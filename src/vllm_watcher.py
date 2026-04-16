#!/usr/bin/env python3
"""
StromaAI — vLLM Watcher
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
    └── apptainer exec --nv stroma-ai-vllm.sif \\
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
  Systemd EnvironmentFile= sources /opt/stroma-ai/config.env before start.

Requires
--------
  pip install requests ray
  (ray must match the version used in stroma-ai-vllm.sif)

See also
--------
  src/cluster_manager.py — ClusterManager abstraction for Slurm + Apptainer
"""

from __future__ import annotations

import json
import logging
import os
import re
import signal
import sys
import time
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

import requests
from cluster_manager import ClusterManager, WorkerState

# ---------------------------------------------------------------------------
# Configuration — all sourced from environment variables, never hardcoded
# ---------------------------------------------------------------------------

HEAD_HOST     = os.environ.get("STROMA_HEAD_HOST", "localhost")
# STROMA_RAY_HOST allows containerised deployments to point the Ray address at
# a different service (e.g. "ray-head" in a Compose stack) while vLLM HTTP
# queries continue to use STROMA_HEAD_HOST.  Defaults to STROMA_HEAD_HOST so
# bare-metal and VM deployments need no changes.
RAY_HOST      = os.environ.get("STROMA_RAY_HOST", HEAD_HOST)
RAY_PORT      = int(os.environ.get("STROMA_RAY_PORT", "6380"))
VLLM_PORT     = int(os.environ.get("STROMA_VLLM_PORT", "8000"))
API_KEY       = os.environ.get("STROMA_API_KEY", "")
MAX_BURST     = int(os.environ.get("STROMA_MAX_BURST_WORKERS", "5"))
UP_THRESHOLD  = int(os.environ.get("STROMA_SCALE_UP_THRESHOLD", "2"))
DOWN_IDLE_S   = int(os.environ.get("STROMA_SCALE_DOWN_IDLE_SECONDS", "300"))
UP_COOLDOWN   = int(os.environ.get("STROMA_SCALE_UP_COOLDOWN", "300"))
POLL_S        = int(os.environ.get("STROMA_WATCHER_POLL_INTERVAL", "30"))
_SCRIPT_ROOT  = str(Path(__file__).resolve().parent.parent)
INSTALL_DIR   = os.environ.get("STROMA_INSTALL_DIR", _SCRIPT_ROOT)
STATE_FILE    = os.environ.get("STROMA_STATE_FILE", f"{INSTALL_DIR}/state/watcher_state.json")
SLURM_SCRIPT  = os.environ.get("STROMA_SLURM_SCRIPT", "/share/slurm/stroma_ai_worker.slurm")

# ClusterManager is constructed once in main() after config validation
# and passed into functions that need Slurm/Apptainer operations.

VLLM_BASE     = f"http://{HEAD_HOST}:{VLLM_PORT}"
RAY_ADDR      = f"{RAY_HOST}:{RAY_PORT}"

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
log = logging.getLogger("stroma-ai-watcher")


# ---------------------------------------------------------------------------
# Startup validation
# ---------------------------------------------------------------------------

def _validate_config() -> None:
    """Fail fast on obvious misconfiguration before touching Slurm or Ray."""
    errors: list[str] = []

    if not API_KEY:
        errors.append("STROMA_API_KEY is not set")
    elif API_KEY.upper().startswith("CHANGEME"):
        errors.append(
            "STROMA_API_KEY is still the placeholder — generate with: openssl rand -hex 32"
        )

    if not re.match(r"^[a-zA-Z0-9._-]+$", HEAD_HOST):
        errors.append(
            f"STROMA_HEAD_HOST={HEAD_HOST!r} contains invalid characters "
            "(only letters, digits, dots, hyphens, underscores allowed)"
        )

    if MAX_BURST <= 0:
        errors.append(f"STROMA_MAX_BURST_WORKERS must be > 0 (got {MAX_BURST})")

    if UP_THRESHOLD <= 0:
        errors.append(f"STROMA_SCALE_UP_THRESHOLD must be > 0 (got {UP_THRESHOLD})")

    if not Path(SLURM_SCRIPT).exists():
        errors.append(f"STROMA_SLURM_SCRIPT not found: {SLURM_SCRIPT}")

    if errors:
        for msg in errors:
            log.error("Config error: %s", msg)
        sys.exit(1)

    log.info("Config validated OK")


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
    os.chmod(STATE_FILE, 0o600)   # restrict to owner; state contains job IDs


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
# Slurm helpers — thin wrappers that delegate to ClusterManager
# ---------------------------------------------------------------------------
# The functions below preserve the watcher's existing call-sites while all
# actual Slurm interactions live in ClusterManager (src/cluster_manager.py).
# ``_mgr`` is set by main() after the ClusterManager is constructed.

_mgr: Optional[ClusterManager] = None


def _get_mgr() -> ClusterManager:
    if _mgr is None:
        raise RuntimeError("ClusterManager not initialised — call main() first")
    return _mgr


def slurm_submit() -> Optional[str]:
    """Submit a burst worker. Returns job ID string or None on failure."""
    result = _get_mgr().submit_worker()
    return result.job_id if result.success else None


def slurm_job_state(job_id: str) -> Optional[str]:
    """Return raw Slurm state string or None if job is gone."""
    state = _get_mgr().get_worker_state(job_id)
    return state.value.upper() if state is not None else None


def slurm_active_ids(job_ids: list[str]) -> set[str]:
    """Return subset of job_ids still present in Slurm."""
    return _get_mgr().get_active_worker_ids(job_ids)


def slurm_cancel(job_id: str) -> None:
    """Cancel a Slurm job. Logs but does not raise on failure."""
    _get_mgr().cancel_worker(job_id)


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
        state.idle_since = None  # activity seen — clear idle timer regardless of submit outcome
        jid = slurm_submit()
        if jid:
            state.jobs[jid] = {
                "state": ST_PENDING,
                "submitted_at": _iso(),
                "ray_node_id": None,
            }
            state.last_scale_up = _iso()
            state.total_submitted += 1
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
    _validate_config()

    # Build ClusterManager from the same env vars the watcher already reads,
    # then assign to the module-level variable so the thin wrappers above work.
    global _mgr  # noqa: PLW0603
    _mgr = ClusterManager.from_env()
    cluster_errors = _mgr.validate()
    if cluster_errors:
        for msg in cluster_errors:
            log.error("ClusterManager validation error: %s", msg)
        sys.exit(1)
    log.info("ClusterManager initialised (container: %s)", _mgr.container_path)

    log.info(
        "StromaAI Watcher starting — HEAD=%s RAY_PORT=%d VLLM_PORT=%d MAX_BURST=%d",
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
        # Touch heartbeat file so the container healthcheck can verify
        # the loop is alive (written even when no state changes occur).
        try:
            Path(STATE_FILE).parent.joinpath("watcher_heartbeat").touch()
        except OSError:
            pass
        time.sleep(POLL_S)

    log.info(
        "Watcher stopped cleanly (lifetime: submitted=%d cancelled=%d)",
        state.total_submitted, state.total_cancelled,
    )


if __name__ == "__main__":
    main()
