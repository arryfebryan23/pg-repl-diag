#!/usr/bin/env python3
# -*- coding: utf-8 -*-
"""
bin/repl_dashboard.py — render the raw sampler CSVs into an interactive HTML dashboard.

No external dependencies (standard library only). Charts are drawn with inline
vanilla-JS canvas code, so the resulting HTML is 100% offline and safe to open
on air-gapped servers.

CONFIGURATION: default input/output directories are read from the environment
(METRICS_DIR, BURST_DIR, DASHBOARD_DIR — set in repl.script.env) and can be
overridden with CLI flags.

USAGE:
  # using directories from repl.script.env:
  set -a; . ./repl.script.env; . ./repl.env; set +a
  python3 bin/repl_dashboard.py
  # or explicitly:
  python3 bin/repl_dashboard.py --metrics-dir ./output/metrics --burst-dir ./output/bursts \\
                                --out ./output/dashboards/dashboard.html
"""
import argparse, csv, glob, json, os, html
from datetime import datetime

def fnum(v):
    try:
        if v in ("", "-", None): return None
        return float(v)
    except (ValueError, TypeError):
        return None

def read_csv(path):
    rows = []
    if not path or not os.path.exists(path):
        return rows
    with open(path, newline="") as f:
        for r in csv.DictReader(f):
            rows.append(r)
    return rows

def series(rows, ykey, xkey="ts_epoch"):
    out = []
    for r in rows:
        x, y = fnum(r.get(xkey)), fnum(r.get(ykey))
        if x is not None and y is not None:
            out.append({"x": x, "y": y})
    return out

def mb_series(rows, ykey):
    out = []
    for r in rows:
        x, y = fnum(r.get("ts_epoch")), fnum(r.get(ykey))
        if x is not None and y is not None:
            out.append({"x": x, "y": round(y / 1048576.0, 2)})
    return out

def summarize(vals):
    ys = [p["y"] for p in vals]
    if not ys: return {"last": None, "max": None, "avg": None}
    return {"last": ys[-1], "max": max(ys), "avg": round(sum(ys)/len(ys), 2)}

# ---------------------------------------------------------------------------
# Defaults follow the output layout from repl.script.env; fall back to ./output/*.
DEF_METRICS   = os.environ.get("METRICS_DIR", "./output/metrics")
DEF_BURST     = os.environ.get("BURST_DIR", "./output/bursts")
DEF_DASHBOARD = os.environ.get("DASHBOARD_DIR", "./output/dashboards")

ap = argparse.ArgumentParser()
ap.add_argument("--metrics-dir", default=DEF_METRICS, help="directory containing *_metrics.csv")
ap.add_argument("--burst-dir", default=DEF_BURST, help="directory containing burst_*.txt")
ap.add_argument("--primary", default=None, help="explicit path to primary_metrics.csv")
ap.add_argument("--standby", default=None, help="explicit path to standby_metrics.csv")
ap.add_argument("--out", default=os.path.join(DEF_DASHBOARD, "dashboard.html"))
args = ap.parse_args()

primary_csv = args.primary or os.path.join(args.metrics_dir, "primary_metrics.csv")
standby_csv = args.standby or os.path.join(args.metrics_dir, "standby_metrics.csv")
burst_dir = args.burst_dir

prows = read_csv(primary_csv)
srows = read_csv(standby_csv)

# ---- build PRIMARY data ----
primary = {"wal_rate": [], "standbys": {}}
seen_ts = set()
for r in prows:
    ts = r.get("ts_epoch")
    if ts not in seen_ts:
        wr = fnum(r.get("wal_rate_mbps"))
        if wr is not None:
            primary["wal_rate"].append({"x": fnum(ts), "y": wr})
        seen_ts.add(ts)
    name = r.get("standby") or "-"
    if name in ("(no-standby)", "-"): continue
    d = primary["standbys"].setdefault(name, {"replay_lag": [], "total_lag_mb": []})
    x = fnum(ts); rl = fnum(r.get("replay_lag_s")); tl = fnum(r.get("total_lag_bytes"))
    if x is not None and rl is not None: d["replay_lag"].append({"x": x, "y": rl})
    if x is not None and tl is not None: d["total_lag_mb"].append({"x": x, "y": round(tl/1048576.0, 2)})

# ---- build STANDBY data ----
standby = {
    "time_lag":   series(srows, "time_lag_s"),
    "arrival":    series(srows, "arrival_mbps"),
    "apply":      series(srows, "apply_mbps"),
    "gap_mb":     mb_series(srows, "apply_gap_bytes"),
    "disk_util":  series(srows, "disk_util"),
    "cpu_startup":series(srows, "cpu_startup_pct"),
    "rtt":        series(srows, "sock_rtt_ms"),
    "retrans":    series(srows, "sock_retrans"),
    "waitevents": {},
}
for r in srows:
    we = (r.get("wait_event") or "").strip()
    if we and we not in ("-", "-/-", "-/running"):
        standby["waitevents"][we] = standby["waitevents"].get(we, 0) + 1

# ---- heuristic verdict ----
verdict, vclass, notes = "Insufficient data", "warn", []
s_lag = summarize(standby["time_lag"])
s_arr = summarize(standby["arrival"]); s_app = summarize(standby["apply"])
s_util = summarize(standby["disk_util"]); s_cpu = summarize(standby["cpu_startup"])
s_retr0 = standby["retrans"][0]["y"] if standby["retrans"] else None
s_retrN = standby["retrans"][-1]["y"] if standby["retrans"] else None
retr_delta = (s_retrN - s_retr0) if (s_retr0 is not None and s_retrN is not None) else None

if srows:
    apply_slower = (s_arr["avg"] is not None and s_app["avg"] is not None and s_app["avg"] < s_arr["avg"]*0.9)
    if (s_lag["max"] or 0) > 30 and apply_slower:
        if (s_util["max"] or 0) > 80:
            verdict, vclass = "APPLY-BOUND -> standby disk I/O", "bad"
            notes.append("Disk %%util peaked at %.0f%% during high lag." % s_util["max"])
        elif (s_cpu["max"] or 0) > 85:
            verdict, vclass = "APPLY-BOUND -> single-thread CPU (redo)", "bad"
            notes.append("Startup process CPU peaked at %.0f%% (one core saturated)." % s_cpu["max"])
        else:
            verdict, vclass = "APPLY-BOUND -> standby not keeping up with WAL", "bad"
        notes.append("Average apply %.2f MB/s < arrival %.2f MB/s." % (s_app["avg"] or 0, s_arr["avg"] or 0))
    elif (s_lag["max"] or 0) > 30 and (s_arr["avg"] or 0) < 1.0:
        verdict, vclass = "Likely NETWORK-BOUND (WAL arriving slowly)", "warn"
        notes.append("Low arrival (%.2f MB/s) despite high lag." % (s_arr["avg"] or 0))
        if retr_delta and retr_delta > 0:
            notes.append("Retransmits rose by %d over the period -> indicates packet loss." % int(retr_delta))
    elif (s_lag["max"] or 0) <= 30:
        verdict, vclass = "HEALTHY (lag under control during this period)", "good"
        notes.append("Peak time_lag %.1f s." % (s_lag["max"] or 0))
elif prows:
    verdict, vclass = "Primary data available (see per-standby lag charts)", "warn"

# ---- burst incident list ----
bursts = []
if burst_dir and os.path.isdir(burst_dir):
    for bf in sorted(glob.glob(os.path.join(burst_dir, "burst_*.txt"))):
        try:
            with open(bf) as f: head = f.readline().strip()
        except OSError: head = ""
        bursts.append({"file": os.path.basename(bf), "head": head})

meta = {
    "generated": datetime.now().strftime("%Y-%m-%d %H:%M:%S"),
    "primary_rows": len(prows), "standby_rows": len(srows),
    "primary_csv": primary_csv or "-", "standby_csv": standby_csv or "-",
}

# summary HTML cards
def card(title, sm, unit):
    if not sm or sm["last"] is None:
        return '<div class="card"><h4>%s</h4><div class="big">-</div></div>' % html.escape(title)
    return ('<div class="card"><h4>%s</h4><div class="big">%s<span>%s</span></div>'
            '<div class="sub">peak %s · avg %s</div></div>') % (
            html.escape(title), sm["last"], unit, sm["max"], sm["avg"])

cards = "".join([
    card("Replication lag (standby)", s_lag, " s"),
    card("Apply rate", s_app, " MB/s"),
    card("Arrival rate", s_arr, " MB/s"),
    card("Disk %util (standby)", s_util, " %"),
    card("CPU redo (startup)", s_cpu, " %"),
    card("Socket RTT", summarize(standby["rtt"]), " ms"),
])
notes_html = "".join("<li>%s</li>" % html.escape(n) for n in notes)
burst_html = ("".join('<li><b>%s</b> — %s</li>' % (html.escape(b["file"]), html.escape(b["head"]))
              for b in bursts) or "<li>No burst incidents recorded.</li>")

DATA = {"primary": primary, "standby": standby, "meta": meta}

# ===========================================================================
TEMPLATE = r"""<!doctype html>
<html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>Replication Diagnostics Dashboard</title>
<style>
  :root{--bg:#0f1419;--panel:#1a2129;--line:#2a3441;--fg:#e6edf3;--mut:#8b98a5;--accent:#4aa8ff;}
  *{box-sizing:border-box}
  body{margin:0;background:var(--bg);color:var(--fg);font:14px/1.5 -apple-system,Segoe UI,Roboto,sans-serif}
  header{padding:20px 24px;border-bottom:1px solid var(--line)}
  h1{margin:0;font-size:20px}
  .meta{color:var(--mut);font-size:12px;margin-top:4px}
  .wrap{padding:20px 24px;max-width:1200px;margin:0 auto}
  .verdict{padding:14px 18px;border-radius:10px;margin-bottom:18px;font-weight:600;font-size:15px}
  .verdict.good{background:#10311f;border:1px solid #2ea043;color:#7ee787}
  .verdict.warn{background:#3a2f10;border:1px solid #d29922;color:#f2cc60}
  .verdict.bad {background:#3a1418;border:1px solid #f85149;color:#ff9492}
  .verdict ul{margin:8px 0 0;padding-left:20px;font-weight:400;font-size:13px}
  .cards{display:grid;grid-template-columns:repeat(auto-fit,minmax(170px,1fr));gap:12px;margin-bottom:22px}
  .card{background:var(--panel);border:1px solid var(--line);border-radius:10px;padding:14px}
  .card h4{margin:0 0 6px;color:var(--mut);font-size:12px;font-weight:500;text-transform:uppercase;letter-spacing:.4px}
  .big{font-size:26px;font-weight:700}.big span{font-size:13px;color:var(--mut);font-weight:400;margin-left:3px}
  .sub{color:var(--mut);font-size:12px;margin-top:2px}
  .chart{background:var(--panel);border:1px solid var(--line);border-radius:10px;padding:14px 16px;margin-bottom:18px}
  .chart h3{margin:0 0 2px;font-size:15px}.chart .hint{color:var(--mut);font-size:12px;margin-bottom:8px}
  canvas{width:100%;height:240px;display:block}
  .legend{display:flex;gap:16px;flex-wrap:wrap;font-size:12px;margin-top:6px;color:var(--mut)}
  .legend i{display:inline-block;width:11px;height:11px;border-radius:2px;margin-right:5px;vertical-align:-1px}
  .bars{display:flex;flex-direction:column;gap:6px;margin-top:6px}
  .bar{display:flex;align-items:center;gap:8px;font-size:12px}
  .bar .track{flex:1;background:var(--line);border-radius:4px;height:16px;overflow:hidden}
  .bar .fill{height:100%;background:var(--accent)}
  .burst{background:var(--panel);border:1px solid var(--line);border-radius:10px;padding:14px 16px}
  .burst ul{margin:8px 0 0;padding-left:18px;font-size:13px}
  footer{color:var(--mut);font-size:12px;padding:16px 24px;text-align:center}
  .empty{color:var(--mut);font-style:italic;padding:30px;text-align:center}
</style></head>
<body>
<header>
  <h1>PostgreSQL Replication Diagnostics</h1>
  <div class="meta">Generated __GEN__ · primary: __PROWS__ rows · standby: __SROWS__ rows</div>
</header>
<div class="wrap">
  <div class="verdict __VCLASS__">VERDICT: __VERDICT__<ul>__NOTES__</ul></div>
  <div class="cards">__CARDS__</div>
  <div id="charts"></div>
  <div class="burst"><h3>Incidents (burst captures)</h3><ul>__BURSTS__</ul></div>
</div>
<footer>Self-contained · rendered offline with no external libraries</footer>

<script>
const DATA = __DATA__;

function fmtTime(ep){const d=new Date(ep*1000);const p=n=>String(n).padStart(2,'0');return p(d.getHours())+':'+p(d.getMinutes())+':'+p(d.getSeconds());}

function drawChart(canvas, cfg){
  const dpr=window.devicePixelRatio||1;
  const cssW=canvas.clientWidth, cssH=canvas.clientHeight;
  canvas.width=cssW*dpr; canvas.height=cssH*dpr;
  const ctx=canvas.getContext('2d'); ctx.scale(dpr,dpr);
  const W=cssW,H=cssH,padL=52,padR=14,padT=10,padB=24;
  const all=[].concat(...cfg.series.map(s=>s.data));
  if(all.length===0){ctx.fillStyle='#8b98a5';ctx.font='13px sans-serif';ctx.fillText('(no data)',padL,H/2);return;}
  const xs=all.map(p=>p.x), ys=all.map(p=>p.y);
  let xMin=Math.min(...xs),xMax=Math.max(...xs);
  let yMin=0,yMax=cfg.yMax!=null?cfg.yMax:Math.max(...ys,0.0001);
  yMax=yMax*1.1||1; if(xMax===xMin)xMax=xMin+1;
  const px=x=>padL+(x-xMin)/(xMax-xMin)*(W-padL-padR);
  const py=y=>H-padB-(y-yMin)/(yMax-yMin)*(H-padT-padB);
  // grid + y labels
  ctx.strokeStyle='#2a3441';ctx.fillStyle='#8b98a5';ctx.font='11px sans-serif';ctx.lineWidth=1;
  for(let i=0;i<=4;i++){const v=yMin+(yMax-yMin)*i/4;const yy=py(v);
    ctx.beginPath();ctx.moveTo(padL,yy);ctx.lineTo(W-padR,yy);ctx.stroke();
    ctx.fillText(v>=100?v.toFixed(0):v.toFixed(1),6,yy+3);}
  // x labels
  for(let i=0;i<=5;i++){const x=xMin+(xMax-xMin)*i/5;
    ctx.fillText(fmtTime(x),px(x)-18,H-8);}
  // series
  cfg.series.forEach(s=>{
    if(s.data.length===0)return;
    ctx.strokeStyle=s.color;ctx.lineWidth=1.8;ctx.beginPath();
    s.data.forEach((p,i)=>{const X=px(p.x),Y=py(p.y);i?ctx.lineTo(X,Y):ctx.moveTo(X,Y);});
    ctx.stroke();
  });
  // hover
  canvas.onmousemove=e=>{
    const r=canvas.getBoundingClientRect();const mx=e.clientX-r.left;
    const tx=xMin+(mx-padL)/(W-padL-padR)*(xMax-xMin);
    drawChart(canvas,cfg); // redraw base
    ctx.strokeStyle='#5b6673';ctx.beginPath();ctx.moveTo(mx,padT);ctx.lineTo(mx,H-padB);ctx.stroke();
    let lines=[fmtTime(tx)];
    cfg.series.forEach(s=>{if(!s.data.length)return;
      let best=s.data[0];for(const p of s.data)if(Math.abs(p.x-tx)<Math.abs(best.x-tx))best=p;
      lines.push(s.name+': '+best.y);});
    const bw=120,bh=lines.length*15+8;let bx=mx+8;if(bx+bw>W)bx=mx-bw-8;
    ctx.fillStyle='rgba(10,14,20,.92)';ctx.fillRect(bx,padT,bw,bh);
    ctx.fillStyle='#e6edf3';ctx.font='11px sans-serif';
    lines.forEach((l,i)=>ctx.fillText(l,bx+6,padT+15+i*15));
  };
  canvas.onmouseleave=()=>drawChart(canvas,cfg);
}

function chartBlock(title,hint,cfg){
  const d=document.createElement('div');d.className='chart';
  d.innerHTML='<h3>'+title+'</h3><div class="hint">'+hint+'</div><canvas></canvas>'+
    '<div class="legend">'+cfg.series.map(s=>'<span><i style="background:'+s.color+'"></i>'+s.name+'</span>').join('')+'</div>';
  document.getElementById('charts').appendChild(d);
  const cv=d.querySelector('canvas');requestAnimationFrame(()=>drawChart(cv,cfg));
}
function barBlock(title,hint,obj){
  const d=document.createElement('div');d.className='chart';
  const ent=Object.entries(obj).sort((a,b)=>b[1]-a[1]);
  const max=ent.length?ent[0][1]:1;
  let h='<h3>'+title+'</h3><div class="hint">'+hint+'</div><div class="bars">';
  if(!ent.length)h+='<div class="empty">(no wait events recorded)</div>';
  ent.forEach(([k,v])=>{h+='<div class="bar"><span style="width:170px">'+k+'</span><div class="track"><div class="fill" style="width:'+(v/max*100)+'%"></div></div><span>'+v+'</span></div>';});
  h+='</div>';d.innerHTML=h;document.getElementById('charts').appendChild(d);
}

const P=DATA.primary, S=DATA.standby;
const C={lag:'#f85149',apply:'#2ea043',arr:'#4aa8ff',gap:'#d29922',util:'#bc8cff',cpu:'#ff7b72',rtt:'#56d4dd',retr:'#f0883e',wal:'#4aa8ff'};

// --- STANDBY charts ---
if(DATA.meta.standby_rows>0){
  chartBlock('Replication Lag (time_lag)','Age of the last applied transaction. The core symptom.',
    {yMax:null,series:[{name:'time_lag (s)',color:C.lag,data:S.time_lag}]});
  chartBlock('Arrival vs Apply Rate','WAL received vs WAL applied. Apply < arrival = standby falling behind.',
    {series:[{name:'arrival (MB/s)',color:C.arr,data:S.arrival},{name:'apply (MB/s)',color:C.apply,data:S.apply}]});
  chartBlock('Apply Gap','WAL received but not yet applied. Growing = apply-bound.',
    {series:[{name:'gap (MB)',color:C.gap,data:S.gap_mb}]});
  chartBlock('Resource Saturation (standby)','Correlate lag spikes with disk / CPU redo.',
    {yMax:100,series:[{name:'disk %util',color:C.util,data:S.disk_util},{name:'CPU redo %',color:C.cpu,data:S.cpu_startup}]});
  chartBlock('Network Quality (replication socket)','RTT & retransmits on the walreceiver connection.',
    {series:[{name:'rtt (ms)',color:C.rtt,data:S.rtt},{name:'retrans (total)',color:C.retr,data:S.retrans}]});
  barBlock('Wait Event Distribution (redo process)','Where the startup process spends its time.',S.waitevents);
}

// --- PRIMARY charts ---
if(DATA.meta.primary_rows>0){
  chartBlock('WAL Generation Rate (primary)','Spikes = batch/checkpoint. Compare against standby apply.',
    {series:[{name:'WAL rate (MB/s)',color:C.wal,data:P.wal_rate}]});
  const names=Object.keys(P.standbys);
  if(names.length){
    const pal=['#f85149','#4aa8ff','#2ea043','#d29922','#bc8cff'];
    chartBlock('replay_lag per Standby (from primary)','Compare standbys side by side.',
      {series:names.map((n,i)=>({name:n,color:pal[i%pal.length],data:P.standbys[n].replay_lag}))});
    chartBlock('Total Lag per Standby (bytes)','Difference between sent and replay LSN per standby.',
      {series:names.map((n,i)=>({name:n,color:pal[i%pal.length],data:P.standbys[n].total_lag_mb}))});
  }
}
if(DATA.meta.primary_rows===0 && DATA.meta.standby_rows===0){
  document.getElementById('charts').innerHTML='<div class="empty">No data. Ensure the sampler CSVs are populated.</div>';
}
window.addEventListener('resize',()=>location.reload());
</script>
</body></html>"""

out = (TEMPLATE
    .replace("__DATA__", json.dumps(DATA))
    .replace("__GEN__", html.escape(meta["generated"]))
    .replace("__PROWS__", str(meta["primary_rows"]))
    .replace("__SROWS__", str(meta["standby_rows"]))
    .replace("__VCLASS__", vclass)
    .replace("__VERDICT__", html.escape(verdict))
    .replace("__NOTES__", notes_html)
    .replace("__CARDS__", cards)
    .replace("__BURSTS__", burst_html))

out_dir = os.path.dirname(os.path.abspath(args.out))
if out_dir:
    os.makedirs(out_dir, exist_ok=True)
with open(args.out, "w") as f:
    f.write(out)
print("Dashboard generated: %s" % args.out)
print("  primary rows: %d | standby rows: %d | bursts: %d" %
      (meta["primary_rows"], meta["standby_rows"], len(bursts)))
