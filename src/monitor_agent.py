#!/usr/bin/env python3
"""
StromaAI — Monitor Agent
=========================
Lightweight metrics-collection service that runs on the head node (red-a70).
Exposes ``GET /metrics`` returning a JSON snapshot of all infrastructure state.

All collectors execute in parallel via ``asyncio.gather``.  Results are cached
for a configurable number of seconds to avoid hammering subprocess / HTTP on
rapid requests.

Environment variables
---------------------
STROMA_MONITOR_AGENT_PORT   Listen port (default 9201)
STROMA_MONITOR_SERVICES     Comma-separated systemd service names to monitor
STROMA_WATCHER_PORT         Model-watcher HTTP port (default 9100)
STROMA_VLLM_PORT            vLLM HTTP port (default 8000)
STROMA_MONITOR_CACHE_SECS   Cache lifetime in seconds (default 5)
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import re
import subprocess
import time
from pathlib import Path
from typing import Any, Optional

from aiohttp import ClientSession, ClientTimeout, web

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

PORT = int(os.environ.get("STROMA_MONITOR_AGENT_PORT", "9201"))
CACHE_SECS = int(os.environ.get("STROMA_MONITOR_CACHE_SECS", "5"))

DEFAULT_SERVICES = (
    "ray-head,"
    "stroma-ai-vllm,"
    "stroma-ai-model-watcher,"
    "stroma-ai-watcher,"
    "stroma-ai-gateway"
)
SERVICES = [
    s.strip()
    for s in os.environ.get("STROMA_MONITOR_SERVICES", DEFAULT_SERVICES).split(",")
    if s.strip()
]

WATCHER_PORT = int(os.environ.get("STROMA_WATCHER_PORT", "9100"))
VLLM_PORT = int(os.environ.get("STROMA_VLLM_PORT", "8000"))

log = logging.getLogger("monitor-agent")

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

async def _run(cmd: list[str], timeout: float = 10) -> str:
    """Run *cmd* asynchronously and return stdout (empty string on failure)."""
    try:
        proc = await asyncio.create_subprocess_exec(
            *cmd,
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        stdout, _ = await asyncio.wait_for(proc.communicate(), timeout=timeout)
        return stdout.decode(errors="replace").strip()
    except Exception:
        return ""


async def _http_get_json(url: str, timeout: float = 5) -> Optional[dict]:
    """GET *url* and return parsed JSON, or ``None`` on any failure."""
    try:
        async with ClientSession(timeout=ClientTimeout(total=timeout)) as s:
            async with s.get(url) as resp:
                if resp.status == 200:
                    return await resp.json()
    except Exception:
        pass
    return None


async def _http_get_text(url: str, timeout: float = 5) -> Optional[str]:
    """GET *url* and return body text, or ``None`` on any failure."""
    try:
        async with ClientSession(timeout=ClientTimeout(total=timeout)) as s:
            async with s.get(url) as resp:
                if resp.status == 200:
                    return await resp.text()
    except Exception:
        pass
    return None


# ---------------------------------------------------------------------------
# Collectors
# ---------------------------------------------------------------------------

async def collect_services() -> list[dict]:
    """Systemd service status and uptime."""
    results = []
    for svc in SERVICES:
        name = f"{svc}.service"
        active = await _run(["systemctl", "is-active", svc])
        since = ""
        if active == "active":
            raw = await _run([
                "systemctl", "show", svc,
                "--property=ActiveEnterTimestamp", "--value",
            ])
            since = raw.strip()
        results.append({
            "name": svc,
            "active": active or "unknown",
            "since": since,
        })
    return results


async def collect_partitions() -> list[dict]:
    """All Slurm partitions via sinfo."""
    out = await _run([
        "sinfo", "--noheader",
        "-o", "%P %a %D %A %l %C",
    ])
    rows = []
    for line in out.splitlines():
        parts = line.split()
        if len(parts) < 6:
            continue
        # CPUs field is "allocated/idle/other/total"
        cpus = parts[5].split("/")
        alloc_idle = parts[3].split("/")  # allocated/idle nodes
        rows.append({
            "partition": parts[0].rstrip("*"),
            "default": parts[0].endswith("*"),
            "avail": parts[1],
            "nodes": int(parts[2]),
            "nodes_alloc": int(alloc_idle[0]) if len(alloc_idle) > 0 else 0,
            "nodes_idle": int(alloc_idle[1]) if len(alloc_idle) > 1 else 0,
            "timelimit": parts[4],
            "cpus_alloc": int(cpus[0]) if len(cpus) > 0 else 0,
            "cpus_idle": int(cpus[1]) if len(cpus) > 1 else 0,
            "cpus_other": int(cpus[2]) if len(cpus) > 2 else 0,
            "cpus_total": int(cpus[3]) if len(cpus) > 3 else 0,
        })
    return rows


async def collect_jobs() -> list[dict]:
    """All Slurm jobs via squeue."""
    out = await _run([
        "squeue", "--noheader",
        "-o", "%i|%j|%u|%P|%T|%N|%M|%r|%b",
    ])
    rows = []
    for line in out.splitlines():
        parts = line.split("|", 8)
        if len(parts) < 9:
            continue
        rows.append({
            "job_id": parts[0].strip(),
            "name": parts[1].strip(),
            "user": parts[2].strip(),
            "partition": parts[3].strip(),
            "state": parts[4].strip(),
            "node": parts[5].strip(),
            "time": parts[6].strip(),
            "reason": parts[7].strip(),
            "gres": parts[8].strip(),
        })
    return rows


async def collect_gpu() -> list[dict]:
    """Head-node GPU utilization via nvidia-smi."""
    out = await _run([
        "nvidia-smi",
        "--query-gpu=index,name,utilization.gpu,memory.used,memory.total,temperature.gpu",
        "--format=csv,noheader,nounits",
    ])
    gpus = []
    for line in out.splitlines():
        parts = [p.strip() for p in line.split(",")]
        if len(parts) < 6:
            continue
        try:
            gpus.append({
                "index": int(parts[0]),
                "name": parts[1],
                "util_pct": int(parts[2]),
                "mem_used_mb": int(parts[3]),
                "mem_total_mb": int(parts[4]),
                "temp_c": int(parts[5]),
            })
        except (ValueError, IndexError):
            continue
    return gpus


async def collect_host() -> dict:
    """CPU, RAM, and disk utilisation from /proc and df."""
    result: dict[str, Any] = {}

    # --- CPU ---
    try:
        with open("/proc/stat") as f:
            line = f.readline()
        fields = line.split()[1:]  # user nice system idle iowait irq softirq steal
        vals = [int(v) for v in fields[:8]]
        idle = vals[3] + vals[4]  # idle + iowait
        total = sum(vals)
        result["cpu"] = {"idle": idle, "total": total}
    except Exception:
        result["cpu"] = None

    # --- RAM ---
    try:
        info: dict[str, int] = {}
        with open("/proc/meminfo") as f:
            for line in f:
                if line.startswith(("MemTotal:", "MemAvailable:", "MemFree:", "Buffers:", "Cached:")):
                    key, val = line.split(":")
                    info[key.strip()] = int(val.split()[0]) * 1024  # kB → bytes
        total = info.get("MemTotal", 0)
        avail = info.get("MemAvailable", info.get("MemFree", 0))
        result["ram"] = {
            "total": total,
            "used": total - avail,
            "available": avail,
        }
    except Exception:
        result["ram"] = None

    # --- Disk ---
    disks = []
    for mount in ["/", "/share"]:
        out = await _run(["df", "-B1", mount])
        lines = out.splitlines()
        if len(lines) >= 2:
            parts = lines[1].split()
            if len(parts) >= 6:
                try:
                    disks.append({
                        "mount": mount,
                        "total": int(parts[1]),
                        "used": int(parts[2]),
                        "available": int(parts[3]),
                    })
                except ValueError:
                    pass
    result["disks"] = disks
    return result


async def collect_network() -> list[dict]:
    """Network interfaces: names, states, IPs, traffic counters."""
    interfaces: dict[str, dict] = {}

    # ip -j addr for names, states, addresses
    out = await _run(["ip", "-j", "addr"])
    if out:
        try:
            for iface in json.loads(out):
                name = iface.get("ifname", "?")
                state = iface.get("operstate", "UNKNOWN")
                addrs = []
                for a in iface.get("addr_info", []):
                    addrs.append(f"{a.get('local', '?')}/{a.get('prefixlen', '?')}")
                interfaces[name] = {
                    "name": name,
                    "state": state,
                    "addresses": addrs,
                    "rx_bytes": 0,
                    "tx_bytes": 0,
                }
        except (json.JSONDecodeError, TypeError):
            pass

    # /proc/net/dev for counters
    try:
        with open("/proc/net/dev") as f:
            for line in f:
                if ":" not in line:
                    continue
                name, rest = line.split(":", 1)
                name = name.strip()
                vals = rest.split()
                if len(vals) >= 10 and name in interfaces:
                    interfaces[name]["rx_bytes"] = int(vals[0])
                    interfaces[name]["tx_bytes"] = int(vals[8])
    except Exception:
        pass

    return list(interfaces.values())


async def collect_watcher() -> Optional[dict]:
    """Model-watcher /status endpoint."""
    return await _http_get_json(f"http://127.0.0.1:{WATCHER_PORT}/status")


async def collect_vllm() -> Optional[dict]:
    """Parse vLLM Prometheus /metrics text into key metrics."""
    text = await _http_get_text(f"http://127.0.0.1:{VLLM_PORT}/metrics")
    if not text:
        return None

    metrics: dict[str, Any] = {}

    # Gauge patterns
    gauge_patterns = {
        "requests_waiting": r"^vllm:num_requests_waiting\b.*?\s+([\d.eE+-]+)",
        "requests_running": r"^vllm:num_requests_running\b.*?\s+([\d.eE+-]+)",
        "requests_swapped": r"^vllm:num_requests_swapped\b.*?\s+([\d.eE+-]+)",
        "gpu_cache_pct": r"^vllm:gpu_cache_usage_perc\b.*?\s+([\d.eE+-]+)",
        "cpu_cache_pct": r"^vllm:cpu_cache_usage_perc\b.*?\s+([\d.eE+-]+)",
    }
    for key, pattern in gauge_patterns.items():
        m = re.search(pattern, text, re.MULTILINE)
        metrics[key] = float(m.group(1)) if m else None

    # Histogram sum/count → avg
    for label, prefix in [
        ("avg_latency_s", "vllm:e2e_request_latency_seconds"),
        ("avg_ttft_s", "vllm:time_to_first_token_seconds"),
    ]:
        sum_m = re.search(
            rf"^{re.escape(prefix)}_sum\b.*?\s+([\d.eE+-]+)", text, re.MULTILINE,
        )
        count_m = re.search(
            rf"^{re.escape(prefix)}_count\b.*?\s+([\d.eE+-]+)", text, re.MULTILINE,
        )
        if sum_m and count_m:
            s, c = float(sum_m.group(1)), float(count_m.group(1))
            metrics[label] = round(s / c, 4) if c > 0 else 0
        else:
            metrics[label] = None

    return metrics


# ---------------------------------------------------------------------------
# Aggregate + Cache
# ---------------------------------------------------------------------------

_cache: dict[str, Any] = {}
_cache_ts: float = 0.0


async def gather_all() -> dict:
    global _cache, _cache_ts
    now = time.monotonic()
    if _cache and (now - _cache_ts) < CACHE_SECS:
        return _cache

    (
        services,
        partitions,
        jobs,
        gpu,
        host,
        network,
        watcher,
        vllm,
    ) = await asyncio.gather(
        collect_services(),
        collect_partitions(),
        collect_jobs(),
        collect_gpu(),
        collect_host(),
        collect_network(),
        collect_watcher(),
        collect_vllm(),
    )

    _cache = {
        "ts": time.time(),
        "services": services,
        "partitions": partitions,
        "jobs": jobs,
        "gpu": gpu,
        "host": host,
        "network": network,
        "watcher": watcher,
        "vllm": vllm,
    }
    _cache_ts = now
    return _cache


# ---------------------------------------------------------------------------
# HTTP handler
# ---------------------------------------------------------------------------

async def handle_metrics(request: web.Request) -> web.Response:
    data = await gather_all()
    return web.json_response(data)


async def handle_health(request: web.Request) -> web.Response:
    return web.json_response({"status": "ok", "service": "stroma-monitor-agent"})


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main() -> None:
    logging.basicConfig(
        level=logging.INFO,
        format="%(asctime)s %(levelname)-7s %(name)s  %(message)s",
    )
    app = web.Application()
    app.router.add_get("/metrics", handle_metrics)
    app.router.add_get("/health", handle_health)
    log.info("Starting monitor agent on 0.0.0.0:%d (cache=%ds)", PORT, CACHE_SECS)
    web.run_app(app, host="0.0.0.0", port=PORT, print=None)


if __name__ == "__main__":
    main()
