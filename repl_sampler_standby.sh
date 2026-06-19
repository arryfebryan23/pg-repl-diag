#!/usr/bin/env bash
#
# repl_sampler_standby.sh  —  run ON THE STANDBY (background / systemd)
# -----------------------------------------------------------------------------
# Periodically samples apply-side metrics into a RAW CSV.
# When time_lag exceeds the threshold, it performs a BURST CAPTURE: a detailed
# snapshot of the incident at the moment it occurs.
#
# OUTPUT (append, restart-safe):
#   $OUTDIR/standby_metrics.csv
#   $OUTDIR/burst_standby_<ts>.txt
#
# USAGE:
#   ./repl_sampler_standby.sh
#   INTERVAL=10 THRESHOLD_LAG_S=30 OUTDIR=./repl_metrics ./repl_sampler_standby.sh
#   nohup ./repl_sampler_standby.sh >/var/log/repl_sampler.log 2>&1 &
# -----------------------------------------------------------------------------
set -u

INTERVAL="${INTERVAL:-10}"
THRESHOLD_LAG_S="${THRESHOLD_LAG_S:-30}"
BURST_COOLDOWN="${BURST_COOLDOWN:-120}"
COUNT="${COUNT:-0}"
OUTDIR="${OUTDIR:-./repl_metrics}"
PGDB="${PGDATABASE:-postgres}"

PSQL="psql -d ${PGDB} -X -At -q -F|"
CSV="${OUTDIR}/standby_metrics.csv"
mkdir -p "$OUTDIR"
CLK="$(getconf CLK_TCK 2>/dev/null || echo 100)"

command -v psql >/dev/null 2>&1 || { echo "ERROR: psql not found"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 not found"; exit 1; }
HAS_IOSTAT=1; command -v iostat >/dev/null 2>&1 || HAS_IOSTAT=0

IN_REC="$($PSQL -c 'SELECT pg_is_in_recovery();' 2>/dev/null)" || { echo "ERROR: failed to connect via psql"; exit 1; }
[ "$IN_REC" = "t" ] || { echo "ERROR: this is NOT a STANDBY (in_recovery=$IN_REC)."; exit 1; }

HEADER="ts_epoch,ts_human,receive_lsn_bytes,replay_lsn_bytes,apply_gap_bytes,arrival_mbps,apply_mbps,time_lag_s,wait_event,disk_util,disk_dev,disk_await,sock_rtt_ms,sock_retrans,cpu_startup_pct"
[ -f "$CSV" ] || echo "$HEADER" > "$CSV"

trap 'echo "[stop] standby sampler stopped."; exit 0' INT TERM

# Highest %util + device + await from a 1-second iostat sample
iostat_peak() {
    [ "$HAS_IOSTAT" = "0" ] && { echo "0 - 0"; return; }
    iostat -dxy 1 1 2>/dev/null | awk '
      /^Device/ { for(i=1;i<=NF;i++){ if($i=="%util")u=i; if($i=="await")a=i; if($i=="w_await")w=i } next }
      NF>3 && u>0 { v=$u+0; if(v>m){m=v;d=$1;aw=(a?$a+0:(w?$w+0:0))} }
      END{ printf "%.1f %s %.1f", m+0,(d==""?"-":d),aw+0 }'
}
# rtt(ms) and total retransmits from the replication socket (walreceiver -> primary:5432)
sock_info() {
    local out rtt retr
    out="$(ss -tin '( dport = :5432 or sport = :5432 )' 2>/dev/null state established)"
    rtt="$(echo "$out"  | grep -oE 'rtt:[0-9.]+'        | head -1 | cut -d: -f2)"
    retr="$(echo "$out" | grep -oE 'retrans:[0-9]+/[0-9]+' | head -1 | cut -d/ -f2)"
    echo "${rtt:--} ${retr:--}"
}

echo "[start] STANDBY sampler -> $CSV (interval ${INTERVAL}s, lag threshold ${THRESHOLD_LAG_S}s)"

prev_recv=""; prev_replay=""; prev_ts=""; prev_pid=""; prev_ticks=""; last_burst=0; iter=0
while :; do
    iter=$((iter+1))
    EPOCH="$(date +%s)"; HUMAN="$(date '+%Y-%m-%d %H:%M:%S')"

    ROW="$($PSQL -c "
      SELECT pg_wal_lsn_diff(pg_last_wal_receive_lsn(),'0/0')::bigint,
             pg_wal_lsn_diff(pg_last_wal_replay_lsn(),'0/0')::bigint,
             round(coalesce(extract(epoch FROM (now()-pg_last_xact_replay_timestamp())),0)::numeric,1),
             coalesce((SELECT coalesce(wait_event_type,'-')||'/'||coalesce(wait_event,'running')
                       FROM pg_stat_activity WHERE backend_type='startup' LIMIT 1),'-/-');" 2>/dev/null)"
    recv="$(echo "$ROW"   | cut -d'|' -f1)"
    replay="$(echo "$ROW" | cut -d'|' -f2)"
    tlag="$(echo "$ROW"   | cut -d'|' -f3)"
    wait_ev="$(echo "$ROW"| cut -d'|' -f4 | tr ',' ';')"
    [ -z "${recv:-}" ] && { echo "[warn] query failed"; sleep "$INTERVAL"; continue; }

    gap=$(( recv - replay ))
    arr="-"; app="-"
    if [ -n "$prev_recv" ] && [ "$EPOCH" -gt "${prev_ts:-0}" ]; then
        dt=$(( EPOCH - prev_ts ))
        arr="$(python3 -c "print(f'{($recv-$prev_recv)/$dt/1048576:.3f}')")"
        app="$(python3 -c "print(f'{($replay-$prev_replay)/$dt/1048576:.3f}')")"
    fi

    # CPU of the startup (redo) process — /proc delta, accurate per-interval
    cpu="-"
    pid="$(ps -eo pid,cmd 2>/dev/null | grep -E 'postgres.*(startup|recovering)' | grep -v grep | awk '{print $1}' | head -1)"
    if [ -n "${pid:-}" ] && [ -r "/proc/$pid/stat" ]; then
        ticks="$(awk '{print $14+$15}' "/proc/$pid/stat" 2>/dev/null)"
        if [ "$pid" = "$prev_pid" ] && [ -n "$prev_ticks" ] && [ "$EPOCH" -gt "${prev_ts:-0}" ]; then
            cpu="$(python3 -c "print(f'{($ticks-$prev_ticks)/$CLK/($EPOCH-$prev_ts)*100:.1f}')")"
        fi
        prev_pid="$pid"; prev_ticks="$ticks"
    fi

    read -r util dev await <<< "$(iostat_peak)"
    read -r rtt retr <<< "$(sock_info)"

    prev_recv="$recv"; prev_replay="$replay"; prev_ts="$EPOCH"

    echo "${EPOCH},${HUMAN},${recv},${replay},${gap},${arr},${app},${tlag},${wait_ev},${util},${dev},${await},${rtt},${retr},${cpu}" >> "$CSV"

    # Burst capture
    if python3 -c "exit(0 if float('${tlag:-0}')>${THRESHOLD_LAG_S} else 1)" 2>/dev/null && [ $((EPOCH - last_burst)) -ge "$BURST_COOLDOWN" ]; then
        last_burst="$EPOCH"
        BF="${OUTDIR}/burst_standby_$(date '+%Y%m%d_%H%M%S').txt"
        {
            echo "=== STANDBY BURST @ ${HUMAN} (time_lag=${tlag}s > ${THRESHOLD_LAG_S}s) ==="
            echo "gap=$(python3 -c "print(f'{$gap/1048576:.1f}MB')") arrival=${arr}MB/s apply=${app}MB/s wait=${wait_ev} disk_util=${util}% cpu_redo=${cpu}%"
            echo "--- pg_stat_activity (all backends) ---"
            psql -d "$PGDB" -X -c "SELECT pid,backend_type,state,wait_event_type,wait_event,now()-query_start AS dur FROM pg_stat_activity ORDER BY backend_type;" 2>&1
            echo "--- iostat detail ---"; [ "$HAS_IOSTAT" = "1" ] && iostat -dxy 1 5 2>&1
            echo "--- per-core CPU ---"; command -v mpstat >/dev/null && mpstat -P ALL 1 3 2>&1
            echo "--- replication socket ---"; ss -tinp '( dport = :5432 or sport = :5432 )' 2>&1 | sed -E 's/(password=)[^ ]*/\1***/Ig'
        } > "$BF"
        echo "[BURST] incident captured -> $BF"
    fi

    [ "$COUNT" -gt 0 ] && [ "$iter" -ge "$COUNT" ] && { echo "[done] $COUNT samples complete."; break; }
    sleep "$INTERVAL"
done
