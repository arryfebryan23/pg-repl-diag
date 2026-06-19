#!/usr/bin/env bash
#
# repl_network_diag.sh
# -----------------------------------------------------------------------------
# Diagnosa apakah replication lag ke standby disebabkan oleh LIMITASI
# SINGLE TCP STREAM (latency/loss) atau memang keterbatasan bandwidth link.
#
# KONSEP: PostgreSQL streaming replication = SATU koneksi TCP per standby.
# Jadi yang relevan adalah throughput 1 stream, BUKAN total kapasitas link.
# Script ini membandingkan:
#     - iperf3 1 stream   -> meniru perilaku replikasi sesungguhnya
#     - iperf3 N stream   -> mengukur kapasitas link yang sebenarnya
#
# CARA PAKAI:
#   1. Di STANDBY SURABAYA (penerima WAL), jalankan server iperf3:
#          iperf3 -s
#   2. Di PRIMARY (pengirim WAL), jalankan script ini:
#          ./repl_network_diag.sh <ip-surabaya>
#
#   Arah uji = Primary -> Surabaya, sama dengan arah aliran WAL.
# -----------------------------------------------------------------------------

set -u

# ============================ KONFIGURASI ====================================
TARGET="${1:-}"                 # IP standby Surabaya (server iperf3)
IPERF_PORT="${IPERF_PORT:-5201}"
DURATION="${DURATION:-20}"      # detik per test
PARALLEL="${PARALLEL:-8}"       # jumlah stream untuk uji kapasitas
LINK_MBPS="${LINK_MBPS:-1000}"  # asumsi bandwidth efektif per arah (Mbps) utk hitung BDP

# -- untuk pengukuran laju generate WAL di Primary (pakai env libpq jika kosong) --
WAL_SAMPLE="${WAL_SAMPLE:-15}"  # detik sampling laju WAL (ambil saat jam sibuk!)
PGDB="${PGDATABASE:-postgres}"  # bisa override: PGHOST/PGPORT/PGUSER/PGDATABASE/.pgpass
# =============================================================================

red()   { printf '\033[31m%s\033[0m\n' "$*"; }
grn()   { printf '\033[32m%s\033[0m\n' "$*"; }
ylw()   { printf '\033[33m%s\033[0m\n' "$*"; }
bold()  { printf '\033[1m%s\033[0m\n' "$*"; }
line()  { printf '%s\n' "------------------------------------------------------------"; }

die()   { red "ERROR: $*"; exit 1; }

[ -z "$TARGET" ] && die "Usage: $0 <ip-standby-surabaya>   (jalankan 'iperf3 -s' dulu di Surabaya)"
command -v iperf3 >/dev/null 2>&1 || die "iperf3 belum terpasang. Install: yum/apt install iperf3"
command -v python3 >/dev/null 2>&1 || die "python3 dibutuhkan untuk parsing hasil"
command -v ping    >/dev/null 2>&1 || die "ping tidak ditemukan"

# Helper: jalankan iperf3, kembalikan "throughput_mbps retransmits" via JSON
run_iperf() {
    local streams="$1"
    iperf3 -c "$TARGET" -p "$IPERF_PORT" -t "$DURATION" -P "$streams" -J 2>/dev/null \
    | python3 -c '
import sys, json
try:
    d = json.load(sys.stdin)
    end = d["end"]
    # throughput diterima (bits/s) -> Mbps
    bps = end["sum_received"]["bits_per_second"]
    retr = end.get("sum_sent", {}).get("retransmits", 0)
    print(f"{bps/1e6:.1f} {retr}")
except Exception:
    print("ERR 0")
'
}

bold ""
bold "==================================================================="
bold "   DIAGNOSA NETWORK SINGLE-STREAM vs PARALLEL  ->  $TARGET"
bold "==================================================================="
echo "Durasi/test : ${DURATION}s | Parallel streams: ${PARALLEL} | Port: ${IPERF_PORT}"
line

# ---------------------------------------------------------------------------
# FASE 1 — Baseline: RTT & Packet Loss
# ---------------------------------------------------------------------------
bold "[FASE 1] RTT & Packet Loss (ping 100 paket)"
PING_OUT="$(ping -c 100 -i 0.2 -q "$TARGET" 2>/dev/null)"
echo "$PING_OUT" | grep -E 'packet loss|rtt|round-trip'
LOSS="$(echo "$PING_OUT" | grep -oE '[0-9.]+% packet loss' | grep -oE '^[0-9.]+')"
RTT_AVG="$(echo "$PING_OUT" | awk -F'/' '/rtt|round-trip/ {print $5}')"
LOSS="${LOSS:-0}"
RTT_AVG="${RTT_AVG:-0}"
echo "  -> RTT rata-rata : ${RTT_AVG} ms"
echo "  -> Packet loss   : ${LOSS} %"
line

# ---------------------------------------------------------------------------
# FASE 2 — Konfigurasi TCP saat ini
# ---------------------------------------------------------------------------
bold "[FASE 2] Konfigurasi TCP host ini (Primary/pengirim)"
echo "  congestion_control : $(sysctl -n net.ipv4.tcp_congestion_control 2>/dev/null)"
echo "  tersedia           : $(sysctl -n net.ipv4.tcp_available_congestion_control 2>/dev/null)"
echo "  tcp_wmem           : $(sysctl -n net.ipv4.tcp_wmem 2>/dev/null)"
echo "  tcp_rmem           : $(sysctl -n net.ipv4.tcp_rmem 2>/dev/null)"
echo "  wmem_max           : $(sysctl -n net.core.wmem_max 2>/dev/null)"
echo "  window_scaling     : $(sysctl -n net.ipv4.tcp_window_scaling 2>/dev/null)"
echo "  slow_start_idle    : $(sysctl -n net.ipv4.tcp_slow_start_after_idle 2>/dev/null)"
line

# ---------------------------------------------------------------------------
# FASE 3 — UJI 1 STREAM (meniru replikasi)
# ---------------------------------------------------------------------------
bold "[FASE 3] iperf3 SINGLE stream  (= perilaku streaming replication)"
read -r SINGLE_MBPS SINGLE_RETR <<< "$(run_iperf 1)"
[ "$SINGLE_MBPS" = "ERR" ] && die "iperf3 gagal. Pastikan 'iperf3 -s' jalan di $TARGET dan port $IPERF_PORT terbuka."
echo "  -> Throughput 1 stream : ${SINGLE_MBPS} Mbps"
echo "  -> Retransmits         : ${SINGLE_RETR}"
line

# ---------------------------------------------------------------------------
# FASE 4 — UJI PARALEL (kapasitas link sebenarnya)
# ---------------------------------------------------------------------------
bold "[FASE 4] iperf3 PARALLEL ${PARALLEL} stream  (= kapasitas link aktual)"
read -r MULTI_MBPS MULTI_RETR <<< "$(run_iperf "$PARALLEL")"
echo "  -> Throughput ${PARALLEL} stream : ${MULTI_MBPS} Mbps"
echo "  -> Retransmits          : ${MULTI_RETR}"
line

# ---------------------------------------------------------------------------
# FASE 5 — Laju generate WAL di Primary
# ---------------------------------------------------------------------------
bold "[FASE 5] Laju generate WAL di Primary (sampling ${WAL_SAMPLE}s)"
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
            # konversi ke Mbps (bit/s) agar bisa dibandingkan dgn output iperf3
            WAL_MBPS="$(python3 -c "print(f'{${WAL_BYTES}*8/${WAL_SAMPLE}/1e6:.1f}')")"
            echo "  -> WAL dihasilkan : ${WAL_BYTES} bytes dalam ${WAL_SAMPLE}s"
            echo "  -> Laju WAL       : ${WAL_MB_S} MB/s  (= ${WAL_MBPS} Mbps)"
            ylw "  CATATAN: ini rata-rata saat sampling. Jalankan ulang saat JAM SIBUK /"
            ylw "           saat batch job untuk dapat laju PUNCAK (yang menentukan lag)."
        else
            ylw "  Gagal hitung selisih WAL. Lewati."
        fi
    else
        ylw "  Host ini bukan Primary (sedang recovery). Jalankan fase ini DI PRIMARY."
    fi
else
    ylw "  psql tidak ditemukan -> fase WAL dilewati."
    ylw "  Set PGHOST/PGUSER/PGDATABASE atau jalankan script di host Primary."
fi
line

# ---------------------------------------------------------------------------
# FASE 6 — Analisa & Vonis
# ---------------------------------------------------------------------------
bold "[FASE 6] ANALISA"

# Hitung Bandwidth-Delay Product (window TCP ideal)
BDP_BYTES="$(python3 -c "print(int(${LINK_MBPS}*1e6/8 * ${RTT_AVG}/1000))" 2>/dev/null)"
BDP_MB="$(python3 -c "print(f'{${BDP_BYTES}/1048576:.2f}')" 2>/dev/null)"

# Rasio paralel vs single
RATIO="$(python3 -c "
s=${SINGLE_MBPS:-0}; m=${MULTI_MBPS:-0}
print(f'{(m/s):.1f}' if s>0 else '0')
" 2>/dev/null)"

echo "  BDP ideal (window minimal) : ${BDP_MB} MB  (link ${LINK_MBPS}Mbps x RTT ${RTT_AVG}ms)"
echo "  Rasio paralel / single     : ${RATIO}x"
echo ""

# Logika vonis
HIGH_LOSS="$(python3 -c "print(1 if float(${LOSS})>0.1 else 0)")"
SINGLE_BOUND="$(python3 -c "print(1 if float('${RATIO}')>=2.0 else 0)")"

if [ "$SINGLE_BOUND" = "1" ]; then
    red   ">> VONIS: SINGLE-STREAM LIMITED."
    echo  "   Link sanggup ${MULTI_MBPS} Mbps total, tapi 1 stream cuma ${SINGLE_MBPS} Mbps."
    echo  "   Replikasi (yang cuma 1 stream) TIDAK akan pernah pakai kapasitas penuh link."
    echo  ""
    if [ "$HIGH_LOSS" = "1" ] || [ "${SINGLE_RETR:-0}" -gt 50 ]; then
        ylw "   PENYEBAB: LOSS-BOUND (loss ${LOSS}%, retransmits ${SINGLE_RETR})."
        grn "   AKSI UTAMA: ganti congestion control ke BBR di Primary."
        echo "        net.core.default_qdisc = fq"
        echo "        net.ipv4.tcp_congestion_control = bbr"
    else
        ylw "   PENYEBAB: LATENCY/WINDOW-BOUND (loss rendah, retransmits ${SINGLE_RETR})."
        grn "   AKSI UTAMA: besarkan TCP buffer agar > BDP (${BDP_MB} MB) di kedua sisi."
        echo "        net.core.wmem_max = $((BDP_BYTES * 4))"
        echo "        net.ipv4.tcp_wmem = 4096 65536 $((BDP_BYTES * 4))"
        echo "        net.ipv4.tcp_slow_start_after_idle = 0"
    fi
else
    ylw  ">> VONIS: BUKAN single-stream limitation."
    echo "   Single (${SINGLE_MBPS}) ~ paralel (${MULTI_MBPS}). Tuning TCP efeknya kecil."
    echo "   Kemungkinan: (a) link memang segini kapasitas efektifnya -> eskalasi network,"
    echo "                (b) bottleneck BUKAN di network -> cek apply/disk di standby."
fi
line

# --- Verdict tambahan: apakah single-stream sanggup mengejar laju WAL? ---
bold "[VONIS AKHIR] Kapasitas single-stream vs kebutuhan WAL"
if [ "$WAL_MBPS" != "-" ]; then
    echo "  Single-stream tersedia : ${SINGLE_MBPS} Mbps"
    echo "  Kebutuhan WAL (sampel) : ${WAL_MBPS} Mbps  (${WAL_MB_S} MB/s)"
    HEADROOM="$(python3 -c "
single=${SINGLE_MBPS:-0}; wal=${WAL_MBPS:-0}
print(f'{(single/wal):.1f}' if wal>0 else '999')
" 2>/dev/null)"
    echo "  Headroom (single/WAL)  : ${HEADROOM}x"
    echo ""
    CAN_KEEP="$(python3 -c "print(1 if float('${HEADROOM}')>=1.5 else 0)")"
    if [ "$CAN_KEEP" = "1" ]; then
        grn ">> Single-stream MAMPU mengejar laju WAL (headroom ${HEADROOM}x)."
        ylw "   Jika lag tetap ada -> NETWORK BUKAN akar masalah. Cek APPLY/DISK di Surabaya"
        ylw "   (gap flush_lsn vs replay_lsn di pg_stat_replication)."
        ylw "   Tapi ingat: ini sampel rata-rata. Cek lagi saat WAL puncak (batch/checkpoint)."
    else
        red ">> Single-stream TIDAK sanggup mengejar laju WAL (headroom cuma ${HEADROOM}x)."
        grn "   NETWORK adalah bottleneck nyata. Terapkan aksi dari [FASE 6] di atas,"
        grn "   lalu jalankan ulang script ini untuk verifikasi headroom membaik."
    fi
else
    ylw ">> Laju WAL tidak terukur. Jalankan ulang DI PRIMARY dengan akses psql,"
    ylw "   idealnya saat jam sibuk, lalu bandingkan dengan single-stream ${SINGLE_MBPS} Mbps."
fi
line
echo ""
