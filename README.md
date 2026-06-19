# PostgreSQL Replication Lag Diagnostics Toolkit

A toolkit for diagnosing **replication lag** in multi-site PostgreSQL topologies
(e.g. Primary → local standby → remote DR standby). It separates the two root
causes that are routinely confused: a **network bottleneck** (single-stream TCP)
versus an **apply bottleneck** (standby disk/CPU).

All scripts are **read-only** against the database and have **no external
dependencies** (only `bash`, `psql`, `python3`; `iostat`/`mpstat` from the
`sysstat` package are optional).

---

## Package Contents

| File | Run on | Type | Purpose |
|------|--------|------|---------|
| `repl_collect.sh` | every node | **one-time** | Static OS + DB configuration snapshot |
| `repl_network_diag.sh` | Primary | on-demand | Single-stream vs parallel test (iperf3) + WAL rate |
| `repl_apply_diag.sh` | Standby | on-demand | Monitor apply gap, wait events, disk, redo CPU |
| `repl_sampler_primary.sh` | Primary | **periodic** | Sample lag & WAL rate → raw CSV + burst captures |
| `repl_sampler_standby.sh` | Standby | **periodic** | Sample apply/network/disk/CPU → raw CSV + burst captures |
| `repl_dashboard.py` | anywhere | offline | Convert raw CSV → interactive HTML dashboard |

---

## Concept: One-Time vs Periodic

- **One-time (static):** OS/PG versions, CPU, disk, TCP sysctl, all `pg_settings`.
  Collected by `repl_collect.sh`. Run once, or whenever something changes. Useful
  for **comparing nodes** (why one standby is smooth while another lags).
- **Periodic (dynamic):** lag, arrival/apply rate, wait events, disk %util, redo
  CPU, rtt/retransmits. Collected by the samplers. They must sample continuously
  so that **when an incident occurs, the data is already recorded** even if nobody
  is watching.

> Some metrics are **instantaneous** (wait events, rtt, retransmits) — worthless
> if inspected after the fact. Hence the tight sampling interval (default 10s) plus
> automatic **burst capture** when lag crosses the threshold.

---

## Prerequisites

```bash
# RHEL/Rocky
sudo yum install -y sysstat iperf3
# Debian/Ubuntu
sudo apt-get install -y sysstat iperf3
```

Passwordless `psql` access — set one of:
```bash
export PGHOST=/var/run/postgresql PGPORT=5432 PGUSER=postgres PGDATABASE=postgres
# or use ~/.pgpass  (chmod 600)
```
Ideally run as the **`postgres`** user so the scripts can read config files and
process-level metrics.

---

## Workflow

### 1) Static snapshot (once, on each node)
```bash
chmod +x repl_collect.sh
# On the Primary, also measure RTT to both standbys:
./repl_collect.sh <standby-1-ip> <standby-2-ip>
# On the remote standby:
./repl_collect.sh <primary-ip>
```
Output: `repl_collect_<host>_<ts>.txt` (passwords are automatically redacted).

### 2) Periodic sampling (run continuously)

**On the Primary:**
```bash
chmod +x repl_sampler_primary.sh
OUTDIR=/var/lib/pgsql/repl_metrics INTERVAL=10 THRESHOLD_LAG_S=30 \
  nohup ./repl_sampler_primary.sh >/var/log/repl_sampler.log 2>&1 &
```

**On the remote standby:**
```bash
chmod +x repl_sampler_standby.sh
OUTDIR=/var/lib/pgsql/repl_metrics INTERVAL=10 THRESHOLD_LAG_S=30 \
  nohup ./repl_sampler_standby.sh >/var/log/repl_sampler.log 2>&1 &
```

Variables:
| Env | Default | Meaning |
|-----|---------|---------|
| `INTERVAL` | 10 | seconds between samples |
| `THRESHOLD_LAG_S` | 30 | lag threshold (s) that triggers a burst capture |
| `BURST_COOLDOWN` | 120 | minimum gap between bursts (s) |
| `OUTDIR` | `./repl_metrics` | output directory for CSV & bursts |
| `COUNT` | 0 | 0 = run indefinitely; >0 = stop after N samples |

Raw output:
- `primary_metrics.csv`, `standby_metrics.csv` (append, restart-safe)
- `burst_primary_<ts>.txt`, `burst_standby_<ts>.txt` (detailed incident snapshots)

### 3) Generate the dashboard
Collect the CSVs from each node into one folder, then:
```bash
python3 repl_dashboard.py --metrics-dir ./repl_metrics --out dashboard.html
# or explicitly:
python3 repl_dashboard.py --primary primary_metrics.csv --standby standby_metrics.csv --out dashboard.html
```
Open `dashboard.html` in a browser (local file, no internet required).

---

## Running as a systemd service (optional, cleaner)

`/etc/systemd/system/repl-sampler.service`:
```ini
[Unit]
Description=PG Replication Sampler
After=postgresql.service

[Service]
User=postgres
Environment=OUTDIR=/var/lib/pgsql/repl_metrics
Environment=INTERVAL=10
Environment=THRESHOLD_LAG_S=30
ExecStart=/path/repl_sampler_standby.sh   ; use _primary on the primary node
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

To prove **NETWORK-BOUND** vs link capacity, run `repl_network_diag.sh`
(single-stream vs parallel test). For apply-side detail, run `repl_apply_diag.sh`.

---

## Notes

- Start the samplers **before** an incident so the rolling history captures it.
- Sampling during **peak / batch hours** reveals the peak WAL rate, which drives lag.
- All output containing `primary_conninfo`/socket data has passwords redacted.
- For stronger long-term monitoring, consider Prometheus + `postgres_exporter` +
  `node_exporter`. This toolkit is for fast diagnosis without heavy setup.
```
