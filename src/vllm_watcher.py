#!/usr/bin/env python3
"""
AI_Flux — vLLM Watcher
=======================
Dynamically bursts Slurm GPU nodes into the Ray cluster based on vLLM queue
depth, then scales them back down when idle.

Architecture
------------
  Proxmox VM (Debian)
    ├── ray start --head --port=6380
    ├── vllm serve ... --worker-use-ray          (vLLM + Ray Serve)
    └── vllm_watcher.py  ←  this script

  Slurm GPU nodes (RHEL)
    └── apptainer exec --nv ai-flux-vllm.sif \\
          ray start --address=HEAD:6380 --num-gpus=1 --block

State machine per burst job
---------------------------
  pending  → Slurm submitted; job not yet RUNNING
  running  → Slurm is RUNNING; worker not yet visible in Ray
  joined   → Worker confirmed in Ray cluster with GPU resources
  (removed on scale-down or when Slurm job disappears)

Configuration
-------------
  All parameters come from environment variables (see config.example.env).
  Systemd EnvironmentFile= sources /opt/ai-flux/config.env before start.

Requires
--------
  pip install requests ray
  (ray must match the version used in ai-flux-vllm.sif)
"""

from __future__ import annotations

import json
import logging
import os
import re
import signal
import subprocess
import sys
import time
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

import requests

# ---------------------------------------------------------------------------
# Configuration — all sourced from environment variables, never hardcoded
# ---------------------------------------------------------------------------

HEAD_HOST     = os.environ.get("AI_FLUX_HEAD_HOST", "localhost")
RAY_PORT      = int(os.environ.get("AI_FLUX_RAY_PORT", "6380"))
VLLM_PORT     = int(os.environ.get("AI_FLUX_VLLM_PORT", "8000"))
API_KEY       = os.environ.get("AI_FLUX_API_KEY", "")
MAX_BURST     = int(os.environ.get("AI_FLUX_MAX_BURST_WORKERS", "5"))
UP_THRESHOLD  = int(os.environ.get("AI_FLUX_SCALE_UP_THRESHOLD", "2"))
DOWN_IDLE_S   = int(os.environ.get("AI_FLUX_SCALE_DOWN_IDLE_SECONDS", "300"))
UP_COOLDOWN   = int(os.environ.get("AI_FLUX_SCALE_UP_COOLDOWN", "300"))
POLL_S        = int(os.environ.get("AI_FLUX_WATCHER_POLL_INTERVAL", "30"))
SLURM_PART    = os.environ.get("AI_FLUX_SLURM_PARTITION", "ai-flux-gpu")
SLURM_ACCT    = os.environ.get("AI_FLUX_SLURM_ACCOUNT", "ai-flux-service")
SLURM_SCRIPT  = os.environ.get("AI_FLUX_SLURM_SCRIPT", "/shared/slurm/ai_flux_worker.slurm")
SLURM_TIME    = os.environ.get("AI_FLUX_SLURM_WALLTIME", "7-00:00:00")
STATE_FILE    = os.environ.get("AI_FLUX_STATE_FILE", "/opt/ai-flux/watcher_state.json")

VLLM_BASE     = f"http://{HEAD_HOST}:{VLLM_PORT}"
RAY_ADDR      = f"{HEAD_HOST}:{RAY_PORT}"

# Job state constants
ST_PENDING  = "pending"   # sbatch submitted; job not RUNNING yet
ST_RUNNING  = "running"   # Slurm RUNNING; worker not visible in Ray yet
ST_JOINED   = "joined"    # confirmed in Ray cluster with GPU resource

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)-8s %(name)s — %(message)s",
    handlers=[logging.StreamHandler(sys.stdout)],
)
log = logging.getLogger("ai-flux-watcher")


# ---------------------------------------------------------------------------
# Persistent state
# ---------------------------------------------------------------------------

@dataclass
class WatcherState:
    """
    All mutable watcher state. Persisted atomically to STATE_FILE after every
    change so the watcher can resume correctly after a restart or crash.
    """
    jobs: dict[str, dict] = field(default_factory=dict)
    # job_id -> {state, submitted_at, ray_node_id, ...}

    last_scale_up: Optional[str] = None   # ISO-8601 timestamp of last sbatch
    idle_since: Optional[str] = None      # ISO-8601 when queue first hit zero
    total_submitted: int = 0
    total_cancelled: int = 0


def load_state() -> WatcherState:
    """Load state from disk. Returns a fresh WatcherState if file missing/corrupt."""
    try:
        data = json.loads(Path(STATE_FILE).read_text())
        s = WatcherState(
            jobs=data.get("jobs", {}),
            last_scale_up=data.get("last_scale_up"),
            idle_since=data.get("idle_since"),
            total_submitted=data.get("total_submitted", 0),
            total_cancelled=data.get("total_cancelled", 0),
        )
        log.info("Loaded state from %s: %d job(s) tracked", STATE_FILE, len(s.jobs))
        return s
    except FileNotFoundError:
        log.info("No state file at %s — starting fresh", STATE_FILE)
        return WatcherState()
    except (json.JSONDecodeError, KeyError) as exc:
        log.warning("State file unreadable (%s) — starting fresh", exc)
        return WatcherState()


def persist(state: WatcherState) -> None:
    """Atomically write state to STATE_FILE via a tmp-file rename."""
    Path(STATE_FILE).parent.mkdir(parents=True, exist_ok=True)
    tmp = STATE_FILE + ".tmp"
    Path(tmp).write_text(json.dumps(asdict(state), indent=2, default=str))
    os.replace(tmp, STATE_FILE)  # POSIX atomic rename


# ---------------------------------------------------------------------------
# vLLM helpers
# ---------------------------------------------------------------------------

def _auth_headers() -> dict:
    return {"Authorization": f"Bearer {API_KEY}"} if API_KEY else {}


def vllm_healthy() -> bool:
    """Return True if the vLLM /health endpoint responds 200."""
    try:
        r = requests.get(f"{VLLM_BASE}/health", headers=_auth_headers(), timeout=5)
        return r.status_code == 200
    except requests.RequestException:
        return False


def fetch_metrics() -> dict[str, float]:
    """
    Parse Prometheus-format metrics from vLLM /metrics endpoint.
    Returns a flat dict of metric_name -> float value.
    Key metrics used by the watcher:
      vllm:num_requests_waiting  — requests queued (no GPU slot yet)
      vllm:num_requests_running  — requests actively being processed
    """
    try:
        r = requests.get(f"{VLLM_BASE}/metrics", headers=_auth_headers(), timeout=10)
        r.raise_for_status()
    except requests.RequestException as exc:
        log.warning("Metrics unavailable: %s", exc)
        return {}

    out: dict[str, float] = {}
    for line in r.text.splitlines():
        if line.startswith("#") or not line.strip():
            continue
        # Match: vllm:metric_name{labels...} value  OR  vllm:metric_name value
        m = re.match(r'^(vllm:\w+)(?:\{[^}]*\})?\s+([\d.]+(?:[eE][+-]?\d+)?)', line)
        if m:
            try:
                out[m.group(1)] = float(m.group(2))
            except ValueError:
                pass
    return out


# ---------------------------------------------------------------------------
# Slurm helpers
# ---------------------------------------------------------------------------

def slurm_submit() -> Optional[str]:
    """
    Submit a burst worker via sbatch.
    Passes HEAD_HOST and RAY_PORT via --export so the worker script can
    connect to the correct Ray cluster without hardcoding.
    Returns the Slurm job ID string, or None on failure.
    """
    cmd = [
        "sbatch",
        f"--partition={SLURM_PART}",
        f"--account={SLURM_ACCT}",
        f"--time={SLURM_TIME}",
        # Pass connection params to the worker script via env vars
        f"--export=ALL,AI_FLUX_HEAD_HOST={HEAD_HOST},AI_FLUX_RAY_PORT={RAY_PORT}",
        SLURM_SCRIPT,
    ]
    try:
        r = subprocess.run(cmd, capture_output=True, text=True, timeout=30, check=False)
    except (subprocess.SubprocessError, FileNotFoundError) as exc:
        log.error("sbatch execution failed: %s", exc)
        return None

    if r.returncode != 0:
        log.error("sbatch returned rc=%d: %s", r.returncode, r.stderr.strip())
        return None

    m = re.search(r"Submitted batch job (\d+)", r.stdout)
    if not m:
        log.error("Unexpected sbatch output: %r", r.stdout.strip())
        return None

    job_id = m.group(1)
    log.info("Submitted burst worker job %s", job_id)
    return job_id


def slurm_job_state(job_id: str) -> Optional[str]:
    """
    Return the Slurm job state string (PENDING, RUNNING, COMPLETING, etc.)
    or None if the job is no longer in the queue.
    """
    try:
        r = subprocess.run(
            ["squeue", "-j", job_id, "-h", "-o", "%T"],
            capture_output=True, text=True, timeout=15, check=False,
        )
        state = r.stdout.strip()
        return state if state else None
    except (subprocess.SubprocessError, FileNotFoundError):
        return None


def slurm_active_ids(job_ids: list[str]) -> set[str]:
    """Return the subset of job_ids that are still present in Slurm (any state)."""
    if not job_ids:
        return set()
    try:
        r = subprocess.run(
            ["squeue", "-j", ",".join(job_ids), "-h", "-o", "%i"],
            capture_output=True, text=True, timeout=15, check=False,
        )
        return {line.strip() for line in r.stdout.splitlines() if line.strip()}
    except (subprocess.SubprocessError, FileNotFoundError):
        return set()


def slurm_cancel(job_id: str) -> None:
    """Cancel a Slurm job. Logs but does not raise on failure."""
    try:
        r = subprocess.run(
            ["scancel", job_id],
            capture_output=True, text=True, timeout=15, check=False,
        )
        if r.returncode == 0:
            log.info("Cancelled Slurm job %s", job_id)
        else:
            log.warning("scancel %s rc=%d: %s", job_id, r.returncode, r.stderr.strip())
    except (subprocess.SubprocessError, FileNotFoundError) as exc:
        log.error("scancel %s failed: %s", job_id, exc)


# ---------------------------------------------------------------------------
# Ray helpers
# ---------------------------------------------------------------------------

def ray_gpu_node_ids() -> set[str]:
    """
    Return the set of live Ray node IDs that have at least one GPU resource.
    These are the Slurm burst workers currently providing capacity.

    Uses the Ray Python API lazily — imported here to avoid hard dependency
    at module load (fails gracefully if Ray is not installed on the head node
    outside the container).
    """
    try:
        import ray  # type: ignore  # noqa: PLC0415
        if not ray.is_initialized():
            ray.init(
                address=f"ray://{RAY_ADDR}",
                ignore_reinit_error=True,
                logging_level="ERROR",
            )
        return {
            n["NodeID"]
            for n in ray.nodes()
            if n.get("Alive") and float(n.get("Resources", {}).get("GPU", 0)) > 0
        }
    except Exception as exc:  # noqa: BLE001
        log.debug("Ray node query failed: %s", exc)
        return set()


# ---------------------------------------------------------------------------
# Time helpers
# ---------------------------------------------------------------------------

def _now() -> datetime:
    return datetime.now(timezone.utc)


def _iso() -> str:
    return _now().isoformat()


def _seconds_since(iso: Optional[str]) -> float:
    """Seconds elapsed since an ISO-8601 timestamp. Returns ∞ if None."""
    if iso is None:
        return float("inf")
    try:
        return (_now() - datetime.fromisoformat(iso)).total_seconds()
    except ValueError:
        return float("inf")


# ---------------------------------------------------------------------------
# State machine logic
# ---------------------------------------------------------------------------

def reconcile_against_slurm(state: WatcherState) -> bool:
    """
    Drop any tracked jobs that are no longer present in Slurm.
    This handles cases where jobs were manually cancelled, hit walltime,
    or were orphaned by a previous watcher crash.
    Returns True if state was modified.
    """
    if not state.jobs:
        return False
    still_active = slurm_active_ids(list(state.jobs.keys()))
    dead = set(state.jobs) - still_active
    if not dead:
        return False
    for jid in dead:
        log.info("Job %s no longer in Slurm — removing from tracked state", jid)
        del state.jobs[jid]
    return True


def advance_pending_jobs(state: WatcherState, known_ray_nodes: set[str]) -> set[str]:
    """
    Non-blocking state transitions for pending/running jobs:
      pending → running  when Slurm reports RUNNING
      running → joined   when a new GPU node appears in Ray
    Returns newly discovered Ray node IDs.
    """
    new_ray_nodes: set[str] = set()

    for jid, rec in list(state.jobs.items()):
        job_state = rec.get("state", ST_PENDING)

        if job_state == ST_PENDING:
            slurm_st = slurm_job_state(jid)
            if slurm_st == "RUNNING":
                log.info("Job %s is RUNNING in Slurm — watching for Ray join", jid)
                rec["state"] = ST_RUNNING
                state.jobs[jid] = rec
            elif slurm_st is None:
                log.warning("Job %s disappeared before reaching RUNNING", jid)
                del state.jobs[jid]

        elif job_state == ST_RUNNING:
            current_nodes = ray_gpu_node_ids()
            appeared = current_nodes - known_ray_nodes
            if appeared:
                node_id = next(iter(appeared))
                log.info("Job %s joined Ray cluster — node %s", jid, node_id)
                rec["state"] = ST_JOINED
                rec["ray_node_id"] = node_id
                state.jobs[jid] = rec
                new_ray_nodes.add(node_id)
                known_ray_nodes = known_ray_nodes | new_ray_nodes
            elif slurm_job_state(jid) is None:
                log.warning("Job %s finished Slurm without joining Ray", jid)
                del state.jobs[jid]

    return new_ray_nodes


def scale_up_ok(state: WatcherState) -> bool:
    return (
        len(state.jobs) < MAX_BURST
        and _seconds_since(state.last_scale_up) >= UP_COOLDOWN
    )


# ---------------------------------------------------------------------------
# Main tick
# ---------------------------------------------------------------------------

def tick(state: WatcherState, known_ray_nodes: set[str]) -> set[str]:
    """
    Execute one watcher cycle. Mutates state in place and persists if changed.
    Returns the updated set of known Ray GPU node IDs.
    """
    changed = reconcile_against_slurm(state)

    # Always health-check before making scaling decisions
    if not vllm_healthy():
        log.warning("vLLM /health check failed — skipping scaling decisions this tick")
        if changed:
            persist(state)
        return known_ray_nodes

    metrics  = fetch_metrics()
    waiting  = int(metrics.get("vllm:num_requests_waiting", 0))
    running  = int(metrics.get("vllm:num_requests_running", 0))
    n_burst  = len(state.jobs)
    cooldown_remaining = max(0.0, UP_COOLDOWN - _seconds_since(state.last_scale_up))

    # Advance pending → running → joined (non-blocking, one step per tick)
    new_nodes = advance_pending_jobs(state, known_ray_nodes)
    known_ray_nodes = known_ray_nodes | new_nodes
    if new_nodes:
        changed = True

    log.info(
        "Queue: waiting=%d running=%d | Burst: %d/%d active | Cooldown: %.0fs",
        waiting, running, n_burst, MAX_BURST, cooldown_remaining,
    )

    # ----------------------------------------------------------------
    # Scale-up decision
    # ----------------------------------------------------------------
    if waiting >= UP_THRESHOLD and scale_up_ok(state):
        jid = slurm_submit()
        if jid:
            state.jobs[jid] = {
                "state": ST_PENDING,
                "submitted_at": _iso(),
                "ray_node_id": None,
            }
            state.last_scale_up = _iso()
            state.total_submitted += 1
            state.idle_since = None  # reset idle timer on any scale-up
            changed = True
            log.info(
                "Scale-up: submitted job %s (%d/%d burst workers active)",
                jid, n_burst + 1, MAX_BURST,
            )

    # ----------------------------------------------------------------
    # Scale-down decision
    # ----------------------------------------------------------------
    elif waiting == 0 and running == 0 and n_burst > 0:
        if state.idle_since is None:
            state.idle_since = _iso()
            changed = True
            log.info("Queue empty — idle timer started (threshold: %ds)", DOWN_IDLE_S)
        else:
            idle_s = _seconds_since(state.idle_since)
            log.info("Idle for %.0fs / %ds threshold", idle_s, DOWN_IDLE_S)
            if idle_s >= DOWN_IDLE_S:
                joined = [jid for jid, r in state.jobs.items() if r.get("state") == ST_JOINED]
                if joined:
                    log.info(
                        "Idle threshold reached — cancelling %d burst job(s)", len(joined)
                    )
                    for jid in joined:
                        slurm_cancel(jid)
                        del state.jobs[jid]
                        state.total_cancelled += 1
                    state.idle_since = None
                    changed = True

    # ----------------------------------------------------------------
    # Activity seen — reset idle timer
    # ----------------------------------------------------------------
    elif (waiting > 0 or running > 0) and state.idle_since is not None:
        state.idle_since = None
        changed = True

    if changed:
        persist(state)

    return known_ray_nodes


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main() -> None:
    log.info(
        "AI_Flux Watcher starting — HEAD=%s RAY_PORT=%d VLLM_PORT=%d MAX_BURST=%d",
        HEAD_HOST, RAY_PORT, VLLM_PORT, MAX_BURST,
    )
    log.info(
        "Thresholds — scale_up>=%d waiting, scale_down_idle=%ds, cooldown=%ds",
        UP_THRESHOLD, DOWN_IDLE_S, UP_COOLDOWN,
    )

    state = load_state()
    known_ray_nodes = ray_gpu_node_ids()
    log.info("Currently %d Ray GPU node(s) visible at startup", len(known_ray_nodes))

    stop = False

    def _on_signal(sig: int, _frame: object) -> None:
        nonlocal stop
        log.info("Signal %d received — stopping after current tick", sig)
        stop = True

    signal.signal(signal.SIGTERM, _on_signal)
    signal.signal(signal.SIGINT, _on_signal)

    while not stop:
        try:
            known_ray_nodes = tick(state, known_ray_nodes)
        except Exception:  # noqa: BLE001
            log.exception("Unhandled error in tick — continuing")
        time.sleep(POLL_S)

    log.info(
        "Watcher stopped cleanly (lifetime: submitted=%d cancelled=%d)",
        state.total_submitted, state.total_cancelled,
    )


if __name__ == "__main__":
    main()
