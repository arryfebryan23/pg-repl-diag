#!/usr/bin/env bash
#
# repl_apply_diag.sh
# -----------------------------------------------------------------------------
# Pasangan dari repl_network_diag.sh — dijalankan DI STANDBY SURABAYA.
#
# TUJUAN: menentukan apakah lag disebabkan oleh sisi APPLY (disk/CPU standby)
# atau WAL memang datang lambat dari network.
#
# KONSEP: replay WAL di standby = SATU proses 'startup' (single-thread).
# Walau WAL sudah sampai dengan cepat, kalau disk/CPU Surabaya tidak sanggup
# apply secepat Primary generate, lag akan terus menumpuk.
#
# Yang diukur tiap interval:
#   - receive_lsn  : seberapa jauh WAL sudah DITERIMA (network)
#   - replay_lsn   : seberapa jauh WAL sudah DI-APPLY (disk/CPU)
#   - apply_gap    : selisih keduanya  -> kalau MEMBESAR = apply tidak ngejar
#   - arrival_rate : laju WAL datang   (MB/s)
#   - apply_rate   : laju WAL di-apply (MB/s)
#   - time_lag     : umur transaksi terakhir yang ter-apply (detik)
#   - wait_event   : proses startup sedang nunggu apa (IO? konflik?)
#   - disk %util   : kesibukan disk paling sibuk (via iostat)
#
# CARA PAKAI (di Surabaya):
#   ./repl_apply_diag.sh                 # default sampling 5s x 12 = 1 menit
#   INTERVAL=5 COUNT=24 ./repl_apply_diag.sh    # 2 menit
#   (set PGHOST/PGPORT/PGUSER/PGDATABASE bila perlu, atau pakai .pgpass)
# -----------------------------------------------------------------------------

set -u

# ============================ KONFIGURASI ====================================
INTERVAL="${INTERVAL:-5}"        # detik antar sampel
COUNT="${COUNT:-12}"             # jumlah sampel (12 x 5s = 1 menit)
PGDB="${PGDATABASE:-postgres}"
# =============================================================================

red()  { printf '\033[31m%s\033[0m\n' "$*"; }
grn()  { printf '\033[32m%s\033[0m\n' "$*"; }
ylw()  { printf '\033[33m%s\033[0m\n' "$*"; }
bold() { printf '\033[1m%s\033[0m\n' "$*"; }
line() { printf '%s\n' "---------------------------------------------------------------------------"; }
die()  { red "ERROR: $*"; exit 1; }

command -v psql    >/dev/null 2>&1 || die "psql dibutuhkan."
command -v python3 >/dev/null 2>&1 || die "python3 dibutuhkan."
HAS_IOSTAT=1
command -v iostat  >/dev/null 2>&1 || { HAS_IOSTAT=0; ylw "iostat tidak ada (paket sysstat) -> metrik disk dilewati."; }

PSQL="psql -d ${PGDB} -At -X -q -F|"

# Pastikan ini standby
IN_REC="$($PSQL -c "SELECT pg_is_in_recovery();" 2>/dev/null)" || die "Gagal konek psql. Cek PGHOST/PGUSER/.pgpass."
[ "$IN_REC" = "t" ] || die "Host ini BUKAN standby (pg_is_in_recovery=false). Jalankan di Surabaya."

# Helper: ambil %util tertinggi + device-nya + await, dari satu sampel iostat 1 detik
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
bold "   DIAGNOSA SISI APPLY (STANDBY)  —  sampling ${INTERVAL}s x ${COUNT}"
bold "==================================================================="

# --- Info statis & setting yang relevan ---
bold "[INFO] Konfigurasi standby"
DATADIR="$($PSQL -c "SHOW data_directory;" 2>/dev/null)"
echo "  data_directory             : ${DATADIR}"
if [ -n "${DATADIR:-}" ]; then
    echo "  device (df)                : $(df --output=source "$DATADIR" 2>/dev/null | tail -1)"
fi
echo "  recovery_min_apply_delay   : $($PSQL -c "SHOW recovery_min_apply_delay;" 2>/dev/null)   <- kalau >0, lag DISENGAJA!"
echo "  hot_standby_feedback       : $($PSQL -c "SHOW hot_standby_feedback;" 2>/dev/null)"
echo "  max_standby_streaming_delay: $($PSQL -c "SHOW max_standby_streaming_delay;" 2>/dev/null)"
echo "  max_parallel_..._restore   : (replay tetap single-thread; ini tidak mempercepat redo biasa)"
line

# Header tabel
printf "%-8s | %12s | %10s | %10s | %8s | %-22s | %s\n" \
    "waktu" "apply_gap" "arrival" "apply" "lag(s)" "startup_wait" "disk(%util dev await)"
line

prev_recv=""; prev_replay=""
sum_arr=0; sum_app=0; n_rate=0
gap_first=""; gap_last=""
io_wait_hits=0; conflict_hits=0; max_util_seen=0

for ((i=1; i<=COUNT; i++)); do
    # Satu query: byte-offset absolut receive & replay, time lag, wait event
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
    [ -z "${recv:-}" ] && { ylw "  (sampel gagal, lanjut)"; sleep "$INTERVAL"; continue; }

    gap=$(( recv - replay ))
    [ -z "$gap_first" ] && gap_first=$gap
    gap_last=$gap

    # rate dihitung mulai sampel ke-2
    arr_rate="-"; app_rate="-"
    if [ -n "$prev_recv" ]; then
        arr_rate="$(python3 -c "print(f'{($recv-$prev_recv)/$INTERVAL/1048576:.1f}')")"
        app_rate="$(python3 -c "print(f'{($replay-$prev_replay)/$INTERVAL/1048576:.1f}')")"
        sum_arr="$(python3 -c "print($sum_arr+($recv-$prev_recv)/$INTERVAL/1048576)")"
        sum_app="$(python3 -c "print($sum_app+($replay-$prev_replay)/$INTERVAL/1048576)")"
        n_rate=$((n_rate+1))
    fi
    prev_recv=$recv; prev_replay=$replay

    # wait event kategorisasi
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
# ANALISA & VONIS
# ---------------------------------------------------------------------------
bold "[ANALISA]"
avg_arr="-"; avg_app="-"
if [ "$n_rate" -gt 0 ]; then
    avg_arr="$(python3 -c "print(f'{$sum_arr/$n_rate:.1f}')")"
    avg_app="$(python3 -c "print(f'{$sum_app/$n_rate:.1f}')")"
fi
echo "  Rata-rata arrival (WAL datang) : ${avg_arr} MB/s"
echo "  Rata-rata apply  (WAL di-apply) : ${avg_app} MB/s"
echo "  apply_gap awal -> akhir         : $(python3 -c "print(f'{$gap_first/1048576:.1f}')") MB -> $(python3 -c "print(f'{$gap_last/1048576:.1f}')") MB"
echo "  Disk %util tertinggi teramati   : ${max_util_seen}%"
echo "  Sampel wait IO / konflik        : ${io_wait_hits} / ${conflict_hits} (dari ${COUNT})"
echo ""

GAP_GROWING="$(python3 -c "print(1 if $gap_last > $gap_first*1.2 and ($gap_last-$gap_first)>5*1048576 else 0)")"
APPLY_SLOWER="$(python3 -c "
a='${avg_arr}'; p='${avg_app}'
print(1 if (a!='-' and p!='-' and float(p) < float(a)*0.9) else 0)")"
HIGH_UTIL="$(python3 -c "print(1 if float('${max_util_seen}')>80 else 0)")"

if [ "$GAP_GROWING" = "1" ] || [ "$APPLY_SLOWER" = "1" ]; then
    red ">> VONIS: APPLY-BOUND. WAL menumpuk lebih cepat dari kemampuan apply standby."
    echo "   (gap membesar dan/atau apply_rate < arrival_rate)"
    echo ""
    if [ "$HIGH_UTIL" = "1" ] || [ "$io_wait_hits" -gt $((COUNT/3)) ]; then
        ylw "   PENYEBAB UTAMA: DISK I/O (util ${max_util_seen}%, banyak wait IO)."
        grn "   AKSI: upgrade storage Surabaya (NVMe/SSD), pisahkan WAL & data,"
        grn "         naikkan shared_buffers, periksa apakah disk DR lebih lambat dari Primary."
    elif [ "$conflict_hits" -gt 0 ]; then
        ylw "   PENYEBAB: RECOVERY CONFLICT (query di standby vs replay)."
        grn "   AKSI: tinjau hot_standby_feedback & max_standby_streaming_delay,"
        grn "         atau pindahkan query berat ke slave Jakarta."
    else
        ylw "   PENYEBAB: CPU SINGLE-THREAD. Proses 'startup' (redo) mentok 1 core,"
        ylw "   disk tidak sibuk & tidak ada konflik."
        grn "   AKSI: CPU dengan clock per-core lebih tinggi, kurangi volume WAL di Primary"
        grn "         (wal_compression, batch lebih kecil), pertimbangkan cascading replication."
    fi
elif [ "$avg_arr" != "-" ] && python3 -c "exit(0 if float('${avg_arr}')<1.0 else 1)" 2>/dev/null; then
    ylw ">> VONIS: WAL DATANG LAMBAT (arrival rendah, apply tidak menumpuk)."
    echo "   Apply sebenarnya idle/sanggup, tapi WAL sedikit yang masuk."
    grn "   -> Bottleneck kemungkinan di NETWORK. Jalankan repl_network_diag.sh dari Primary."
else
    grn ">> VONIS: SEHAT. Apply mengejar arrival, gap stabil, tidak ada lag signifikan."
    ylw "   Jika user tetap melihat lag, cek lagi saat JAM SIBUK (batch/checkpoint)."
fi
line
bold "Pasangkan dengan repl_network_diag.sh (sisi Primary) untuk gambaran lengkap:"
echo "  - Network script bilang single-stream cukup TAPI script ini APPLY-BOUND -> fokus DISK/CPU Surabaya."
echo "  - Script ini bilang arrival rendah -> balik ke network."
echo ""
