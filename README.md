# PostgreSQL Replication Lag Diagnostics Toolkit

A toolkit for diagnosing **replication lag** in multi-site PostgreSQL topologies
(e.g. Primary → local standby → remote DR standby). It separates the two root
causes that are routinely confused: a **network bottleneck** (single-stream TCP)
versus an **apply bottleneck** (standby disk/CPU).

All scripts are **read-only** against the database and have **no external
dependencies** (only `bash`, `psql`, `python3`; `iostat`/`mpstat` from the
`sysstat` package are optional).

---

## Repository Layout

```
.
├── repl.script.env      # SCRIPT/toolkit behaviour: output, logging, cadence, appearance (committed)
├── repl.env.example     # ENVIRONMENT template: PostgreSQL/OS/topology (committed)
├── repl.env             # your local environment config (git-ignored; copy of the example)
├── bin/                 # single entry point (put this dir on PATH)
│   └── pg-repl-diag     # dispatcher: routes sub-commands to libexec/
├── libexec/
│   └── pg-repl-diag/    # sub-command implementations (not called directly)
│       ├── collect          # pg-repl-diag collect
│       ├── net-test         # pg-repl-diag net-test
│       ├── apply-check      # pg-repl-diag apply-check
│       ├── sample-primary   # pg-repl-diag sample --role primary
│       ├── sample-standby   # pg-repl-diag sample --role standby
│       └── dashboard        # pg-repl-diag dashboard
├── lib/                 # shared library
│   ├── repl_common.sh   # config loader + validation + per-run logging
│   └── repl_format.sh   # shared console UI (banners, sections, status tags)
└── output/              # all runtime artifacts (git-ignored, created on demand)
    ├── metrics/         # sampler CSV files
    ├── reports/         # static collector reports
    ├── bursts/          # incident burst captures
    ├── dashboards/      # generated HTML dashboards
    └── log/             # per-run console logs (stdout+stderr of each command)
```

Configuration is split by concern across **two** files, both loaded via
`lib/repl_common.sh`, which **aborts** if a variable an operation depends on is
missing:

- **`repl.script.env`** — *script / toolkit behaviour* (output dirs, logging,
  sampling cadence, thresholds, console appearance). Identical on every node and
  committed to git.
- **`repl.env`** — *deployment environment* (PostgreSQL connection, target /
  peer IPs, link bandwidth). Site-specific, copied from `repl.env.example`, and
  git-ignored so site values are never committed.

Scripts never embed configuration values.

---

## Package Contents

Everything is driven through a single command, **`pg-repl-diag`**. Put `bin/` on
your `PATH` (or call `bin/pg-repl-diag` directly) and run `pg-repl-diag help` for
the full list.

| Command | Run on | Type | Purpose |
|---------|--------|------|---------|
| `pg-repl-diag collect` | every node | **one-time** | Static OS + DB configuration snapshot |
| `pg-repl-diag net-test` | Primary | on-demand | Single-stream vs parallel test (iperf3) + WAL rate |
| `pg-repl-diag apply-check` | Standby | on-demand | Monitor apply gap, wait events, disk, redo CPU |
| `pg-repl-diag sample --role primary` | Primary | **periodic** | Sample lag & WAL rate → CSV + burst captures |
| `pg-repl-diag sample --role standby` | Standby | **periodic** | Sample apply/network/disk/CPU → CSV + burst captures |
| `pg-repl-diag dashboard` | anywhere | offline | Convert CSV → interactive HTML dashboard |

---

## Configuration

```bash
cp repl.env.example repl.env
$EDITOR repl.env          # adjust connection + topology for THIS node
# (toolkit behaviour lives in repl.script.env and rarely needs changes)
```

Both files are sourced by bash and use the `VAR="${VAR:-default}"` form, so any
value already exported in the environment still takes precedence — per-invocation
overrides keep working, e.g. `INTERVAL=5 pg-repl-diag sample --role standby`.

**Environment** — site-specific (`repl.env`, from `repl.env.example`):

| Variable | Default | Meaning |
|----------|---------|---------|
| `PGHOST`/`PGPORT`/`PGUSER`/`PGDATABASE` | libpq defaults | PostgreSQL connection |
| `TARGET` | *(empty, required for network test)* | standby IP running `iperf3 -s` |
| `LINK_MBPS` | 1000 | this link's per-direction bandwidth (Mbps), for the BDP calc |
| `PEERS` | *(empty, optional)* | space-separated peer IPs for RTT in the collector |

**Script / toolkit** — same on every node (`repl.script.env`):

| Variable | Default | Meaning |
|----------|---------|---------|
| `OUTPUT_DIR` | `./output` | root for all generated artifacts |
| `METRICS_DIR` / `REPORTS_DIR` / `BURST_DIR` / `DASHBOARD_DIR` | under `OUTPUT_DIR` | per-type output folders |
| `LOG_DIR` | `$OUTPUT_DIR/log` | per-run console logs (every command mirrors stdout+stderr here; set `REPL_NO_LOG=1` to disable) |
| `INTERVAL` | 10 | seconds between sampler samples |
| `THRESHOLD_LAG_S` | 30 | lag threshold (s) that triggers a burst capture |
| `BURST_COOLDOWN` | 120 | minimum gap between bursts (s) |
| `COUNT` | 0 | 0 = sampler runs indefinitely; >0 = stop after N samples |
| `APPLY_INTERVAL` / `APPLY_COUNT` | 5 / 12 | cadence of the on-demand apply probe |
| `IPERF_PORT` / `DURATION` / `PARALLEL` / `WAL_SAMPLE` | 5201 / 20 / 8 / 15 | network test parameters |
| `REPL_TOOLKIT_NAME` / `REPL_TOOLKIT_VERSION` | toolkit name / `1.0` | shown in the console banner of every script |
| `REPL_WIDTH` | 74 | banner / rule width in columns |
| `REPL_COLOR` | `auto` | `auto` (color only on a terminal) / `always` / `never` |

All scripts share **one console look & feel** via `lib/repl_format.sh` (banners,
sections, `[INFO]`/`[ OK ]`/`[WARN]`/`[FAIL]` status tags, and `VERDICT` blocks).
Color is automatic on a terminal and suppressed when output is redirected or
`NO_COLOR` is set, so log files stay clean.

> Do **not** store the database password in `repl.env` — use `~/.pgpass`
> (`chmod 600`). Ideally run the scripts as the **`postgres`** user so config
> files and process-level metrics are readable.

Operations validate the variables they need and **abort** when one is missing —
e.g. `pg-repl-diag net-test` refuses to run without `TARGET`.

---

## Prerequisites

### Platform

**Linux only.** The scripts read `/proc`, `/sys`, and `net.ipv4.*` sysctls and rely
on `iproute2` / `sysstat`, so they do **not** run on macOS or Windows. Run them
directly on the PostgreSQL hosts (Primary, local standby, remote DR standby) — the
host is where the disk, CPU, and TCP socket being diagnosed actually live.
`bash` **4+** is required (the scripts use arrays, `mapfile`, and process substitution).

### OS user

Run the scripts as the **`postgres`** OS user (or `root`). This is needed so that:

- `postgresql.auto.conf` inside `data_directory` is readable (collector §19);
- the redo/`startup` process CPU can be read from `/proc/<pid>/stat`
  (standby sampler `cpu_startup_pct` column);
- `ss -tinp` can show the **PID** owning the replication socket;
- `ethtool` (NIC speed/duplex) works — it needs root.

Running as an unrelated user does not crash the scripts, but the items above are
silently reported as unavailable.

### Database access & privileges

- Connect via libpq env vars (`PGHOST` / `PGPORT` / `PGUSER` / `PGDATABASE` in `repl.env`).
- Put the password in **`~/.pgpass`** (`chmod 600`) — never in `repl.env`.
- The role needs read access to the monitoring views. Grant **`pg_monitor`**
  (`GRANT pg_monitor TO youruser;`) or use a superuser. Without it, `client_addr`,
  `wait_event`, and query text in `pg_stat_activity` / `pg_stat_replication` are
  hidden, which weakens the apply-side and socket diagnosis.
- All queries are **strictly read-only**.
- **PostgreSQL 12+** works; **14+** recommended (`pg_stat_wal`). `pg_stat_checkpointer`
  (PG17+) and a few view columns are version-gated and skipped gracefully on older releases.

### Ports & firewall

| Port | Direction | Used by | Required? |
|------|-----------|---------|-----------|
| **5432** (`PGPORT`) | standby → primary | streaming replication **and** every script's `psql` | **Yes** |
| **5201** (`IPERF_PORT`) | primary → standby | `pg-repl-diag net-test` only | Only for the network test |
| **ICMP** (ping) | primary ↔ standby | RTT / packet-loss baseline in the collector & network test | Recommended |

For the network test, start `iperf3 -s` on the standby (listening on `IPERF_PORT`,
default 5201) and make sure that port is reachable from the Primary.

### Required packages / commands

Present on a standard Linux + PostgreSQL install; listed for completeness:

| Package | Provides | Why it's needed |
|---------|----------|-----------------|
| `bash` (4+) | shell | arrays / `mapfile` / process substitution |
| postgresql client | `psql` | every script queries the DB |
| `python3` | `python3` | JSON parsing (iperf3) and float math |
| coreutils + `awk`/`sed`/`grep` | `date`, `df`, `hostname`, `getconf`, … | text processing & math |
| `procps` | `ps`, `sysctl`, `free` | process lookup, TCP sysctls, memory |
| `iproute2` | `ss`, `ip` | replication-socket RTT/retransmits, addressing |

**Required only for `pg-repl-diag net-test`:**

| Package | Provides | Note |
|---------|----------|------|
| `iperf3` | `iperf3` | needed on **both** Primary (client) and standby (`iperf3 -s`) |
| `iputils` | `ping` | RTT & packet-loss baseline |

### Optional packages — what you lose without them

Everything below degrades gracefully; the scripts keep running and only the
listed data goes uncollected.

| Package | Command | Used for | If missing |
|---------|---------|----------|------------|
| `sysstat` | `iostat` | disk `%util` / `await` / busiest device | `disk_util` / `disk_dev` / `disk_await` recorded as `0` / `-`; the **"DISK I/O" apply-side root cause cannot be confirmed** |
| `sysstat` | `mpstat` | per-core CPU inside standby **burst captures** | that block is omitted from `burst_standby_*.txt` |
| `util-linux` | `lscpu` | CPU model / per-core clock (collector §2) | falls back to `/proc/cpuinfo` |
| `util-linux` | `lsblk` | block devices / I/O scheduler (collector §4) | section skipped |
| `ethtool` | `ethtool` | NIC speed/duplex/ring buffers (collector §6) | shows "(ethtool not available)" |
| `chrony` / `ntp` | `chronyc` / `ntpq` | clock-sync check — skew invalidates lag numbers (collector §7) | warns; verify the three nodes share a synced clock manually |
| `net-tools` | `netstat` | global retransmit counters (collector §8) | line skipped (`ss` still gives per-socket data) |

### Install

```bash
# RHEL/Rocky
sudo yum install -y sysstat iperf3 ethtool chrony
# Debian/Ubuntu
sudo apt-get install -y sysstat iperf3 ethtool chrony
```

> `iperf3` is only needed if you run the network test. `sysstat` is the most
> impactful optional package — without `iostat` you cannot distinguish a
> **disk-bound** standby from a **CPU-bound** one.

---

## Workflow

> Make the dispatcher executable once: `chmod +x bin/pg-repl-diag`. Put `bin/` on
> your `PATH` to drop the `bin/` prefix below, or call `bin/pg-repl-diag …` directly.

### 1) Static snapshot (once, on each node)
```bash
# On the Primary, also measure RTT to both standbys:
pg-repl-diag collect <standby-1-ip> <standby-2-ip>
# On the remote standby:
pg-repl-diag collect <primary-ip>
```
Output: `output/reports/repl_collect_<host>_<ts>.txt` (passwords auto-redacted).

### 2) Periodic sampling (run continuously)

**On the Primary:**
```bash
nohup pg-repl-diag sample --role primary >/dev/null 2>&1 &   # console log -> output/log/
```

**On the remote standby:**
```bash
nohup pg-repl-diag sample --role standby >/dev/null 2>&1 &   # console log -> output/log/
```

Raw output:
- `output/metrics/primary_metrics.csv`, `output/metrics/standby_metrics.csv` (append, restart-safe)
- `output/bursts/burst_primary_<ts>.txt`, `output/bursts/burst_standby_<ts>.txt` (incident snapshots)

### 3) On-demand deep dives
```bash
pg-repl-diag net-test <standby-ip>   # on the Primary (start 'iperf3 -s' on the standby first)
pg-repl-diag apply-check             # on the standby
```

### 4) Generate the dashboard
Collect the CSVs from each node into `output/metrics/`, then:
```bash
# the dispatcher loads the output paths from the config for you:
pg-repl-diag dashboard
# or point at explicit paths:
pg-repl-diag dashboard --metrics-dir ./output/metrics --burst-dir ./output/bursts \
                       --out ./output/dashboards/dashboard.html
```
Open the generated `output/dashboards/dashboard.html` in a browser (local file, no internet required).

---

## Running as a systemd service (optional, cleaner)

`/etc/systemd/system/repl-sampler.service`:
```ini
[Unit]
Description=PG Replication Sampler
After=postgresql.service

[Service]
User=postgres
WorkingDirectory=/opt/repl-diag
Environment=REPL_ENV_FILE=/opt/repl-diag/repl.env
ExecStart=/opt/repl-diag/bin/pg-repl-diag sample --role standby   ; use --role primary on the primary node
Restart=always

[Install]
WantedBy=multi-user.target
```
```bash
sudo systemctl daemon-reload && sudo systemctl enable --now repl-sampler
```

---

## Reading the Dashboard

The top panel provides an **automatic verdict** plus summary cards. Key charts:

- **Replication Lag (time_lag)** — the symptom users feel.
- **Arrival vs Apply Rate** — if *apply* < *arrival*, the standby is falling behind → apply-bound.
- **Apply Gap** — if it keeps rising → apply is not catching up.
- **Resource Saturation** — disk %util & redo CPU (0–100 scale). Correlate with lag spikes.
- **Network Quality** — rtt & retransmits on the replication socket.
- **Wait Event Distribution** — where the redo process spends its time.
- **WAL Generation Rate (primary)** & **per-standby lag** — compare standbys.

### Decision Tree

```
High lag?
├─ Apply < Arrival  &  gap growing  → APPLY-BOUND
│   ├─ high disk %util / IO waits    → standby disk I/O (upgrade storage, separate WAL)
│   ├─ redo CPU ~100% (1 core)       → single-thread CPU (higher per-core clock, reduce WAL)
│   └─ Recovery/Conflict waits       → query conflict (tune hot_standby_feedback)
└─ Low arrival, no apply backlog → NETWORK-BOUND
    ├─ rising retransmits / loss      → loss-bound    → switch congestion control to BBR
    └─ high rtt, retransmits ~0       → latency-bound → raise TCP buffers above the BDP
```

To prove **NETWORK-BOUND** vs link capacity, run `pg-repl-diag net-test`
(single-stream vs parallel test). For apply-side detail, run `pg-repl-diag apply-check`.

---

## Notes

- Start the samplers **before** an incident so the rolling history captures it.
- Sampling during **peak / batch hours** reveals the peak WAL rate, which drives lag.
- All output containing `primary_conninfo`/socket data has passwords redacted.
- For stronger long-term monitoring, consider Prometheus + `postgres_exporter` +
  `node_exporter`. This toolkit is for fast diagnosis without heavy setup.
```
