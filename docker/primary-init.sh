#!/usr/bin/env bash
# Runs ONCE on the primary, during first initialization
# (/docker-entrypoint-initdb.d). It enables streaming replication and opens
# pg_hba to replication connections from the compose network. The official
# entrypoint restarts the server after these scripts, so the file edits below
# take effect on the real start.
#
# Wrapped in a subshell so that if the official entrypoint *sources* this file
# (it does when the file is not marked executable, e.g. over a Windows bind
# mount), our `set -e` does not leak into the entrypoint's own shell.
(
set -Eeuo pipefail

echo "[primary-init] applying replication settings to postgresql.conf"
cat >> "${PGDATA}/postgresql.conf" <<'CONF'

# --- added by pg-repl-diag docker test harness ---
listen_addresses = '*'
wal_level = replica
max_wal_senders = 10
max_replication_slots = 10
hot_standby = on
wal_log_hints = on
wal_keep_size = '512MB'
CONF

echo "[primary-init] opening pg_hba.conf for replication (trust, test cluster)"
cat >> "${PGDATA}/pg_hba.conf" <<'HBA'

# --- replication for the test cluster (trust — DO NOT use in production) ---
host    replication     all     all     trust
host    all             all     all     trust
HBA
)
