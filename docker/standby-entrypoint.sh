#!/usr/bin/env bash
# Entrypoint for the standby containers. On first start (empty data dir) it
# clones the upstream node with pg_basebackup (-R writes standby.signal +
# primary_conninfo, -C -S creates a physical replication slot on the upstream),
# then hands off to the standard postgres entrypoint. On later starts the data
# dir already exists, so it just starts streaming again.
set -Eeuo pipefail

: "${UPSTREAM_HOST:?set UPSTREAM_HOST (the node to replicate from)}"
: "${SLOT_NAME:?set SLOT_NAME (unique physical slot name)}"
PGDATA="${PGDATA:-/var/lib/postgresql/data}"
UPSTREAM_PORT="${UPSTREAM_PORT:-5432}"
REPL_USER="${REPL_USER:-postgres}"

if [ ! -s "${PGDATA}/PG_VERSION" ]; then
    echo "[standby] empty data dir -> cloning from ${UPSTREAM_HOST}:${UPSTREAM_PORT}"
    mkdir -p "${PGDATA}"
    chown -R postgres:postgres "${PGDATA}"
    chmod 700 "${PGDATA}"

    echo "[standby] waiting for upstream ${UPSTREAM_HOST} to accept connections..."
    until gosu postgres pg_isready -h "${UPSTREAM_HOST}" -p "${UPSTREAM_PORT}" -U "${REPL_USER}" -q; do
        sleep 2
    done

    echo "[standby] running pg_basebackup (slot=${SLOT_NAME})..."
    gosu postgres pg_basebackup \
        -h "${UPSTREAM_HOST}" -p "${UPSTREAM_PORT}" -U "${REPL_USER}" \
        -D "${PGDATA}" -Fp -Xs -R -P \
        -C -S "${SLOT_NAME}"
    echo "[standby] clone complete (standby.signal + primary_conninfo written by -R)"
else
    echo "[standby] existing data dir -> resuming as standby of ${UPSTREAM_HOST}"
fi

exec docker-entrypoint.sh postgres
