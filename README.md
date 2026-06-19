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
├── repl.env.example     # configuration template (committed)
├── repl.env             # your local configuration (git-ignored; copy of the example)
├── bin/                 # executable scripts run by operators
│   ├── repl_collect.sh
│   ├── repl_network_diag.sh
│   ├── repl_apply_diag.sh
│   ├── repl_sampler_primary.sh
│   ├── repl_sampler_standby.sh
│   └── repl_dashboard.py
├── lib/                 # shared library
│   └── repl_common.sh   # config loader + validation helpers
└── output/              # all runtime artifacts (git-ignored, created on demand)
    ├── metrics/         # sampler CSV files
    ├── reports/         # static collector reports
    ├── bursts/          # incident burst captures
    └── dashboards/      # generated HTML dashboards
```

All tunables live in **one** place — `repl.env`. Scripts never embed
configuration values; they load `repl.env` via `lib/repl_common.sh` and **abort**
if a variable an operation depends on is missing.

---

## Package Contents

| Script | Run on | Type | Purpose |
|--------|--------|------|---------|
| `bin/repl_collect.sh` | every node | **one-time** | Static OS + DB configuration snapshot |
| `bin/repl_network_diag.sh` | Primary | on-demand | Single-stream vs parallel test (iperf3) + WAL rate |
| `bin/repl_apply_diag.sh` | Standby | on-demand | Monitor apply gap, wait events, disk, redo CPU |
| `bin/repl_sampler_primary.sh` | Primary | **periodic** | Sample lag & WAL rate → CSV + burst captures |
| `bin/repl_sampler_standby.sh` | Standby | **periodic** | Sample apply/network/disk/CPU → CSV + burst captures |
| `bin/repl_dashboard.py` | anywhere | offline | Convert CSV → interactive HTML dashboard |

---

## Configuration

```bash
cp repl.env.example repl.env
$EDITOR repl.env          # adjust connection, output paths, and tunables
```

`repl.env` is sourced by bash and uses the `VAR="${VAR:-default}"` form, so any
value already exported in the environment still takes precedence — per-invocation
overrides keep working, e.g. `INTERVAL=5 bin/repl_sampler_standby.sh`.

Key settings (full list in `repl.env.example`):

| Variable | Default | Meaning |
|----------|---------|---------|
| `PGHOST`/`PGPORT`/`PGUSER`/`PGDATABASE` | libpq defaults | PostgreSQL connection |
| `OUTPUT_DIR` | `./output` | root for all generated artifacts |
| `METRICS_DIR` / `REPORTS_DIR` / `BURST_DIR` / `DASHBOARD_DIR` | under `OUTPUT_DIR` | per-type output folders |
| `INTERVAL` | 10 | seconds between sampler samples |
| `THRESHOLD_LAG_S` | 30 | lag threshold (s) that triggers a burst capture |
| `BURST_COOLDOWN` | 120 | minimum gap between bursts (s) |
| `COUNT` | 0 | 0 = sampler runs indefinitely; >0 = stop after N samples |
| `APPLY_INTERVAL` / `APPLY_COUNT` | 5 / 12 | cadence of the on-demand apply probe |
| `TARGET` | *(empty, required)* | standby IP for the network test (`iperf3 -s`) |
| `IPERF_PORT` / `DURATION` / `PARALLEL` / `LINK_MBPS` / `WAL_SAMPLE` | 5201 / 20 / 8 / 1000 / 15 | network test parameters |
| `PEERS` | *(empty, optional)* | space-separated peer IPs for RTT in the collector |

> Do **not** store the database password in `repl.env` — use `~/.pgpass`
> (`chmod 600`). Ideally run the scripts as the **`postgres`** user so config
> files and process-level metrics are readable.

Operations validate the variables they need and **abort** when one is missing —
e.g. `repl_network_diag.sh` refuses to run without `TARGET`.

---

## Prerequisites

```bash
# RHEL/Rocky
sudo yum install -y sysstat iperf3
# Debian/Ubuntu
sudo apt-get install -y sysstat iperf3
```

---

## Workflow

### 1) Static snapshot (once, on each node)
```bash
chmod +x bin/repl_collect.sh
# On the Primary, also measure RTT to both standbys:
bin/repl_collect.sh <standby-1-ip> <standby-2-ip>
# On the remote standby:
bin/repl_collect.sh <primary-ip>
```
Output: `output/reports/repl_collect_<host>_<ts>.txt` (passwords auto-redacted).

### 2) Periodic sampling (run continuously)

**On the Primary:**
```bash
chmod +x bin/repl_sampler_primary.sh
nohup bin/repl_sampler_primary.sh >/var/log/repl_sampler.log 2>&1 &
```

**On the remote standby:**
```bash
chmod +x bin/repl_sampler_standby.sh
nohup bin/repl_sampler_standby.sh >/var/log/repl_sampler.log 2>&1 &
```

Raw output:
- `output/metrics/primary_metrics.csv`, `output/metrics/standby_metrics.csv` (append, restart-safe)
- `output/bursts/burst_primary_<ts>.txt`, `output/bursts/burst_standby_<ts>.txt` (incident snapshots)

### 3) On-demand deep dives
```bash
bin/repl_network_diag.sh <standby-ip>   # on the Primary (start 'iperf3 -s' on the standby first)
bin/repl_apply_diag.sh                  # on the standby
```

### 4) Generate the dashboard
Collect the CSVs from each node into `output/metrics/`, then:
```bash
# load the output paths from repl.env, then render:
set -a; . ./repl.env; set +a
python3 bin/repl_dashboard.py
# or explicitly:
python3 bin/repl_dashboard.py --metrics-dir ./output/metrics --burst-dir ./output/bursts \
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
ExecStart=/opt/repl-diag/bin/repl_sampler_standby.sh   ; use _primary on the primary node
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

To prove **NETWORK-BOUND** vs link capacity, run `bin/repl_network_diag.sh`
(single-stream vs parallel test). For apply-side detail, run `bin/repl_apply_diag.sh`.

---

## Notes

- Start the samplers **before** an incident so the rolling history captures it.
- Sampling during **peak / batch hours** reveals the peak WAL rate, which drives lag.
- All output containing `primary_conninfo`/socket data has passwords redacted.
- For stronger long-term monitoring, consider Prometheus + `postgres_exporter` +
  `node_exporter`. This toolkit is for fast diagnosis without heavy setup.
```
