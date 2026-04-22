#!/usr/bin/env python3
"""
StromaAI — Monitor Dashboard
==============================
Real-time browser dashboard served via aiohttp + WebSocket.

A background task polls the monitor agent every N seconds and broadcasts
the JSON snapshot to all connected WebSocket clients.  The HTML/CSS/JS
is fully inline — no external CDN or static files required.

Environment variables
---------------------
STROMA_MONITOR_DASHBOARD_PORT   Listen port (default 9200)
STROMA_MONITOR_AGENT_HOST       Agent hostname/IP (default localhost)
STROMA_MONITOR_AGENT_PORT       Agent port (default 9201)
STROMA_MONITOR_POLL_SECS        Agent poll interval (default 10)
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import time

from aiohttp import ClientSession, ClientTimeout, WSMsgType, web

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

PORT = int(os.environ.get("STROMA_MONITOR_DASHBOARD_PORT", "9200"))
AGENT_HOST = os.environ.get("STROMA_MONITOR_AGENT_HOST", "localhost")
AGENT_PORT = int(os.environ.get("STROMA_MONITOR_AGENT_PORT", "9201"))
POLL_SECS = int(os.environ.get("STROMA_MONITOR_POLL_SECS", "10"))

AGENT_URL = f"http://{AGENT_HOST}:{AGENT_PORT}/metrics"

log = logging.getLogger("monitor-dashboard")

# ---------------------------------------------------------------------------
# WebSocket client management
# ---------------------------------------------------------------------------

_clients: set[web.WebSocketResponse] = set()
_latest: dict = {}


async def _poll_agent(app: web.Application) -> None:
    """Background task: poll agent, broadcast to all WS clients."""
    global _latest
    await asyncio.sleep(1)  # let the server bind first
    log.info("Polling agent at %s every %ds", AGENT_URL, POLL_SECS)
    while True:
        try:
            async with ClientSession(timeout=ClientTimeout(total=8)) as sess:
                async with sess.get(AGENT_URL) as resp:
                    if resp.status == 200:
                        _latest = await resp.json()
        except Exception as exc:
            log.debug("Agent poll failed: %s", exc)
            _latest = {"error": str(exc), "ts": time.time()}

        payload = json.dumps(_latest)
        dead: list[web.WebSocketResponse] = []
        for ws in _clients:
            try:
                await ws.send_str(payload)
            except Exception:
                dead.append(ws)
        for ws in dead:
            _clients.discard(ws)

        await asyncio.sleep(POLL_SECS)


async def start_background(app: web.Application) -> None:
    app["poll_task"] = asyncio.create_task(_poll_agent(app))


async def stop_background(app: web.Application) -> None:
    app["poll_task"].cancel()
    try:
        await app["poll_task"]
    except asyncio.CancelledError:
        pass


# ---------------------------------------------------------------------------
# Routes
# ---------------------------------------------------------------------------

async def handle_index(request: web.Request) -> web.Response:
    return web.Response(text=DASHBOARD_HTML, content_type="text/html")


async def handle_ws(request: web.Request) -> web.WebSocketResponse:
    ws = web.WebSocketResponse(heartbeat=30)
    await ws.prepare(request)
    _clients.add(ws)
    log.info("WS client connected (%d total)", len(_clients))

    # Send latest snapshot immediately
    if _latest:
        await ws.send_str(json.dumps(_latest))

    try:
        async for msg in ws:
            if msg.type in (WSMsgType.ERROR, WSMsgType.CLOSE):
                break
    finally:
        _clients.discard(ws)
        log.info("WS client disconnected (%d remaining)", len(_clients))
    return ws


# ---------------------------------------------------------------------------
# Inline HTML
# ---------------------------------------------------------------------------

DASHBOARD_HTML = r"""<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<title>StromaAI Monitor</title>
<style>
:root {
  --bg:      #0d1117;
  --surface: #161b22;
  --border:  #30363d;
  --text:    #c9d1d9;
  --dim:     #8b949e;
  --green:   #3fb950;
  --red:     #f85149;
  --yellow:  #d29922;
  --blue:    #58a6ff;
  --orange:  #d18616;
  --purple:  #bc8cff;
  --cyan:    #39d2c0;
}
*, *::before, *::after { box-sizing: border-box; }
body {
  margin: 0; padding: 16px;
  font-family: 'SF Mono', 'Cascadia Code', 'Fira Code', 'Consolas', monospace;
  font-size: 13px;
  background: var(--bg);
  color: var(--text);
  line-height: 1.5;
}
h1 { margin:0 0 4px; font-size:20px; color:#fff; }
.header { display:flex; align-items:center; gap:16px; margin-bottom:16px; flex-wrap:wrap; }
.header-meta { color:var(--dim); font-size:12px; }
.dot { display:inline-block; width:8px; height:8px; border-radius:50%; margin-right:4px; }
.dot-green { background:var(--green); }
.dot-red { background:var(--red); }
.section { margin-bottom:20px; }
.section-title {
  font-size:12px; text-transform:uppercase; letter-spacing:1px;
  color:var(--dim); margin-bottom:8px; font-weight:600;
  border-bottom:1px solid var(--border); padding-bottom:4px;
}
/* Cards grid */
.cards { display:flex; flex-wrap:wrap; gap:10px; }
.card {
  background:var(--surface); border:1px solid var(--border);
  border-radius:6px; padding:10px 14px; min-width:180px; flex:1;
}
.card-label { font-size:11px; color:var(--dim); margin-bottom:2px; }
.card-value { font-size:18px; font-weight:700; }
.card-sub { font-size:11px; color:var(--dim); margin-top:2px; }
/* Status badges */
.badge {
  display:inline-block; padding:1px 8px; border-radius:10px;
  font-size:11px; font-weight:600; text-transform:uppercase;
}
.badge-active  { background:#1a3a2a; color:var(--green); }
.badge-failed  { background:#3a1a1a; color:var(--red); }
.badge-inactive { background:#2a2a2a; color:var(--dim); }
.badge-running { background:#1a2a3a; color:var(--blue); }
.badge-pending { background:#2a2a1a; color:var(--yellow); }
.badge-healthy { background:#1a3a2a; color:var(--green); }
.badge-serving { background:#1a3a2a; color:var(--green); }
/* Tables */
table { width:100%; border-collapse:collapse; background:var(--surface); border-radius:6px; overflow:hidden; }
th, td { text-align:left; padding:6px 10px; border-bottom:1px solid var(--border); }
th { font-size:11px; color:var(--dim); text-transform:uppercase; letter-spacing:0.5px; background:#1c2128; }
tr:last-child td { border-bottom:none; }
tr.stroma { background:#111820; }
/* Progress bars */
.progress-wrap { background:#21262d; border-radius:3px; height:16px; position:relative; overflow:hidden; }
.progress-bar { height:100%; border-radius:3px; transition:width 0.5s; }
.progress-text {
  position:absolute; top:0; left:6px; right:6px; height:16px;
  line-height:16px; font-size:10px; color:#fff; white-space:nowrap;
}
.pb-green  { background:var(--green); }
.pb-yellow { background:var(--yellow); }
.pb-red    { background:var(--red); }
.pb-blue   { background:var(--blue); }
.pb-cyan   { background:var(--cyan); }
/* GPU bars */
.gpu-row { display:flex; align-items:center; gap:10px; margin-bottom:6px; }
.gpu-label { min-width:200px; font-size:12px; }
.gpu-bar-wrap { flex:1; }
.gpu-temp { min-width:50px; text-align:right; font-size:12px; }
/* Model cards */
.model-card {
  background:var(--surface); border:1px solid var(--border);
  border-radius:6px; padding:12px; margin-bottom:8px;
}
.model-header { display:flex; align-items:center; gap:8px; margin-bottom:6px; }
.model-id { font-weight:700; font-size:14px; }
.replica-table { width:100%; font-size:12px; }
.replica-table th { font-size:10px; }
/* Network */
.net-ips { font-size:11px; color:var(--dim); }
/* Gauge cards */
.gauge-grid { display:grid; grid-template-columns:repeat(auto-fill, minmax(160px, 1fr)); gap:10px; }
.gauge-card {
  background:var(--surface); border:1px solid var(--border);
  border-radius:6px; padding:10px 14px; text-align:center;
}
.gauge-val { font-size:24px; font-weight:700; }
.gauge-label { font-size:11px; color:var(--dim); margin-top:2px; }
/* Responsive */
@media (max-width:900px) {
  .cards { flex-direction:column; }
  .gauge-grid { grid-template-columns:1fr 1fr; }
}
.error-banner {
  background:#3a1a1a; border:1px solid var(--red); border-radius:6px;
  padding:10px 14px; margin-bottom:16px; color:var(--red);
}
.empty { color:var(--dim); font-style:italic; padding:10px; }
</style>
</head>
<body>

<div class="header">
  <h1>StromaAI Monitor</h1>
  <div class="header-meta">
    <span id="conn-dot" class="dot dot-red"></span>
    <span id="conn-text">Connecting…</span>
    &nbsp;|&nbsp; Last update: <span id="last-update">—</span>
  </div>
</div>
<div id="error-banner" class="error-banner" style="display:none"></div>

<div class="section" id="sec-services">
  <div class="section-title">Services</div>
  <div id="services" class="cards"><div class="empty">Waiting for data…</div></div>
</div>

<div class="section" id="sec-vllm">
  <div class="section-title">vLLM Metrics</div>
  <div id="vllm" class="gauge-grid"><div class="empty">Waiting for data…</div></div>
</div>

<div class="section" id="sec-models">
  <div class="section-title">Models</div>
  <div id="models"><div class="empty">Waiting for data…</div></div>
</div>

<div class="section" id="sec-gpu">
  <div class="section-title">GPU</div>
  <div id="gpu"><div class="empty">Waiting for data…</div></div>
</div>

<div class="section" id="sec-host">
  <div class="section-title">Host Resources</div>
  <div id="host"><div class="empty">Waiting for data…</div></div>
</div>

<div class="section" id="sec-partitions">
  <div class="section-title">Slurm Partitions</div>
  <div id="partitions"><div class="empty">Waiting for data…</div></div>
</div>

<div class="section" id="sec-jobs">
  <div class="section-title">Slurm Jobs</div>
  <div id="jobs"><div class="empty">Waiting for data…</div></div>
</div>

<div class="section" id="sec-network">
  <div class="section-title">Network Interfaces</div>
  <div id="network"><div class="empty">Waiting for data…</div></div>
</div>

<script>
// =========================================================================
// Utilities
// =========================================================================
function fmt_bytes(b) {
  if (b == null) return '—';
  if (b < 1024) return b + ' B';
  if (b < 1048576) return (b/1024).toFixed(1) + ' KiB';
  if (b < 1073741824) return (b/1048576).toFixed(1) + ' MiB';
  if (b < 1099511627776) return (b/1073741824).toFixed(1) + ' GiB';
  return (b/1099511627776).toFixed(1) + ' TiB';
}
function fmt_pct(v, d) { return v != null ? (v * (d||1)).toFixed(1) + '%' : '—'; }
function fmt_num(v) { return v != null ? Number(v).toLocaleString() : '—'; }
function fmt_time(s) {
  if (s == null) return '—';
  if (s < 0.001) return (s*1e6).toFixed(0) + ' µs';
  if (s < 1) return (s*1000).toFixed(1) + ' ms';
  return s.toFixed(2) + ' s';
}
function fmt_ts(epoch) {
  if (!epoch) return '—';
  const d = new Date(epoch * 1000);
  return d.toLocaleTimeString();
}
function badge(cls, text) {
  return '<span class="badge badge-' + cls + '">' + text + '</span>';
}
function progress_bar(pct, label, color) {
  const c = color || (pct > 90 ? 'red' : pct > 70 ? 'yellow' : 'green');
  return '<div class="progress-wrap">' +
    '<div class="progress-bar pb-' + c + '" style="width:' + Math.min(pct, 100).toFixed(1) + '%"></div>' +
    '<div class="progress-text">' + label + '</div></div>';
}
function esc(s) {
  const d = document.createElement('div');
  d.textContent = s || '';
  return d.innerHTML;
}

// =========================================================================
// Renderers
// =========================================================================
function render_services(data) {
  const el = document.getElementById('services');
  if (!data || !data.length) { el.innerHTML = '<div class="empty">No service data</div>'; return; }
  el.innerHTML = data.map(s => {
    const cls = s.active === 'active' ? 'active' : s.active === 'failed' ? 'failed' : 'inactive';
    const since = s.since ? '<div class="card-sub">since ' + esc(s.since) + '</div>' : '';
    return '<div class="card"><div class="card-label">' + esc(s.name) + '</div>' +
      '<div class="card-value">' + badge(cls, s.active) + '</div>' + since + '</div>';
  }).join('');
}

function render_vllm(data) {
  const el = document.getElementById('vllm');
  if (!data) { el.innerHTML = '<div class="empty">vLLM metrics unavailable</div>'; return; }
  const items = [
    { label:'Requests Waiting', val: fmt_num(data.requests_waiting),
      color: (data.requests_waiting||0) > 5 ? 'var(--yellow)' : 'var(--green)' },
    { label:'Requests Running', val: fmt_num(data.requests_running), color:'var(--blue)' },
    { label:'Requests Swapped', val: fmt_num(data.requests_swapped), color:'var(--orange)' },
    { label:'GPU Cache', val: fmt_pct(data.gpu_cache_pct, 100),
      color: (data.gpu_cache_pct||0) > 0.85 ? 'var(--red)' : 'var(--cyan)' },
    { label:'CPU Cache', val: fmt_pct(data.cpu_cache_pct, 100), color:'var(--purple)' },
    { label:'Avg Latency', val: fmt_time(data.avg_latency_s), color:'var(--text)' },
    { label:'Avg TTFT', val: fmt_time(data.avg_ttft_s), color:'var(--text)' },
  ];
  el.innerHTML = items.map(i =>
    '<div class="gauge-card"><div class="gauge-val" style="color:' + i.color + '">' +
    i.val + '</div><div class="gauge-label">' + i.label + '</div></div>'
  ).join('');
}

function render_models(data) {
  const el = document.getElementById('models');
  if (!data || !data.models) { el.innerHTML = '<div class="empty">Model watcher unavailable</div>'; return; }
  const models = data.models;
  const keys = Object.keys(models);
  if (!keys.length) { el.innerHTML = '<div class="empty">No models registered</div>'; return; }
  el.innerHTML = keys.map(mid => {
    const m = models[mid];
    const st = m.status || 'unknown';
    const cls = st === 'serving' ? 'serving' : st === 'running' ? 'running' : 'inactive';
    let html = '<div class="model-card"><div class="model-header">' +
      '<span class="model-id">' + esc(mid) + '</span> ' +
      badge(cls, st) +
      ' <span class="badge" style="background:#1c2128;color:var(--dim)">' + esc(m.tier) + '</span>' +
      (m.vllm_port ? ' <span style="color:var(--dim)">:' + m.vllm_port + '</span>' : '') +
      '</div>';
    if (m.error_message) {
      html += '<div style="color:var(--red);font-size:12px;margin-bottom:6px">' + esc(m.error_message) + '</div>';
    }
    // Burst replicas
    const reps = m.burst_replicas || [];
    if (reps.length) {
      html += '<table class="replica-table"><tr><th>Job</th><th>Host</th><th>Port</th><th>State</th></tr>';
      reps.forEach(r => {
        const rc = r.state === 'healthy' ? 'healthy' : r.state === 'running' ? 'running' : 'pending';
        html += '<tr><td>' + esc(r.job_id) + '</td><td>' + esc(r.host||'—') + '</td>' +
          '<td>' + (r.port||'—') + '</td><td>' + badge(rc, r.state) + '</td></tr>';
      });
      html += '</table>';
    }
    // Slurm jobs (on-demand)
    const sj = m.slurm_jobs || [];
    if (sj.length) {
      html += '<div style="font-size:12px;color:var(--dim);margin-top:4px">Slurm jobs: ' + sj.join(', ') + '</div>';
    }
    html += '</div>';
    return html;
  }).join('');
}

function render_gpu(data) {
  const el = document.getElementById('gpu');
  if (!data || !data.length) { el.innerHTML = '<div class="empty">No GPU data (nvidia-smi unavailable)</div>'; return; }
  el.innerHTML = data.map(g => {
    const mem_pct = g.mem_total_mb > 0 ? (g.mem_used_mb / g.mem_total_mb * 100) : 0;
    return '<div class="gpu-row">' +
      '<div class="gpu-label">GPU' + g.index + ' ' + esc(g.name) + '</div>' +
      '<div class="gpu-bar-wrap">' +
        progress_bar(g.util_pct, 'Util: ' + g.util_pct + '%', 'blue') +
        '<div style="height:3px"></div>' +
        progress_bar(mem_pct, 'VRAM: ' + g.mem_used_mb + '/' + g.mem_total_mb + ' MiB', 'cyan') +
      '</div>' +
      '<div class="gpu-temp" style="color:' + (g.temp_c > 80 ? 'var(--red)' : g.temp_c > 65 ? 'var(--yellow)' : 'var(--green)') + '">' +
        g.temp_c + '°C</div></div>';
  }).join('');
}

function render_host(data) {
  const el = document.getElementById('host');
  if (!data) { el.innerHTML = '<div class="empty">No host data</div>'; return; }
  let html = '<div class="cards">';
  // CPU — agent sends idle/total counters; we derive % from delta
  if (data.cpu) {
    const cpuPct = render_host._prevCpu
      ? (() => {
          const dIdle = data.cpu.idle - render_host._prevCpu.idle;
          const dTotal = data.cpu.total - render_host._prevCpu.total;
          return dTotal > 0 ? ((1 - dIdle/dTotal) * 100) : 0;
        })()
      : 0;
    render_host._prevCpu = { idle: data.cpu.idle, total: data.cpu.total };
    html += '<div class="card"><div class="card-label">CPU</div>' +
      progress_bar(cpuPct, cpuPct.toFixed(1) + '%') + '</div>';
  }
  // RAM
  if (data.ram) {
    const pct = data.ram.total > 0 ? (data.ram.used / data.ram.total * 100) : 0;
    html += '<div class="card"><div class="card-label">RAM</div>' +
      progress_bar(pct, fmt_bytes(data.ram.used) + ' / ' + fmt_bytes(data.ram.total)) + '</div>';
  }
  // Disks
  (data.disks || []).forEach(d => {
    const pct = d.total > 0 ? (d.used / d.total * 100) : 0;
    html += '<div class="card"><div class="card-label">Disk: ' + esc(d.mount) + '</div>' +
      progress_bar(pct, fmt_bytes(d.used) + ' / ' + fmt_bytes(d.total)) + '</div>';
  });
  html += '</div>';
  el.innerHTML = html;
}
render_host._prevCpu = null;

function render_partitions(data) {
  const el = document.getElementById('partitions');
  if (!data || !data.length) { el.innerHTML = '<div class="empty">No partition data (sinfo unavailable)</div>'; return; }
  let html = '<table><tr><th>Partition</th><th>Avail</th><th>Nodes</th><th>Alloc</th><th>Idle</th><th>Time Limit</th><th>CPUs (A/I/O/T)</th></tr>';
  data.forEach(p => {
    const av = p.avail === 'up' ? '<span style="color:var(--green)">up</span>' : '<span style="color:var(--red)">' + esc(p.avail) + '</span>';
    html += '<tr><td>' + esc(p.partition) + (p.default ? ' *' : '') + '</td>' +
      '<td>' + av + '</td><td>' + p.nodes + '</td>' +
      '<td>' + p.nodes_alloc + '</td><td>' + p.nodes_idle + '</td>' +
      '<td>' + esc(p.timelimit) + '</td>' +
      '<td>' + p.cpus_alloc + '/' + p.cpus_idle + '/' + p.cpus_other + '/' + p.cpus_total + '</td></tr>';
  });
  html += '</table>';
  el.innerHTML = html;
}

function render_jobs(data) {
  const el = document.getElementById('jobs');
  if (!data || !data.length) { el.innerHTML = '<div class="empty">No active jobs</div>'; return; }
  let html = '<table><tr><th>Job ID</th><th>Name</th><th>User</th><th>Partition</th><th>State</th><th>Node</th><th>Time</th><th>Reason</th><th>GRES</th></tr>';
  data.forEach(j => {
    const is_stroma = (j.name||'').startsWith('stroma');
    const cls = is_stroma ? ' class="stroma"' : '';
    const st = j.state || '';
    let st_html = esc(st);
    if (st === 'RUNNING') st_html = '<span style="color:var(--green)">' + st + '</span>';
    else if (st === 'PENDING') st_html = '<span style="color:var(--yellow)">' + st + '</span>';
    else if (st === 'FAILED' || st === 'CANCELLED') st_html = '<span style="color:var(--red)">' + st + '</span>';
    html += '<tr' + cls + '><td>' + esc(j.job_id) + '</td><td>' + esc(j.name) + '</td>' +
      '<td>' + esc(j.user) + '</td><td>' + esc(j.partition) + '</td>' +
      '<td>' + st_html + '</td><td>' + esc(j.node) + '</td>' +
      '<td>' + esc(j.time) + '</td><td>' + esc(j.reason) + '</td>' +
      '<td>' + esc(j.gres) + '</td></tr>';
  });
  html += '</table>';
  el.innerHTML = html;
}

function render_network(data) {
  const el = document.getElementById('network');
  if (!data || !data.length) { el.innerHTML = '<div class="empty">No network data</div>'; return; }
  let html = '<table><tr><th>Interface</th><th>State</th><th>Addresses</th><th>RX</th><th>TX</th></tr>';
  data.forEach(n => {
    const st = n.state === 'UP' ? '<span style="color:var(--green)">UP</span>' :
               n.state === 'DOWN' ? '<span style="color:var(--red)">DOWN</span>' :
               esc(n.state);
    const addrs = (n.addresses||[]).map(a => esc(a)).join('<br>');
    html += '<tr><td>' + esc(n.name) + '</td><td>' + st + '</td>' +
      '<td class="net-ips">' + (addrs || '—') + '</td>' +
      '<td>' + fmt_bytes(n.rx_bytes) + '</td><td>' + fmt_bytes(n.tx_bytes) + '</td></tr>';
  });
  html += '</table>';
  el.innerHTML = html;
}

// =========================================================================
// WebSocket
// =========================================================================
let ws = null;
let reconnectTimer = null;

function connect() {
  const proto = location.protocol === 'https:' ? 'wss:' : 'ws:';
  ws = new WebSocket(proto + '//' + location.host + '/ws');

  ws.onopen = () => {
    document.getElementById('conn-dot').className = 'dot dot-green';
    document.getElementById('conn-text').textContent = 'Connected';
    if (reconnectTimer) { clearTimeout(reconnectTimer); reconnectTimer = null; }
  };

  ws.onmessage = (ev) => {
    try {
      const d = JSON.parse(ev.data);
      if (d.error && !d.services) {
        document.getElementById('error-banner').style.display = 'block';
        document.getElementById('error-banner').textContent = 'Agent error: ' + d.error;
        return;
      }
      document.getElementById('error-banner').style.display = 'none';
      document.getElementById('last-update').textContent = fmt_ts(d.ts);
      render_services(d.services);
      render_vllm(d.vllm);
      render_models(d.watcher);
      render_gpu(d.gpu);
      render_host(d.host);
      render_partitions(d.partitions);
      render_jobs(d.jobs);
      render_network(d.network);
    } catch(e) { console.error('Parse error:', e); }
  };

  ws.onclose = () => {
    document.getElementById('conn-dot').className = 'dot dot-red';
    document.getElementById('conn-text').textContent = 'Disconnected — reconnecting…';
    if (!reconnectTimer) reconnectTimer = setTimeout(connect, 3000);
  };

  ws.onerror = () => { ws.close(); };
}

connect();
</script>
</body>
</html>"""


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main() -> None:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)-7s %(name)s  %(message)s",
    )
    app = web.Application()
    app.router.add_get("/", handle_index)
    app.router.add_get("/ws", handle_ws)
    app.on_startup.append(start_background)
    app.on_cleanup.append(stop_background)
    log.info(
        "Starting dashboard on 0.0.0.0:%d (agent=%s, poll=%ds)",
        PORT, AGENT_URL, POLL_SECS,
    )
    web.run_app(app, host="0.0.0.0", port=PORT, print=None)


if __name__ == "__main__":
    main()
