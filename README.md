# Replication Lag Diagnostics Toolkit (PostgreSQL)

Toolkit untuk mendiagnosa **replication lag** pada topologi multi-site
(mis. Primary Jakarta → Slave Jakarta → Slave Surabaya). Memisahkan dua akar
masalah yang sering tertukar: **bottleneck network** (single-stream TCP) vs
**bottleneck apply** (disk/CPU standby).

Semua script **read-only** terhadap database dan **tanpa dependensi eksternal**
(hanya `bash`, `psql`, `python3`; `iostat`/`mpstat` dari paket `sysstat` opsional).

---

## Isi Paket

| File | Jalankan di | Sifat | Fungsi |
|------|-------------|-------|--------|
| `repl_collect.sh` | semua node | **one-time** | Snapshot konfigurasi OS + DB (statis) |
| `repl_network_diag.sh` | Primary | on-demand | Uji single-stream vs paralel (iperf3) + laju WAL |
| `repl_apply_diag.sh` | Standby | on-demand | Monitor apply gap, wait event, disk, CPU redo |
| `repl_sampler_primary.sh` | Primary | **periodik** | Sampling lag & laju WAL → CSV raw + burst |
| `repl_sampler_standby.sh` | Standby | **periodik** | Sampling apply/network/disk/CPU → CSV raw + burst |
| `repl_dashboard.py` | mana saja | offline | Ubah CSV raw → dashboard HTML interaktif |

---

## Konsep: One-Time vs Periodik

- **One-time (statis):** versi OS/PG, CPU, disk, sysctl TCP, semua `pg_settings`.
  Dikumpulkan `repl_collect.sh`. Cukup sekali / saat ada perubahan. Berguna untuk
  **membandingkan antar node** (kenapa JKT mulus, SBY lag).
- **Periodik (dinamis):** lag, apply/arrival rate, wait event, disk %util, CPU redo,
  rtt/retransmit. Dikumpulkan sampler. Harus sampling terus agar **saat insiden
  terjadi, datanya sudah tercatat** walau tidak ada yang menunggui.

> Beberapa metrik bersifat **instan** (wait event, rtt, retransmit) — tak bernilai
> bila dilihat belakangan. Karena itu sampling rapat (default 10 detik) + **burst
> capture** otomatis saat lag melewati ambang.

---

## Prasyarat

```bash
# RHEL/Rocky
sudo yum install -y sysstat iperf3
# Debian/Ubuntu
sudo apt-get install -y sysstat iperf3
```

Akses `psql` tanpa prompt password — set salah satu:
```bash
export PGHOST=/var/run/postgresql PGPORT=5432 PGUSER=postgres PGDATABASE=postgres
# atau gunakan ~/.pgpass  (chmod 600)
```
Idealnya dijalankan sebagai user **`postgres`** agar bisa baca file config & metrik proses.

---

## Alur Pakai

### 1) Snapshot statis (sekali, di tiap node)
```bash
chmod +x repl_collect.sh
# di Primary, sekalian ukur RTT ke kedua slave:
./repl_collect.sh <ip-slave-jkt> <ip-slave-sby>
# di Slave SBY:
./repl_collect.sh <ip-primary>
```
Hasil: `repl_collect_<host>_<ts>.txt` (password otomatis diredaksi).

### 2) Sampling periodik (jalan terus)

**Di Primary:**
```bash
chmod +x repl_sampler_primary.sh
OUTDIR=/var/lib/pgsql/repl_metrics INTERVAL=10 THRESHOLD_LAG_S=30 \
  nohup ./repl_sampler_primary.sh >/var/log/repl_sampler.log 2>&1 &
```

**Di Standby Surabaya:**
```bash
chmod +x repl_sampler_standby.sh
OUTDIR=/var/lib/pgsql/repl_metrics INTERVAL=10 THRESHOLD_LAG_S=30 \
  nohup ./repl_sampler_standby.sh >/var/log/repl_sampler.log 2>&1 &
```

Variabel:
| Env | Default | Arti |
|-----|---------|------|
| `INTERVAL` | 10 | detik antar sampel |
| `THRESHOLD_LAG_S` | 30 | ambang lag (detik) pemicu burst capture |
| `BURST_COOLDOWN` | 120 | jeda minimal antar burst (detik) |
| `OUTDIR` | `./repl_metrics` | folder output CSV & burst |
| `COUNT` | 0 | 0 = jalan terus; >0 = berhenti setelah N sampel |

Output raw:
- `primary_metrics.csv`, `standby_metrics.csv` (append, aman saat restart)
- `burst_primary_<ts>.txt`, `burst_standby_<ts>.txt` (snapshot detail saat insiden)

### 3) Generate dashboard
Kumpulkan CSV dari node ke satu folder, lalu:
```bash
python3 repl_dashboard.py --metrics-dir ./repl_metrics --out dashboard.html
# atau eksplisit:
python3 repl_dashboard.py --primary primary_metrics.csv --standby standby_metrics.csv --out dashboard.html
```
Buka `dashboard.html` di browser (file lokal, tanpa internet).

---

## Menjalankan sebagai systemd service (opsional, lebih rapi)

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
ExecStart=/path/repl_sampler_standby.sh   ; ganti _primary di node primary
Restart=always

[Install]
WantedBy=multi-user.target
```
```bash
sudo systemctl daemon-reload && sudo systemctl enable --now repl-sampler
```

---

## Membaca Dashboard

Panel atas memberi **VONIS otomatis** + kartu ringkasan. Grafik utama:

- **Replication Lag (time_lag)** — masalah yang user rasakan.
- **Arrival vs Apply Rate** — kalau garis *apply* < *arrival*, standby tertinggal → apply-bound.
- **Apply Gap** — kalau terus naik → apply tidak mengejar.
- **Saturasi Resource** — disk %util & CPU redo (skala 0–100). Korelasikan dengan lonjakan lag.
- **Kualitas Network** — rtt & retransmit socket replikasi.
- **Distribusi Wait Event** — di mana proses redo menghabiskan waktu.
- **Laju WAL (primary)** & **lag per standby** — bandingkan SBY vs JKT.

### Pohon Keputusan

```
Lag tinggi?
├─ Apply < Arrival  &  gap membesar  → APPLY-BOUND
│   ├─ disk %util tinggi / wait IO    → DISK I/O standby (upgrade storage, pisah WAL)
│   ├─ CPU redo ~100% (1 core)        → CPU single-thread (clock per-core, kurangi WAL)
│   └─ ada Recovery/Conflict wait     → konflik query (tune hot_standby_feedback)
└─ Arrival rendah, apply tidak numpuk → NETWORK-BOUND
    ├─ retransmit naik / loss          → loss-bound  → ganti congestion control ke BBR
    └─ rtt tinggi, retransmit ~0       → latency-bound → besarkan TCP buffer > BDP
```

Untuk membuktikan **NETWORK-BOUND** vs kapasitas link, jalankan `repl_network_diag.sh`
(uji single-stream vs paralel). Untuk detail sisi apply, `repl_apply_diag.sh`.

---

## Catatan

- Jalankan sampler **sebelum** insiden agar history bergulir menangkap kejadian.
- Sampling saat **jam sibuk / batch** memberi gambaran laju WAL puncak (penentu lag).
- Semua output yang memuat `primary_conninfo`/socket diredaksi passwordnya.
- Untuk pemantauan jangka panjang yang lebih kuat, pertimbangkan
  Prometheus + `postgres_exporter` + `node_exporter`. Toolkit ini untuk
  diagnosa cepat tanpa setup besar.
```
