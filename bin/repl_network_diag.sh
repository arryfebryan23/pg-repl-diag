#!/usr/bin/env bash
#
# bin/repl_network_diag.sh
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
# CONFIGURATION: behaviour in repl.script.env, environment in repl.env (see repl.env.example).
# TARGET is mandatory; the run aborts if it is not set.
#
# USAGE:
#   1. On the RECEIVING standby (the WAL receiver), start an iperf3 server:
#          iperf3 -s
#   2. On the PRIMARY (the WAL sender), run this script:
#          bin/repl_network_diag.sh [standby-ip]   # arg overrides TARGET in repl.env
#
#   Test direction = Primary -> Standby, matching the direction of WAL flow.
# -----------------------------------------------------------------------------

set -u

# Load central configuration (repl.script.env + repl.env), validation helpers, and the shared
# presentation layer (run_header/section/kv/verdict/...).
# shellcheck source=../lib/repl_common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/repl_common.sh"

# A CLI argument overrides the TARGET defined in repl.env.
TARGET="${1:-${TARGET:-}}"

# Every value this diagnosis depends on must be present, otherwise abort.
require TARGET     "standby IP running 'iperf3 -s'"
require IPERF_PORT
require DURATION
require PARALLEL
require LINK_MBPS
require WAL_SAMPLE
require PGDATABASE

PGDB="$PGDATABASE"

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

run_header "NETWORK DIAGNOSIS — SINGLE-STREAM vs PARALLEL  ->  $TARGET"
kv "Duration / test"   "${DURATION}s"
kv "Parallel streams"  "${PARALLEL}"
kv "iperf3 port"       "${IPERF_PORT}"

# ---------------------------------------------------------------------------
# PHASE 1 — Baseline: RTT & packet loss
# ---------------------------------------------------------------------------
section "[PHASE 1] RTT & packet loss (ping, 100 packets)"
PING_OUT="$(ping -c 100 -i 0.2 -q "$TARGET" 2>/dev/null)"
echo "$PING_OUT" | grep -E 'packet loss|rtt|round-trip'
LOSS="$(echo "$PING_OUT" | grep -oE '[0-9.]+% packet loss' | grep -oE '^[0-9.]+')"
RTT_AVG="$(echo "$PING_OUT" | awk -F'/' '/rtt|round-trip/ {print $5}')"
LOSS="${LOSS:-0}"
RTT_AVG="${RTT_AVG:-0}"
kv "Average RTT"  "${RTT_AVG} ms"
kv "Packet loss"  "${LOSS} %"

# ---------------------------------------------------------------------------
# PHASE 2 — Current TCP configuration
# ---------------------------------------------------------------------------
section "[PHASE 2] TCP configuration on this host (Primary / sender)"
kv "congestion_control" "$(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
kv "available"          "$(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null)"
kv "tcp_wmem"           "$(sysctl -n net.ipv4.tcp_wmem 2>/dev/null)"
kv "tcp_rmem"           "$(sysctl -n net.ipv4.tcp_rmem 2>/dev/null)"
kv "wmem_max"           "$(sysctl -n net.core.wmem_max 2>/dev/null)"
kv "window_scaling"     "$(sysctl -n net.ipv4.tcp_window_scaling 2>/dev/null)"
kv "slow_start_idle"    "$(sysctl -n net.ipv4.tcp_slow_start_after_idle 2>/dev/null)"

# ---------------------------------------------------------------------------
# PHASE 3 — SINGLE-STREAM test (mirrors replication)
# ---------------------------------------------------------------------------
section "[PHASE 3] iperf3 SINGLE stream  (= streaming replication behaviour)"
read -r SINGLE_MBPS SINGLE_RETR <<< "$(run_iperf 1)"
[ "$SINGLE_MBPS" = "ERR" ] && die "iperf3 failed. Ensure 'iperf3 -s' is running on $TARGET and port $IPERF_PORT is open."
kv "Single-stream throughput" "${SINGLE_MBPS} Mbps"
kv "Retransmits"              "${SINGLE_RETR}"

# ---------------------------------------------------------------------------
# PHASE 4 — PARALLEL test (true link capacity)
# ---------------------------------------------------------------------------
section "[PHASE 4] iperf3 PARALLEL ${PARALLEL} streams  (= actual link capacity)"
read -r MULTI_MBPS MULTI_RETR <<< "$(run_iperf "$PARALLEL")"
kv "${PARALLEL}-stream throughput" "${MULTI_MBPS} Mbps"
kv "Retransmits"                  "${MULTI_RETR}"

# ---------------------------------------------------------------------------
# PHASE 5 — WAL generation rate on the Primary
# ---------------------------------------------------------------------------
section "[PHASE 5] WAL generation rate on the Primary (sampling ${WAL_SAMPLE}s)"
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
            kv "WAL generated" "${WAL_BYTES} bytes over ${WAL_SAMPLE}s"
            kv "WAL rate"      "${WAL_MB_S} MB/s  (= ${WAL_MBPS} Mbps)"
            note "This is the average over the sampling window. Re-run during PEAK"
            note "load / batch jobs to capture the PEAK rate, which drives lag."
        else
            warn "Could not compute the WAL delta. Skipping."
        fi
    else
        warn "This host is not the Primary (it is in recovery). Run this phase ON THE PRIMARY."
    fi
else
    warn "psql not found -> WAL phase skipped."
    note "Set PGHOST/PGUSER/PGDATABASE, or run this script on the Primary host."
fi

# ---------------------------------------------------------------------------
# PHASE 6 — Analysis & verdict
# ---------------------------------------------------------------------------
section "[PHASE 6] ANALYSIS"

# Bandwidth-Delay Product (the ideal TCP window)
BDP_BYTES="$(python3 -c "print(int(${LINK_MBPS}*1e6/8 * ${RTT_AVG}/1000))" 2>/dev/null)"
BDP_MB="$(python3 -c "print(f'{${BDP_BYTES}/1048576:.2f}')" 2>/dev/null)"

# Parallel-vs-single ratio
RATIO="$(python3 -c "
s=${SINGLE_MBPS:-0}; m=${MULTI_MBPS:-0}
print(f'{(m/s):.1f}' if s>0 else '0')
" 2>/dev/null)"

kv "Ideal BDP (min window)" "${BDP_MB} MB  (link ${LINK_MBPS}Mbps x RTT ${RTT_AVG}ms)"
kv "Parallel / single"      "${RATIO}x"

# Verdict logic
HIGH_LOSS="$(python3 -c "print(1 if float(${LOSS})>0.1 else 0)")"
SINGLE_BOUND="$(python3 -c "print(1 if float('${RATIO}')>=2.0 else 0)")"

if [ "$SINGLE_BOUND" = "1" ]; then
    verdict bad "SINGLE-STREAM LIMITED"
    bullet "The link sustains ${MULTI_MBPS} Mbps aggregate, but a single stream reaches only ${SINGLE_MBPS} Mbps."
    bullet "Replication (a single stream) will NEVER use the full link capacity."
    if [ "$HIGH_LOSS" = "1" ] || [ "${SINGLE_RETR:-0}" -gt 50 ]; then
        warn "ROOT CAUSE: LOSS-BOUND (loss ${LOSS}%, retransmits ${SINGLE_RETR})."
        action "Switch the congestion control algorithm to BBR on the Primary:"
        bullet "net.core.default_qdisc = fq"
        bullet "net.ipv4.tcp_congestion_control = bbr"
    else
        warn "ROOT CAUSE: LATENCY/WINDOW-BOUND (low loss, retransmits ${SINGLE_RETR})."
        action "Raise TCP buffers above the BDP (${BDP_MB} MB) on both ends:"
        bullet "net.core.wmem_max = $((BDP_BYTES * 4))"
        bullet "net.ipv4.tcp_wmem = 4096 65536 $((BDP_BYTES * 4))"
        bullet "net.ipv4.tcp_slow_start_after_idle = 0"
    fi
else
    verdict warn "NOT a single-stream limitation"
    bullet "Single (${SINGLE_MBPS}) is comparable to parallel (${MULTI_MBPS}). TCP tuning will have little effect."
    bullet "Likely (a): this is the link's true effective capacity -> escalate to the network team."
    bullet "Likely (b): the bottleneck is NOT the network -> inspect apply/disk on the standby."
fi

# --- Final verdict: can a single stream keep up with the WAL rate? ---
section "[FINAL VERDICT] Single-stream capacity vs WAL demand"
if [ "$WAL_MBPS" != "-" ]; then
    kv "Single-stream available" "${SINGLE_MBPS} Mbps"
    kv "WAL demand (sampled)"    "${WAL_MBPS} Mbps  (${WAL_MB_S} MB/s)"
    HEADROOM="$(python3 -c "
single=${SINGLE_MBPS:-0}; wal=${WAL_MBPS:-0}
print(f'{(single/wal):.1f}' if wal>0 else '999')
" 2>/dev/null)"
    kv "Headroom (single/WAL)"   "${HEADROOM}x"
    CAN_KEEP="$(python3 -c "print(1 if float('${HEADROOM}')>=1.5 else 0)")"
    if [ "$CAN_KEEP" = "1" ]; then
        verdict good "Single-stream CAN keep up with the WAL rate (headroom ${HEADROOM}x)"
        note "If lag persists, the NETWORK is NOT the root cause. Inspect APPLY/DISK on the standby"
        note "(the flush_lsn vs replay_lsn gap in pg_stat_replication)."
        note "Caveat: this is an averaged sample. Re-check during peak WAL (batch/checkpoint)."
    else
        verdict bad "Single-stream CANNOT keep up with the WAL rate (headroom only ${HEADROOM}x)"
        action "The NETWORK is a genuine bottleneck. Apply the actions from [PHASE 6] above,"
        action "then re-run this script to verify the headroom has improved."
    fi
else
    verdict warn "WAL rate not measured"
    note "Re-run ON THE PRIMARY with psql access, ideally during peak hours,"
    note "and compare against single-stream ${SINGLE_MBPS} Mbps."
fi
echo ""
