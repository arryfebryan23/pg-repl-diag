#!/usr/bin/env bash
#
# bin/repl_apply_diag.sh
# -----------------------------------------------------------------------------
# Counterpart to repl_network_diag.sh — run this ON THE STANDBY.
#
# PURPOSE: determine whether lag originates on the APPLY side (standby disk/CPU)
# or because WAL is genuinely arriving slowly over the network.
#
# CONCEPT: WAL replay on the standby is a SINGLE 'startup' process (single
# threaded). Even when WAL arrives quickly, if the standby's disk/CPU cannot
# apply it as fast as the Primary generates it, lag accumulates indefinitely.
#
# Sampled every interval:
#   - receive_lsn  : how far WAL has been RECEIVED (network)
#   - replay_lsn   : how far WAL has been APPLIED  (disk/CPU)
#   - apply_gap    : the difference -> if it GROWS, apply is not keeping up
#   - arrival_rate : rate at which WAL arrives  (MB/s)
#   - apply_rate   : rate at which WAL is applied (MB/s)
#   - time_lag     : age of the last applied transaction (seconds)
#   - wait_event   : what the startup process is waiting on (I/O? conflict?)
#   - disk %util   : utilization of the busiest disk (via iostat)
#
# CONFIGURATION: all tunables live in repl.env (see repl.env.example).
# Cadence is controlled by APPLY_INTERVAL / APPLY_COUNT.
#
# USAGE (on the standby):
#   bin/repl_apply_diag.sh
#   APPLY_INTERVAL=5 APPLY_COUNT=24 bin/repl_apply_diag.sh   # override for 2 minutes
# -----------------------------------------------------------------------------

set -u

# Load central configuration (repl.env) and validation helpers.
# shellcheck source=../lib/repl_common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/repl_common.sh"

# This probe needs its cadence and DB connectivity defined, otherwise abort.
require APPLY_INTERVAL
require APPLY_COUNT
require PGDATABASE

INTERVAL="$APPLY_INTERVAL"
COUNT="$APPLY_COUNT"
PGDB="$PGDATABASE"

red()  { printf '\033[31m%s\033[0m\n' "$*"; }
grn()  { printf '\033[32m%s\033[0m\n' "$*"; }
ylw()  { printf '\033[33m%s\033[0m\n' "$*"; }
bold() { printf '\033[1m%s\033[0m\n' "$*"; }
line() { printf '%s\n' "---------------------------------------------------------------------------"; }
die()  { red "ERROR: $*"; exit 1; }

command -v psql    >/dev/null 2>&1 || die "psql is required."
command -v python3 >/dev/null 2>&1 || die "python3 is required."
HAS_IOSTAT=1
command -v iostat  >/dev/null 2>&1 || { HAS_IOSTAT=0; ylw "iostat not found (sysstat package) -> disk metrics will be skipped."; }

PSQL="psql -d ${PGDB} -At -X -q -F|"

# Confirm this host is a standby
IN_REC="$($PSQL -c "SELECT pg_is_in_recovery();" 2>/dev/null)" || die "Failed to connect via psql. Check PGHOST/PGUSER/.pgpass."
[ "$IN_REC" = "t" ] || die "This host is NOT a standby (pg_is_in_recovery=false). Run it on the standby."

# Helper: from a 1-second iostat sample, return the highest %util, its device, and await
iostat_peak() {
    [ "$HAS_IOSTAT" = "0" ] && { echo "0 - 0"; return; }
    iostat -dxy 1 1 2>/dev/null | awk '
        /^Device/ { for(i=1;i<=NF;i++){ if($i=="%util")u=i; if($i=="await")a=i; if($i=="w_await")w=i } next }
        NF>3 && u>0 {
            util=$u+0
            if(util>maxu){ maxu=util; dev=$1; aw=(a? $a+0 : (w? $w+0 : 0)) }
        }
        END{ printf "%.1f %s %.1f", maxu+0, (dev==""?"-":dev), aw+0 }'
}

bold ""
bold "==================================================================="
bold "   STANDBY APPLY-SIDE DIAGNOSIS  —  sampling ${INTERVAL}s x ${COUNT}"
bold "==================================================================="

# --- Static information & relevant settings ---
bold "[INFO] Standby configuration"
DATADIR="$($PSQL -c "SHOW data_directory;" 2>/dev/null)"
echo "  data_directory             : ${DATADIR}"
if [ -n "${DATADIR:-}" ]; then
    echo "  device (df)                : $(df --output=source "$DATADIR" 2>/dev/null | tail -1)"
fi
echo "  recovery_min_apply_delay   : $($PSQL -c "SHOW recovery_min_apply_delay;" 2>/dev/null)   <- if >0, the lag is INTENTIONAL"
echo "  hot_standby_feedback       : $($PSQL -c "SHOW hot_standby_feedback;" 2>/dev/null)"
echo "  max_standby_streaming_delay: $($PSQL -c "SHOW max_standby_streaming_delay;" 2>/dev/null)"
echo "  parallel restore           : (replay remains single-threaded; this does not accelerate ordinary redo)"
line

# Table header
printf "%-8s | %12s | %10s | %10s | %8s | %-22s | %s\n" \
    "time" "apply_gap" "arrival" "apply" "lag(s)" "startup_wait" "disk(%util dev await)"
line

prev_recv=""; prev_replay=""
sum_arr=0; sum_app=0; n_rate=0
gap_first=""; gap_last=""
io_wait_hits=0; conflict_hits=0; max_util_seen=0

for ((i=1; i<=COUNT; i++)); do
    # Single query: absolute byte offsets of receive & replay, time lag, wait event
    ROW="$($PSQL -c "
        SELECT
          pg_wal_lsn_diff(pg_last_wal_receive_lsn(),'0/0')::bigint,
          pg_wal_lsn_diff(pg_last_wal_replay_lsn(),'0/0')::bigint,
          round(coalesce(extract(epoch FROM (now()-pg_last_xact_replay_timestamp())),0)::numeric,1),
          coalesce((SELECT coalesce(wait_event_type,'-')||'/'||coalesce(wait_event,'running')
                    FROM pg_stat_activity WHERE backend_type='startup' LIMIT 1),'-/-');
    " 2>/dev/null)"

    recv="$(echo "$ROW"   | cut -d'|' -f1)"
    replay="$(echo "$ROW" | cut -d'|' -f2)"
    tlag="$(echo "$ROW"   | cut -d'|' -f3)"
    wait_ev="$(echo "$ROW"| cut -d'|' -f4)"
    [ -z "${recv:-}" ] && { ylw "  (sample failed, continuing)"; sleep "$INTERVAL"; continue; }

    gap=$(( recv - replay ))
    [ -z "$gap_first" ] && gap_first=$gap
    gap_last=$gap

    # rates are computed from the 2nd sample onward
    arr_rate="-"; app_rate="-"
    if [ -n "$prev_recv" ]; then
        arr_rate="$(python3 -c "print(f'{($recv-$prev_recv)/$INTERVAL/1048576:.1f}')")"
        app_rate="$(python3 -c "print(f'{($replay-$prev_replay)/$INTERVAL/1048576:.1f}')")"
        sum_arr="$(python3 -c "print($sum_arr+($recv-$prev_recv)/$INTERVAL/1048576)")"
        sum_app="$(python3 -c "print($sum_app+($replay-$prev_replay)/$INTERVAL/1048576)")"
        n_rate=$((n_rate+1))
    fi
    prev_recv=$recv; prev_replay=$replay

    # wait event categorization
    case "$wait_ev" in
        IO/*|*/DataFileRead|*/DataFileWrite|*/WALSync|*/WALRead) io_wait_hits=$((io_wait_hits+1)) ;;
        *Recovery*|*Conflict*|Lock/*)                            conflict_hits=$((conflict_hits+1)) ;;
    esac

    # disk
    read -r util dev await <<< "$(iostat_peak)"
    python3 -c "exit(0 if float('$util')>float('$max_util_seen') else 1)" 2>/dev/null && max_util_seen=$util

    gap_mb="$(python3 -c "print(f'{$gap/1048576:.1f}MB')")"
    printf "%-8s | %12s | %8s%s | %8s%s | %8s | %-22s | %s%% %s %sms\n" \
        "$(date +%H:%M:%S)" "$gap_mb" \
        "$arr_rate" "$([ "$arr_rate" != "-" ] && echo "MB" || echo "")" \
        "$app_rate" "$([ "$app_rate" != "-" ] && echo "MB" || echo "")" \
        "$tlag" "$wait_ev" "$util" "$dev" "$await"

    sleep "$INTERVAL"
done
line

# ---------------------------------------------------------------------------
# ANALYSIS & VERDICT
# ---------------------------------------------------------------------------
bold "[ANALYSIS]"
avg_arr="-"; avg_app="-"
if [ "$n_rate" -gt 0 ]; then
    avg_arr="$(python3 -c "print(f'{$sum_arr/$n_rate:.1f}')")"
    avg_app="$(python3 -c "print(f'{$sum_app/$n_rate:.1f}')")"
fi
echo "  Average arrival (WAL received)  : ${avg_arr} MB/s"
echo "  Average apply   (WAL applied)   : ${avg_app} MB/s"
echo "  apply_gap start -> end          : $(python3 -c "print(f'{$gap_first/1048576:.1f}')") MB -> $(python3 -c "print(f'{$gap_last/1048576:.1f}')") MB"
echo "  Highest disk %util observed     : ${max_util_seen}%"
echo "  Samples with I/O wait / conflict: ${io_wait_hits} / ${conflict_hits} (of ${COUNT})"
echo ""

GAP_GROWING="$(python3 -c "print(1 if $gap_last > $gap_first*1.2 and ($gap_last-$gap_first)>5*1048576 else 0)")"
APPLY_SLOWER="$(python3 -c "
a='${avg_arr}'; p='${avg_app}'
print(1 if (a!='-' and p!='-' and float(p) < float(a)*0.9) else 0)")"
HIGH_UTIL="$(python3 -c "print(1 if float('${max_util_seen}')>80 else 0)")"

if [ "$GAP_GROWING" = "1" ] || [ "$APPLY_SLOWER" = "1" ]; then
    red ">> VERDICT: APPLY-BOUND. WAL accumulates faster than the standby can apply it."
    echo "   (the gap is growing and/or apply_rate < arrival_rate)"
    echo ""
    if [ "$HIGH_UTIL" = "1" ] || [ "$io_wait_hits" -gt $((COUNT/3)) ]; then
        ylw "   ROOT CAUSE: DISK I/O (util ${max_util_seen}%, frequent I/O waits)."
        grn "   ACTION: upgrade standby storage (NVMe/SSD), separate WAL from data,"
        grn "           increase shared_buffers, and verify the DR disk is not slower than the Primary."
    elif [ "$conflict_hits" -gt 0 ]; then
        ylw "   ROOT CAUSE: RECOVERY CONFLICT (standby queries vs replay)."
        grn "   ACTION: review hot_standby_feedback & max_standby_streaming_delay,"
        grn "           or move heavy read queries to a different standby."
    else
        ylw "   ROOT CAUSE: SINGLE-THREAD CPU. The 'startup' (redo) process is pegged on 1 core,"
        ylw "   while disk is idle and no conflicts are present."
        grn "   ACTION: use a CPU with higher per-core clock, reduce WAL volume on the Primary"
        grn "           (wal_compression, smaller batches), and consider cascading replication."
    fi
elif [ "$avg_arr" != "-" ] && python3 -c "exit(0 if float('${avg_arr}')<1.0 else 1)" 2>/dev/null; then
    ylw ">> VERDICT: WAL ARRIVING SLOWLY (low arrival, no apply backlog)."
    echo "   Apply is effectively idle / capable, but little WAL is coming in."
    grn "   -> The bottleneck is likely the NETWORK. Run repl_network_diag.sh from the Primary."
else
    grn ">> VERDICT: HEALTHY. Apply keeps up with arrival, the gap is stable, no significant lag."
    ylw "   If users still perceive lag, re-check during PEAK load (batch/checkpoint)."
fi
line
bold "Pair this with repl_network_diag.sh (Primary side) for the full picture:"
echo "  - Network script says single-stream is sufficient BUT this is APPLY-BOUND -> focus on standby DISK/CPU."
echo "  - This script reports low arrival -> go back to the network."
echo ""
