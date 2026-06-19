#!/usr/bin/env bash
#
# repl_network_diag.sh
# -----------------------------------------------------------------------------
# Determines whether replication lag to a standby is caused by a SINGLE TCP
# STREAM limitation (latency/loss) or by genuine link bandwidth constraints.
#
# CONCEPT: PostgreSQL streaming replication uses ONE TCP connection per
# standby. The figure that matters is therefore single-stream throughput, NOT
# the aggregate capacity of the link. This script compares:
#     - iperf3, 1 stream   -> mirrors real replication behaviour
#     - iperf3, N streams  -> measures the true capacity of the link
#
# USAGE:
#   1. On the RECEIVING standby (the WAL receiver), start an iperf3 server:
#          iperf3 -s
#   2. On the PRIMARY (the WAL sender), run this script:
#          ./repl_network_diag.sh <standby-ip>
#
#   Test direction = Primary -> Standby, matching the direction of WAL flow.
# -----------------------------------------------------------------------------

set -u

# ============================ CONFIGURATION ==================================
TARGET="${1:-}"                 # standby IP (iperf3 server)
IPERF_PORT="${IPERF_PORT:-5201}"
DURATION="${DURATION:-20}"      # seconds per test
PARALLEL="${PARALLEL:-8}"       # stream count for the capacity test
LINK_MBPS="${LINK_MBPS:-1000}"  # assumed effective per-direction bandwidth (Mbps), for BDP

# -- WAL generation sampling on the Primary (uses libpq env vars if unset) --
WAL_SAMPLE="${WAL_SAMPLE:-15}"  # seconds to sample WAL rate (run during peak load!)
PGDB="${PGDATABASE:-postgres}"  # override via PGHOST/PGPORT/PGUSER/PGDATABASE/.pgpass
# =============================================================================

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
grn()   { printf '\033[32m%s\033[0m\n' "$*"; }
ylw()   { printf '\033[33m%s\033[0m\n' "$*"; }
bold()  { printf '\033[1m%s\033[0m\n' "$*"; }
line()  { printf '%s\n' "------------------------------------------------------------"; }

die()   { red "ERROR: $*"; exit 1; }

[ -z "$TARGET" ] && die "Usage: $0 <standby-ip>   (start 'iperf3 -s' on the standby first)"
command -v iperf3 >/dev/null 2>&1 || die "iperf3 is not installed. Install with: yum/apt install iperf3"
command -v python3 >/dev/null 2>&1 || die "python3 is required to parse results"
command -v ping    >/dev/null 2>&1 || die "ping not found"

# Helper: run iperf3 and return "throughput_mbps retransmits" parsed from JSON
run_iperf() {
    local streams="$1"
    iperf3 -c "$TARGET" -p "$IPERF_PORT" -t "$DURATION" -P "$streams" -J 2>/dev/null \
    | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
    end = d["end"]
    # received throughput (bits/s) -> Mbps
    bps = end["sum_received"]["bits_per_second"]
    retr = end.get("sum_sent", {}).get("retransmits", 0)
    print(f"{bps/1e6:.1f} {retr}")
except Exception:
    print("ERR 0")
'
}

bold ""
bold "==================================================================="
bold "   NETWORK DIAGNOSIS: SINGLE-STREAM vs PARALLEL  ->  $TARGET"
bold "==================================================================="
echo "Duration/test : ${DURATION}s | Parallel streams: ${PARALLEL} | Port: ${IPERF_PORT}"
line

# ---------------------------------------------------------------------------
# PHASE 1 — Baseline: RTT & packet loss
# ---------------------------------------------------------------------------
bold "[PHASE 1] RTT & packet loss (ping, 100 packets)"
PING_OUT="$(ping -c 100 -i 0.2 -q "$TARGET" 2>/dev/null)"
echo "$PING_OUT" | grep -E 'packet loss|rtt|round-trip'
LOSS="$(echo "$PING_OUT" | grep -oE '[0-9.]+% packet loss' | grep -oE '^[0-9.]+')"
RTT_AVG="$(echo "$PING_OUT" | awk -F'/' '/rtt|round-trip/ {print $5}')"
LOSS="${LOSS:-0}"
RTT_AVG="${RTT_AVG:-0}"
echo "  -> Average RTT  : ${RTT_AVG} ms"
echo "  -> Packet loss  : ${LOSS} %"
line

# ---------------------------------------------------------------------------
# PHASE 2 — Current TCP configuration
# ---------------------------------------------------------------------------
bold "[PHASE 2] TCP configuration on this host (Primary / sender)"
echo "  congestion_control : $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
echo "  available          : $(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null)"
echo "  tcp_wmem           : $(sysctl -n net.ipv4.tcp_wmem 2>/dev/null)"
echo "  tcp_rmem           : $(sysctl -n net.ipv4.tcp_rmem 2>/dev/null)"
echo "  wmem_max           : $(sysctl -n net.core.wmem_max 2>/dev/null)"
echo "  window_scaling     : $(sysctl -n net.ipv4.tcp_window_scaling 2>/dev/null)"
echo "  slow_start_idle    : $(sysctl -n net.ipv4.tcp_slow_start_after_idle 2>/dev/null)"
line

# ---------------------------------------------------------------------------
# PHASE 3 — SINGLE-STREAM test (mirrors replication)
# ---------------------------------------------------------------------------
bold "[PHASE 3] iperf3 SINGLE stream  (= streaming replication behaviour)"
read -r SINGLE_MBPS SINGLE_RETR <<< "$(run_iperf 1)"
[ "$SINGLE_MBPS" = "ERR" ] && die "iperf3 failed. Ensure 'iperf3 -s' is running on $TARGET and port $IPERF_PORT is open."
echo "  -> Single-stream throughput : ${SINGLE_MBPS} Mbps"
echo "  -> Retransmits              : ${SINGLE_RETR}"
line

# ---------------------------------------------------------------------------
# PHASE 4 — PARALLEL test (true link capacity)
# ---------------------------------------------------------------------------
bold "[PHASE 4] iperf3 PARALLEL ${PARALLEL} streams  (= actual link capacity)"
read -r MULTI_MBPS MULTI_RETR <<< "$(run_iperf "$PARALLEL")"
echo "  -> ${PARALLEL}-stream throughput : ${MULTI_MBPS} Mbps"
echo "  -> Retransmits           : ${MULTI_RETR}"
line

# ---------------------------------------------------------------------------
# PHASE 5 — WAL generation rate on the Primary
# ---------------------------------------------------------------------------
bold "[PHASE 5] WAL generation rate on the Primary (sampling ${WAL_SAMPLE}s)"
WAL_MB_S="-"; WAL_MBPS="-"
if command -v psql >/dev/null 2>&1; then
    PSQL="psql -d ${PGDB} -At -X -q"
    IS_PRIMARY="$($PSQL -c "SELECT pg_is_in_recovery();" 2>/dev/null)"
    if [ "$IS_PRIMARY" = "f" ]; then
        LSN1="$($PSQL -c "SELECT pg_current_wal_lsn();" 2>/dev/null)"
        sleep "$WAL_SAMPLE"
        LSN2="$($PSQL -c "SELECT pg_current_wal_lsn();" 2>/dev/null)"
        WAL_BYTES="$($PSQL -c "SELECT pg_wal_lsn_diff('${LSN2}','${LSN1}');" 2>/dev/null)"
        if [ -n "${WAL_BYTES:-}" ] && [ "${WAL_BYTES}" -ge 0 ] 2>/dev/null; then
            WAL_MB_S="$(python3 -c "print(f'{${WAL_BYTES}/${WAL_SAMPLE}/1048576:.1f}')")"
            # convert to Mbps (bits/s) so it is directly comparable to iperf3 output
            WAL_MBPS="$(python3 -c "print(f'{${WAL_BYTES}*8/${WAL_SAMPLE}/1e6:.1f}')")"
            echo "  -> WAL generated : ${WAL_BYTES} bytes over ${WAL_SAMPLE}s"
            echo "  -> WAL rate      : ${WAL_MB_S} MB/s  (= ${WAL_MBPS} Mbps)"
            ylw "  NOTE: this is the average over the sampling window. Re-run during PEAK"
            ylw "        load / batch jobs to capture the PEAK rate, which drives lag."
        else
            ylw "  Could not compute the WAL delta. Skipping."
        fi
    else
        ylw "  This host is not the Primary (it is in recovery). Run this phase ON THE PRIMARY."
    fi
else
    ylw "  psql not found -> WAL phase skipped."
    ylw "  Set PGHOST/PGUSER/PGDATABASE, or run this script on the Primary host."
fi
line

# ---------------------------------------------------------------------------
# PHASE 6 — Analysis & verdict
# ---------------------------------------------------------------------------
bold "[PHASE 6] ANALYSIS"

# Bandwidth-Delay Product (the ideal TCP window)
BDP_BYTES="$(python3 -c "print(int(${LINK_MBPS}*1e6/8 * ${RTT_AVG}/1000))" 2>/dev/null)"
BDP_MB="$(python3 -c "print(f'{${BDP_BYTES}/1048576:.2f}')" 2>/dev/null)"

# Parallel-vs-single ratio
RATIO="$(python3 -c "
s=${SINGLE_MBPS:-0}; m=${MULTI_MBPS:-0}
print(f'{(m/s):.1f}' if s>0 else '0')
" 2>/dev/null)"

echo "  Ideal BDP (minimum window) : ${BDP_MB} MB  (link ${LINK_MBPS}Mbps x RTT ${RTT_AVG}ms)"
echo "  Parallel / single ratio    : ${RATIO}x"
echo ""

# Verdict logic
HIGH_LOSS="$(python3 -c "print(1 if float(${LOSS})>0.1 else 0)")"
SINGLE_BOUND="$(python3 -c "print(1 if float('${RATIO}')>=2.0 else 0)")"

if [ "$SINGLE_BOUND" = "1" ]; then
    red   ">> VERDICT: SINGLE-STREAM LIMITED."
    echo  "   The link sustains ${MULTI_MBPS} Mbps aggregate, but a single stream reaches only ${SINGLE_MBPS} Mbps."
    echo  "   Replication (a single stream) will NEVER use the full link capacity."
    echo  ""
    if [ "$HIGH_LOSS" = "1" ] || [ "${SINGLE_RETR:-0}" -gt 50 ]; then
        ylw "   ROOT CAUSE: LOSS-BOUND (loss ${LOSS}%, retransmits ${SINGLE_RETR})."
        grn "   PRIMARY ACTION: switch the congestion control algorithm to BBR on the Primary."
        echo "        net.core.default_qdisc = fq"
        echo "        net.ipv4.tcp_congestion_control = bbr"
    else
        ylw "   ROOT CAUSE: LATENCY/WINDOW-BOUND (low loss, retransmits ${SINGLE_RETR})."
        grn "   PRIMARY ACTION: raise TCP buffers above the BDP (${BDP_MB} MB) on both ends."
        echo "        net.core.wmem_max = $((BDP_BYTES * 4))"
        echo "        net.ipv4.tcp_wmem = 4096 65536 $((BDP_BYTES * 4))"
        echo "        net.ipv4.tcp_slow_start_after_idle = 0"
    fi
else
    ylw  ">> VERDICT: NOT a single-stream limitation."
    echo "   Single (${SINGLE_MBPS}) is comparable to parallel (${MULTI_MBPS}). TCP tuning will have little effect."
    echo "   Likely: (a) this is the link's true effective capacity -> escalate to the network team,"
    echo "           (b) the bottleneck is NOT the network -> inspect apply/disk on the standby."
fi
line

# --- Final verdict: can a single stream keep up with the WAL rate? ---
bold "[FINAL VERDICT] Single-stream capacity vs WAL demand"
if [ "$WAL_MBPS" != "-" ]; then
    echo "  Single-stream available : ${SINGLE_MBPS} Mbps"
    echo "  WAL demand (sampled)    : ${WAL_MBPS} Mbps  (${WAL_MB_S} MB/s)"
    HEADROOM="$(python3 -c "
single=${SINGLE_MBPS:-0}; wal=${WAL_MBPS:-0}
print(f'{(single/wal):.1f}' if wal>0 else '999')
" 2>/dev/null)"
    echo "  Headroom (single/WAL)   : ${HEADROOM}x"
    echo ""
    CAN_KEEP="$(python3 -c "print(1 if float('${HEADROOM}')>=1.5 else 0)")"
    if [ "$CAN_KEEP" = "1" ]; then
        grn ">> Single-stream CAN keep up with the WAL rate (headroom ${HEADROOM}x)."
        ylw "   If lag persists, the NETWORK is NOT the root cause. Inspect APPLY/DISK on the standby"
        ylw "   (the flush_lsn vs replay_lsn gap in pg_stat_replication)."
        ylw "   Caveat: this is an averaged sample. Re-check during peak WAL (batch/checkpoint)."
    else
        red ">> Single-stream CANNOT keep up with the WAL rate (headroom only ${HEADROOM}x)."
        grn "   The NETWORK is a genuine bottleneck. Apply the actions from [PHASE 6] above,"
        grn "   then re-run this script to verify the headroom has improved."
    fi
else
    ylw ">> WAL rate not measured. Re-run ON THE PRIMARY with psql access,"
    ylw "   ideally during peak hours, and compare against single-stream ${SINGLE_MBPS} Mbps."
fi
line
echo ""
