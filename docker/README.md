# Docker test cluster — 3× PostgreSQL 17 (cascading replication)

A throwaway, self-contained cluster to exercise **pg-repl-diag** end-to-end:

```
pg-primary  ──streams──▶  pg-standby1  ──streams──▶  pg-standby2
(PRIMARY)                 (local standby)            (remote DR standby)
```

| Node | Container | Host port | Role |
|------|-----------|-----------|------|
| Primary | `pg-primary` | `5432` | accepts writes |
| Standby 1 | `pg-standby1` | `5433` | streams from primary, cascades to standby2 |
| Standby 2 | `pg-standby2` | `5434` | streams from standby1 (DR) |

The image is `postgres:17` plus the host tools the toolkit needs (`python3`,
`iproute2`/`ss`, `sysstat`/`iostat`, `iperf3`, `ping`, `ps`). The whole repo is
bind-mounted at `/opt/pg-repl-diag` and runs **inside** each node, writing to
`./output/` on the host.

> Auth is `trust` and everything is disposable — **for testing only**.

---

## 1. Bring it up

```bash
cd docker
docker compose up -d --build
```

`pg-standby1` waits for the primary to be healthy, then clones it with
`pg_basebackup`; `pg-standby2` then clones `pg-standby1`. Watch progress:

```bash
docker compose logs -f pg-standby1 pg-standby2
docker compose ps                       # all three should become healthy
```

## 2. Verify replication

```bash
# Primary should list its connected standby (cascading -> only standby1 here):
docker exec -u postgres pg-primary \
  psql -x -c "SELECT application_name, client_addr, state, sync_state, replay_lag FROM pg_stat_replication;"

# standby1 should itself have a downstream (standby2):
docker exec -u postgres pg-standby1 \
  psql -x -c "SELECT application_name, client_addr, state FROM pg_stat_replication;"

# Both standbys are in recovery:
docker exec -u postgres pg-standby1 psql -At -c "SELECT pg_is_in_recovery();"   # t
docker exec -u postgres pg-standby2 psql -At -c "SELECT pg_is_in_recovery();"   # t
```

Quick end-to-end write test:

```bash
docker exec -u postgres pg-primary  psql -c "CREATE TABLE IF NOT EXISTS t(id int); INSERT INTO t VALUES (1);"
docker exec -u postgres pg-standby2 psql -At -c "SELECT count(*) FROM t;"        # -> 1 (after replay)
```

## 3. Run the toolkit

Run each command **on the right node** (`-w` sets the repo as working dir):

```bash
# Static snapshot — on every node
docker exec -u postgres -w /opt/pg-repl-diag pg-primary  bin/pg-repl-diag collect
docker exec -u postgres -w /opt/pg-repl-diag pg-standby1 bin/pg-repl-diag collect
docker exec -u postgres -w /opt/pg-repl-diag pg-standby2 bin/pg-repl-diag collect

# Apply-side probe — on a standby
docker exec -u postgres -w /opt/pg-repl-diag pg-standby2 bin/pg-repl-diag apply-check

# Periodic samplers — finite runs for a test (COUNT>0)
docker exec -u postgres -w /opt/pg-repl-diag pg-primary  bash -lc 'COUNT=20 bin/pg-repl-diag sample-primary'
docker exec -u postgres -w /opt/pg-repl-diag pg-standby2 bash -lc 'COUNT=20 bin/pg-repl-diag sample-standby'

# Network test (Primary -> standby1): start the iperf3 server on the TARGET first
docker exec -d pg-standby1 iperf3 -s
docker exec -u postgres -w /opt/pg-repl-diag pg-primary  bin/pg-repl-diag net-test

# Dashboard from collected CSVs
docker exec -u postgres -w /opt/pg-repl-diag pg-primary  bin/pg-repl-diag dashboard
```

Artifacts land in `../output/` on the host (`metrics/`, `reports/`, `bursts/`,
`dashboards/`, `log/`).

## 4. Generate lag (to trigger burst captures)

```bash
# Write load on the primary
docker exec -u postgres pg-primary pgbench -i -s 50 postgres
docker exec -u postgres pg-primary pgbench -T 120 -c 8 -j 4 postgres

# Force artificial REPLAY lag on the DR standby (reloadable):
docker exec -u postgres pg-standby2 \
  psql -c "ALTER SYSTEM SET recovery_min_apply_delay = '30s'; SELECT pg_reload_conf();"
```

With the delay set above `THRESHOLD_LAG_S` (default 30s), the standby sampler
writes burst captures to `output/bursts/`. Reset it with:

```bash
docker exec -u postgres pg-standby2 \
  psql -c "ALTER SYSTEM SET recovery_min_apply_delay = '0'; SELECT pg_reload_conf();"
```

## 5. Tear down

```bash
docker compose down          # keep data volumes
docker compose down -v       # also wipe the cluster (forces a fresh clone next time)
```

---

## Notes & troubleshooting

- **Connecting from the host:** `psql -h localhost -p 5432 -U postgres postgres`
  (5433 → standby1, 5434 → standby2).
- **`permission denied` running `bin/pg-repl-diag`:** the bind mount lost the
  exec bit — call it through bash instead, e.g.
  `docker exec -u postgres -w /opt/pg-repl-diag pg-primary bash bin/pg-repl-diag collect`.
- **Windows / Git Bash mangles `/opt/...` (e.g. `Cwd must be an absolute path`
  or `C:/Program Files/Git/opt/...`):** MSYS rewrites absolute paths passed to
  `docker.exe`. Run these from **PowerShell**, or `cd` inside the container
  instead of using `-w`, e.g.
  `docker exec -u postgres pg-primary bash -lc "cd /opt/pg-repl-diag && bin/pg-repl-diag collect"`,
  or prefix with `MSYS_NO_PATHCONV=1`.
- **Re-cloning a standby:** `docker compose down -v` (volumes hold the data dir;
  the entrypoint only clones when the data dir is empty).
- **Fan-out instead of cascading** (both standbys stream directly from the
  primary): set `UPSTREAM_HOST: pg-primary` for `pg-standby2` and point its
  `depends_on` at `pg-primary`.
- **`iostat`/`ss` show host-level data** because containers share the host
  kernel — fine for a functional test of the toolkit's plumbing.
