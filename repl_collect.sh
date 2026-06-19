#!/usr/bin/env bash
#
# repl_collect.sh
# -----------------------------------------------------------------------------
# Collector konfigurasi EXISTING (OS + PostgreSQL) yang relevan dengan
# diagnosa replication lag. READ-ONLY — tidak mengubah apapun.
#
# Jalankan di SETIAP node (Primary JKT, Slave JKT, Slave SBY) untuk
# perbandingan. Output: satu file report .txt yang bisa diserahkan.
#
# CARA PAKAI:
#   ./repl_collect.sh                          # collect lokal
#   ./repl_collect.sh <ip-peer1> <ip-peer2>    # + ukur RTT ke node lain
#   (set PGHOST/PGPORT/PGUSER/PGDATABASE atau pakai .pgpass bila perlu)
#
# Idealnya dijalankan sebagai user 'postgres' (atau root) agar bisa baca
# file config & beberapa metrik OS.
# -----------------------------------------------------------------------------

set -u

PGDB="${PGDATABASE:-postgres}"
PEERS=("$@")
TS="$(date +%Y%m%d_%H%M%S)"
HOST="$(hostname 2>/dev/null || echo node)"
OUT="repl_collect_${HOST}_${TS}.txt"

PSQL_S="psql -d ${PGDB} -X -At -q"            # scalar
PSQL_T="psql -d ${PGDB} -X -q -P pager=off"   # tabel

have(){ command -v "$1" >/dev/null 2>&1; }
redact(){ sed -E 's/(password[[:space:]]*=[[:space:]]*)[^[:space:]"'"'"']+/\1***REDACTED***/Ig'; }

exec 3>&1                                       # fd3 = terminal untuk progress
prog(){ echo ">>> $*" >&3; }
sec(){ printf '\n========================================================================\n== %s\n========================================================================\n' "$*"; prog "$*"; }
sub(){ printf '\n--- %s ---\n' "$*"; }
run(){ # run "deskripsi" cmd...
    sub "$1"; shift
    if have "$1" 2>/dev/null || type "$1" >/dev/null 2>&1; then
        "$@" 2>&1 || echo "(gagal / butuh hak akses lebih tinggi)"
    else
        echo "(perintah '$1' tidak tersedia)"
    fi
}
psql_ok=0

# ============================================================================
collect() {

printf 'REPL DIAG COLLECTOR\nHost   : %s\nWaktu  : %s\nUser   : %s\n' \
    "$HOST" "$(date)" "$(whoami)"

# ---------------------------------------------------------------------------
sec "1. OS & KERNEL"
run "uname"        uname -a
run "os-release"   cat /etc/os-release
run "uptime"       uptime

# ---------------------------------------------------------------------------
sec "2. CPU  (penting: replay WAL single-thread, clock per-core menentukan)"
if have lscpu; then run "lscpu" lscpu
else run "cpuinfo" sh -c "grep -E 'model name|MHz|processor' /proc/cpuinfo | sort -u"; fi

# ---------------------------------------------------------------------------
sec "3. MEMORY & VM TUNING"
run "free"          free -h
run "hugepages"     sh -c "grep -i huge /proc/meminfo"
run "THP"           sh -c "cat /sys/kernel/mm/transparent_hugepage/enabled 2>/dev/null"
run "vm sysctl"     sh -c "sysctl vm.swappiness vm.dirty_ratio vm.dirty_background_ratio vm.overcommit_memory 2>/dev/null"

# ---------------------------------------------------------------------------
sec "4. DISK & FILESYSTEM  (penting untuk kecepatan apply di standby)"
run "df"            df -hT
if have lsblk; then run "lsblk" lsblk -o NAME,TYPE,SIZE,FSTYPE,ROTA,MOUNTPOINT,SCHED; fi
run "io scheduler"  sh -c "for q in /sys/block/*/queue/scheduler; do echo \"\$q: \$(cat \$q)\"; done 2>/dev/null"
run "mount options" sh -c "mount | grep -E 'ext4|xfs|zfs' "

# ---------------------------------------------------------------------------
sec "5. NETWORK — SYSCTL TCP  (inti diagnosa single-stream throughput)"
run "congestion aktif"    sh -c "sysctl net.ipv4.tcp_congestion_control"
run "congestion tersedia" sh -c "sysctl net.ipv4.tcp_available_congestion_control"
run "buffer & window"     sh -c "sysctl net.core.rmem_max net.core.wmem_max \
    net.ipv4.tcp_rmem net.ipv4.tcp_wmem net.ipv4.tcp_window_scaling \
    net.ipv4.tcp_slow_start_after_idle net.ipv4.tcp_sack net.ipv4.tcp_timestamps \
    net.ipv4.tcp_mtu_probing net.core.netdev_max_backlog net.core.somaxconn 2>/dev/null"
run "default qdisc"       sh -c "sysctl net.core.default_qdisc 2>/dev/null"

# ---------------------------------------------------------------------------
sec "6. NETWORK — NIC, MTU, ROUTE"
run "ip addr"   sh -c "ip -br addr 2>/dev/null || ip addr"
run "MTU/link"  sh -c "ip -br link 2>/dev/null || ip link"
run "route"     sh -c "ip route 2>/dev/null"
if have ethtool; then
    for IF in $(ip -br link 2>/dev/null | awk '$2=="UP"{print $1}' | grep -v '^lo'); do
        sub "ethtool ${IF} (speed/duplex)"; ethtool "$IF" 2>&1 | grep -Ei 'speed|duplex|link detected' || echo "(perlu root)"
        sub "ethtool -g ${IF} (ring buffer)"; ethtool -g "$IF" 2>&1 | head -20 || true
    done
else sub "ethtool"; echo "(ethtool tidak tersedia)"; fi

# ---------------------------------------------------------------------------
sec "7. WAKTU / CLOCK SYNC  (skew jam membuat pengukuran lag tidak akurat!)"
run "timedatectl" sh -c "timedatectl 2>/dev/null"
if have chronyc; then run "chrony tracking" chronyc tracking
elif have ntpq;  then run "ntpq" ntpq -p
else echo "(chrony/ntp tidak terdeteksi — pastikan jam ketiga node sinkron)"; fi

# ---------------------------------------------------------------------------
sec "8. KONEKSI TCP REPLIKASI LIVE  (rtt, retrans, cwnd dari socket nyata)"
run "socket :5432" sh -c "ss -tinp 2>/dev/null '( sport = :5432 or dport = :5432 )' | redact || echo '(tidak ada / perlu root utk PID)'"
run "retransmit global" sh -c "netstat -s 2>/dev/null | grep -i -E 'retrans|segments' | head"

# ---------------------------------------------------------------------------
sec "9. RTT KE PEER"
if [ "${#PEERS[@]}" -eq 0 ]; then
    echo "(tidak ada IP peer diberikan. Jalankan: $0 <ip-peer1> <ip-peer2>)"
else
    for P in "${PEERS[@]}"; do
        sub "ping $P"; ping -c 20 -i 0.2 -q "$P" 2>&1 | grep -E 'loss|rtt|round-trip' || echo "(tidak terjangkau)"
    done
fi

# ---------------------------------------------------------------------------
sec "10. LIMITS"
run "ulimit" sh -c "ulimit -a"

# ===========================================================================
#  POSTGRESQL
# ===========================================================================
sec "11. POSTGRESQL — IDENTITAS & PERAN"
if VER="$($PSQL_S -c 'SELECT version();' 2>/dev/null)"; then
    psql_ok=1
    echo "version          : $VER"
    ROLE="$($PSQL_S -c "SELECT CASE WHEN pg_is_in_recovery() THEN 'STANDBY' ELSE 'PRIMARY' END;" 2>/dev/null)"
    echo "peran (role)     : $ROLE"
    echo "start time       : $($PSQL_S -c 'SELECT pg_postmaster_start_time();' 2>/dev/null)"
    echo "config_file      : $($PSQL_S -c 'SHOW config_file;' 2>/dev/null)"
    echo "data_directory   : $($PSQL_S -c 'SHOW data_directory;' 2>/dev/null)"
else
    echo "(!) Tidak bisa konek psql. Set PGHOST/PGPORT/PGUSER/.pgpass atau jalankan sebagai user postgres."
    echo "    Bagian DB di-skip; bagian OS di atas tetap berguna."
fi

if [ "$psql_ok" = "1" ]; then
    sec "12. PARAMETER REPLIKASI & WAL  (eksplisit, walau default)"
    $PSQL_T -c "
      SELECT name, setting, unit, source
      FROM pg_settings
      WHERE name IN (
        'wal_level','max_wal_senders','max_replication_slots','wal_compression',
        'wal_keep_size','synchronous_commit','synchronous_standby_names',
        'hot_standby','hot_standby_feedback','max_standby_streaming_delay',
        'recovery_min_apply_delay','primary_conninfo','primary_slot_name',
        'checkpoint_timeout','checkpoint_completion_target','max_wal_size','min_wal_size',
        'shared_buffers','effective_cache_size','wal_buffers','full_page_writes',
        'wal_writer_delay','listen_addresses','max_connections'
      ) ORDER BY name;" 2>&1 | redact

    sec "13. SEMUA PARAMETER NON-DEFAULT  (yang sengaja di-set)"
    $PSQL_T -c "
      SELECT name, setting, unit, source
      FROM pg_settings
      WHERE source NOT IN ('default','override','client')
      ORDER BY source, name;" 2>&1 | redact

    if [ "${ROLE:-}" = "PRIMARY" ]; then
        sec "14. [PRIMARY] STATUS REPLIKASI"
        $PSQL_T -x -c "SELECT * FROM pg_stat_replication;" 2>&1 | redact
        sub "lag per standby (bytes)"
        $PSQL_T -c "
          SELECT application_name, client_addr, state, sync_state,
                 pg_size_pretty(pg_wal_lsn_diff(sent_lsn, replay_lsn)) AS total_lag,
                 write_lag, flush_lag, replay_lag
          FROM pg_stat_replication;" 2>&1
        sub "laju generate WAL (pg_stat_wal, PG14+)"
        $PSQL_T -x -c "SELECT * FROM pg_stat_wal;" 2>&1 || echo "(pg_stat_wal tidak ada)"
    else
        sec "14. [STANDBY] STATUS RECOVERY"
        $PSQL_T -x -c "
          SELECT pg_is_in_recovery() AS in_recovery,
                 pg_last_wal_receive_lsn() AS receive_lsn,
                 pg_last_wal_replay_lsn()  AS replay_lsn,
                 pg_size_pretty(pg_wal_lsn_diff(pg_last_wal_receive_lsn(),
                                                pg_last_wal_replay_lsn())) AS belum_diapply,
                 pg_last_xact_replay_timestamp() AS last_replay_ts,
                 round(extract(epoch FROM (now()-pg_last_xact_replay_timestamp()))::numeric,1) AS time_lag_detik;" 2>&1
        sub "proses startup (redo) sedang nunggu apa"
        $PSQL_T -c "SELECT backend_type, state, wait_event_type, wait_event
                    FROM pg_stat_activity WHERE backend_type='startup';" 2>&1
    fi

    sec "15. REPLICATION SLOTS"
    $PSQL_T -x -c "SELECT slot_name, slot_type, active, wal_status,
                          pg_size_pretty(safe_wal_size) AS safe_wal_size,
                          restart_lsn FROM pg_replication_slots;" 2>&1

    sec "16. CHECKPOINT / BGWRITER"
    $PSQL_T -x -c "SELECT * FROM pg_stat_bgwriter;" 2>&1
    $PSQL_T -x -c "SELECT * FROM pg_stat_checkpointer;" 2>&1 || echo "(pg_stat_checkpointer hanya PG17+)"

    sec "17. ARCHIVER"
    $PSQL_T -x -c "SELECT * FROM pg_stat_archiver;" 2>&1

    sec "18. UKURAN DATABASE & EXTENSION"
    $PSQL_T -c "SELECT datname, pg_size_pretty(pg_database_size(datname)) AS size
                FROM pg_database ORDER BY pg_database_size(datname) DESC LIMIT 15;" 2>&1
    $PSQL_T -c "SELECT extname, extversion FROM pg_extension ORDER BY 1;" 2>&1

    sec "19. ISI postgresql.auto.conf  (override via ALTER SYSTEM, password diredaksi)"
    AUTOCONF="$($PSQL_S -c 'SHOW data_directory;' 2>/dev/null)/postgresql.auto.conf"
    if [ -r "$AUTOCONF" ]; then cat "$AUTOCONF" | redact; else echo "(tidak terbaca: $AUTOCONF — jalankan sebagai user postgres)"; fi
fi

printf '\n======================== SELESAI ========================\n'
}

# ============================================================================
prog "Mengumpulkan data ke: $OUT"
collect > "$OUT" 2>&1
prog "Selesai. File report: $OUT"
echo ""
echo "Serahkan file '$OUT' ini untuk analisa."
echo "Jalankan script yang sama di KETIGA node agar bisa dibandingkan."
