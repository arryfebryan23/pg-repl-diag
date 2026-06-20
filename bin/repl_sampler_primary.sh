#!/usr/bin/env bash
#
# bin/repl_sampler_primary.sh  —  run ON THE PRIMARY (background / systemd)
# -----------------------------------------------------------------------------
# Periodically samples primary-side replication metrics into a RAW CSV under
# METRICS_DIR. When any standby's replay_lag exceeds the threshold, it performs
# a BURST CAPTURE under BURST_DIR: a detailed snapshot of the incident.
#
# OUTPUT (append, restart-safe):
#   $METRICS_DIR/primary_metrics.csv
#   $BURST_DIR/burst_primary_<ts>.txt   (on incident)
#
# CONFIGURATION: all tunables live in repl.env (see repl.env.example).
#
# USAGE:
#   bin/repl_sampler_primary.sh
#   nohup bin/repl_sampler_primary.sh >/dev/null 2>&1 &
#
# Console output is mirrored automatically to a log file inside the project
# (LOG_DIR, default output/log/repl_sampler_primary.log) — no /var/log needed.
# -----------------------------------------------------------------------------
set -u

# Load central configuration (repl.env) and validation helpers.
# shellcheck source=../lib/repl_common.sh
. "$(dirname "${BASH_SOURCE[0]}")/../lib/repl_common.sh"

# Abort if any required tunable or output directory is missing.
require INTERVAL
require THRESHOLD_LAG_S
require BURST_COOLDOWN
require COUNT
require METRICS_DIR
require BURST_DIR
require PGDATABASE

PGDB="$PGDATABASE"

PSQL="psql -d ${PGDB} -X -At -q -F|"
CSV="${METRICS_DIR}/primary_metrics.csv"
ensure_dir "$METRICS_DIR" "$BURST_DIR"

command -v psql >/dev/null 2>&1 || die "psql not found"
command -v python3 >/dev/null 2>&1 || die "python3 not found"

IN_REC="$($PSQL -c 'SELECT pg_is_in_recovery();' 2>/dev/null)" || die "failed to connect via psql (check PGHOST/.pgpass)"
[ "$IN_REC" = "f" ] || die "this is NOT the PRIMARY (in_recovery=$IN_REC). Use the standby script."

HEADER="ts_epoch,ts_human,wal_lsn_bytes,wal_rate_mbps,standby,client_addr,state,sync_state,write_lag_s,flush_lag_s,replay_lag_s,total_lag_bytes"
[ -f "$CSV" ] || echo "$HEADER" > "$CSV"

trap 'log_info "primary sampler stopped."; exit 0' INT TERM

run_header "PRIMARY SAMPLER"
kv "CSV output"     "$CSV"
kv "Interval"       "${INTERVAL}s"
kv "Lag threshold"  "${THRESHOLD_LAG_S}s"
log_ok "primary sampler started"

prev_lsn=""; prev_ts=""; last_burst=0; iter=0
while :; do
    iter=$((iter+1))
    EPOCH="$(date +%s)"; HUMAN="$(date '+%Y-%m-%d %H:%M:%S')"

    LSN="$($PSQL -c "SELECT pg_wal_lsn_diff(pg_current_wal_lsn(),'0/0')::bigint;" 2>/dev/null)"
    [ -z "${LSN:-}" ] && { log_warn "LSN query failed"; sleep "$INTERVAL"; continue; }

    RATE="-"
    if [ -n "$prev_lsn" ] && [ "$EPOCH" -gt "${prev_ts:-0}" ]; then
        RATE="$(python3 -c "print(f'{($LSN-$prev_lsn)/($EPOCH-$prev_ts)/1048576:.3f}')")"
    fi
    prev_lsn="$LSN"; prev_ts="$EPOCH"

    # One row per standby
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
            # threshold check
            python3 -c "exit(0 if float('${rl:-0}')>${THRESHOLD_LAG_S} else 1)" 2>/dev/null && max_lag=1
        done
    fi

    # Burst capture when the threshold is exceeded and the cooldown has elapsed
    if [ "$max_lag" = "1" ] && [ $((EPOCH - last_burst)) -ge "$BURST_COOLDOWN" ]; then
        last_burst="$EPOCH"
        BF="${BURST_DIR}/burst_primary_$(date '+%Y%m%d_%H%M%S').txt"
        {
            echo "=== PRIMARY BURST @ ${HUMAN} (replay_lag > ${THRESHOLD_LAG_S}s) ==="
            echo "--- pg_stat_replication ---"
            psql -d "$PGDB" -X -x -c "SELECT * FROM pg_stat_replication;" 2>&1 | sed -E 's/(password=)[^ ]*/\1***/Ig'
            echo "--- pg_stat_wal ---"
            psql -d "$PGDB" -X -x -c "SELECT * FROM pg_stat_wal;" 2>&1
            echo "--- WAL sender activity ---"
            psql -d "$PGDB" -X -c "SELECT pid,state,wait_event_type,wait_event,backend_type FROM pg_stat_activity WHERE backend_type LIKE '%walsender%';" 2>&1
            echo "--- iostat ---"; command -v iostat >/dev/null && iostat -dxy 1 3 2>&1
        } > "$BF"
        log_evt "burst captured -> $BF"
    fi

    [ "$COUNT" -gt 0 ] && [ "$iter" -ge "$COUNT" ] && { log_ok "$COUNT samples complete."; break; }
    sleep "$INTERVAL"
done
