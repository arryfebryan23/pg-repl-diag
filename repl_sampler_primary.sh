#!/usr/bin/env bash
#
# repl_sampler_primary.sh  —  jalankan DI PRIMARY (background/systemd)
# -----------------------------------------------------------------------------
# Sampling berkala metrik replikasi sisi primary -> tulis RAW CSV.
# Saat replay_lag salah satu standby > ambang, lakukan BURST CAPTURE.
#
# OUTPUT (append, restart-safe):
#   $OUTDIR/primary_metrics.csv
#   $OUTDIR/burst_primary_<ts>.txt   (saat insiden)
#
# PAKAI:
#   ./repl_sampler_primary.sh
#   INTERVAL=10 THRESHOLD_LAG_S=30 OUTDIR=./repl_metrics ./repl_sampler_primary.sh
#   nohup ./repl_sampler_primary.sh >/var/log/repl_sampler.log 2>&1 &
# -----------------------------------------------------------------------------
set -u

INTERVAL="${INTERVAL:-10}"            # detik antar sampel
THRESHOLD_LAG_S="${THRESHOLD_LAG_S:-30}"
BURST_COOLDOWN="${BURST_COOLDOWN:-120}"   # jeda min antar burst (detik)
COUNT="${COUNT:-0}"                   # 0 = jalan terus
OUTDIR="${OUTDIR:-./repl_metrics}"
PGDB="${PGDATABASE:-postgres}"

PSQL="psql -d ${PGDB} -X -At -q -F|"
CSV="${OUTDIR}/primary_metrics.csv"
mkdir -p "$OUTDIR"

command -v psql >/dev/null 2>&1 || { echo "ERROR: psql tidak ada"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "ERROR: python3 tidak ada"; exit 1; }

IN_REC="$($PSQL -c 'SELECT pg_is_in_recovery();' 2>/dev/null)" || { echo "ERROR: gagal konek psql (cek PGHOST/.pgpass)"; exit 1; }
[ "$IN_REC" = "f" ] || { echo "ERROR: ini bukan PRIMARY (in_recovery=$IN_REC). Pakai script standby."; exit 1; }

HEADER="ts_epoch,ts_human,wal_lsn_bytes,wal_rate_mbps,standby,client_addr,state,sync_state,write_lag_s,flush_lag_s,replay_lag_s,total_lag_bytes"
[ -f "$CSV" ] || echo "$HEADER" > "$CSV"

trap 'echo "[stop] sampler primary dihentikan."; exit 0' INT TERM

echo "[start] sampler PRIMARY -> $CSV (interval ${INTERVAL}s, ambang lag ${THRESHOLD_LAG_S}s)"

prev_lsn=""; prev_ts=""; last_burst=0; iter=0
while :; do
    iter=$((iter+1))
    EPOCH="$(date +%s)"; HUMAN="$(date '+%Y-%m-%d %H:%M:%S')"

    LSN="$($PSQL -c "SELECT pg_wal_lsn_diff(pg_current_wal_lsn(),'0/0')::bigint;" 2>/dev/null)"
    [ -z "${LSN:-}" ] && { echo "[warn] query LSN gagal"; sleep "$INTERVAL"; continue; }

    RATE="-"
    if [ -n "$prev_lsn" ] && [ "$EPOCH" -gt "${prev_ts:-0}" ]; then
        RATE="$(python3 -c "print(f'{($LSN-$prev_lsn)/($EPOCH-$prev_ts)/1048576:.3f}')")"
    fi
    prev_lsn="$LSN"; prev_ts="$EPOCH"

    # Satu baris per standby
    mapfile -t ROWS < <($PSQL -c "
      SELECT coalesce(application_name,'-'),
             coalesce(host(client_addr),'local'),
             coalesce(state,'-'),
             coalesce(sync_state,'-'),
             round(coalesce(extract(epoch FROM write_lag),0)::numeric,2),
             round(coalesce(extract(epoch FROM flush_lag),0)::numeric,2),
             round(coalesce(extract(epoch FROM replay_lag),0)::numeric,2),
             coalesce(pg_wal_lsn_diff(sent_lsn, replay_lsn),0)::bigint
      FROM pg_stat_replication;" 2>/dev/null | tr ',' ';')

    max_lag=0
    if [ "${#ROWS[@]}" -eq 0 ]; then
        echo "${EPOCH},${HUMAN},${LSN},${RATE},(no-standby),-,-,-,0,0,0,0" >> "$CSV"
    else
        for r in "${ROWS[@]}"; do
            IFS='|' read -r app addr st sync wl fl rl tl <<< "$r"
            echo "${EPOCH},${HUMAN},${LSN},${RATE},${app},${addr},${st},${sync},${wl},${fl},${rl},${tl}" >> "$CSV"
            # cek ambang
            python3 -c "exit(0 if float('${rl:-0}')>${THRESHOLD_LAG_S} else 1)" 2>/dev/null && max_lag=1
        done
    fi

    # Burst capture saat ambang terlewati & cooldown habis
    if [ "$max_lag" = "1" ] && [ $((EPOCH - last_burst)) -ge "$BURST_COOLDOWN" ]; then
        last_burst="$EPOCH"
        BF="${OUTDIR}/burst_primary_$(date '+%Y%m%d_%H%M%S').txt"
        {
            echo "=== BURST PRIMARY @ ${HUMAN} (replay_lag > ${THRESHOLD_LAG_S}s) ==="
            echo "--- pg_stat_replication ---"
            psql -d "$PGDB" -X -x -c "SELECT * FROM pg_stat_replication;" 2>&1 | sed -E 's/(password=)[^ ]*/\1***/Ig'
            echo "--- pg_stat_wal ---"
            psql -d "$PGDB" -X -x -c "SELECT * FROM pg_stat_wal;" 2>&1
            echo "--- aktivitas WAL sender ---"
            psql -d "$PGDB" -X -c "SELECT pid,state,wait_event_type,wait_event,backend_type FROM pg_stat_activity WHERE backend_type LIKE '%walsender%';" 2>&1
            echo "--- iostat ---"; command -v iostat >/dev/null && iostat -dxy 1 3 2>&1
        } > "$BF"
        echo "[BURST] insiden tercatat -> $BF"
    fi

    [ "$COUNT" -gt 0 ] && [ "$iter" -ge "$COUNT" ] && { echo "[done] $COUNT sampel selesai."; break; }
    sleep "$INTERVAL"
done
