#!/usr/bin/env python3
"""
StromaAI — Model Watcher
=========================
Per-model lifecycle manager that provisions on-demand vLLM instances via Slurm,
monitors their health, and drains them after an idle timeout.

The *persistent* model (always-on coder, e.g. Qwen2.5-Coder-32B-Instruct-AWQ)
keeps the existing burst-scaling behaviour from ``vllm_watcher.py``.  All other
models are *on-demand*: they start only when a user selects them in OpenWebUI or
sends a request via the gateway.

Architecture
~~~~~~~~~~~~
::

    Gateway :9000
      ├── POST /v1/chat/completions  {"model":"Llama-3.1-70B-Instruct"}
      │   → model not serving → 503 + signal watcher
      │
      ▼
    Model Watcher :9100 (this module)
      ├── HTTP  POST /request-model/{model_id}  ← gateway signal
      ├── HTTP  GET  /status                     ← diagnostic
      └── Tick loop (every POLL_S seconds):
            - Per-model state machine
            - Health monitoring for serving models
            - Idle detection → drain after timeout
            - Persistent model burst scaling (existing logic)

Per-model state machine
~~~~~~~~~~~~~~~~~~~~~~~
::

  available → requested → provisioning → serving → draining → available
                                            │          ↑
                                            └──────────┘  (idle timeout)

  error: terminal state until operator resets or model rescanned

Configuration
-------------
All parameters come from environment variables.  See ``config/config.example.env``.

Requires
--------
  pip install requests aiohttp
  (+ ray for the persistent model burst-scaling path)
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import signal
import sys
import time
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from pathlib import Path
from typing import Optional

import requests
from aiohttp import web

from cluster_manager import ClusterManager, WorkerState
from model_registry import (
    ModelEntry,
    ModelRegistry,
    ModelStatus,
    ModelTier,
)

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

HEAD_HOST     = os.environ.get("STROMA_HEAD_HOST", "localhost")
RAY_HOST      = os.environ.get("STROMA_RAY_HOST", HEAD_HOST)
RAY_PORT      = int(os.environ.get("STROMA_RAY_PORT", "6380"))
VLLM_PORT     = int(os.environ.get("STROMA_VLLM_PORT", "8000"))
API_KEY       = os.environ.get("STROMA_API_KEY", "")
POLL_S        = int(os.environ.get("STROMA_WATCHER_POLL_INTERVAL", "30"))
IDLE_TIMEOUT  = int(os.environ.get("STROMA_MODEL_IDLE_TIMEOUT", "300"))
HTTP_PORT     = int(os.environ.get("STROMA_WATCHER_PORT", "9100"))
INSTALL_DIR   = os.environ.get("STROMA_INSTALL_DIR", "/opt/stroma-ai")
STATE_FILE    = os.environ.get("STROMA_MODEL_STATE_FILE",
                               f"{INSTALL_DIR}/state/model_watcher_state.json")

# Persistent model burst-scaling (re-used from vllm_watcher)
MAX_BURST     = int(os.environ.get("STROMA_MAX_BURST_WORKERS", "5"))
UP_THRESHOLD  = int(os.environ.get("STROMA_SCALE_UP_THRESHOLD", "2"))
DOWN_IDLE_S   = int(os.environ.get("STROMA_SCALE_DOWN_IDLE_SECONDS", "300"))
UP_COOLDOWN   = int(os.environ.get("STROMA_SCALE_UP_COOLDOWN", "300"))
SLURM_SCRIPT  = os.environ.get("STROMA_SLURM_SCRIPT",
                                "/share/slurm/stroma_ai_worker.slurm")

VLLM_BASE = f"http://{HEAD_HOST}:{VLLM_PORT}"
RAY_ADDR  = f"{RAY_HOST}:{RAY_PORT}"

log = logging.getLogger("stroma-ai-model-watcher")

# ---------------------------------------------------------------------------
# Logging setup
# ---------------------------------------------------------------------------

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)-8s %(name)s — %(message)s",
    handlers=[logging.StreamHandler(sys.stdout)],
)


# ---------------------------------------------------------------------------
# Time helpers
# ---------------------------------------------------------------------------

def _now() -> datetime:
    return datetime.now(timezone.utc)

def _iso() -> str:
    return _now().isoformat()

def _seconds_since(iso: Optional[str]) -> float:
    if iso is None:
        return float("inf")
    try:
        return (_now() - datetime.fromisoformat(iso)).total_seconds()
    except ValueError:
        return float("inf")


# ---------------------------------------------------------------------------
# Per-model state
# ---------------------------------------------------------------------------

@dataclass
class ModelState:
    """Mutable runtime state for a single model in the watcher."""
    model_id: str
    status: str = "available"          # ModelStatus value
    slurm_job_ids: list[str] = field(default_factory=list)
    vllm_port: Optional[int] = None
    last_request_at: Optional[str] = None   # ISO-8601
    idle_since: Optional[str] = None        # ISO-8601
    error_message: str = ""
    gpu_count: int = 1
    # Persistent model burst-scaling fields
    burst_jobs: dict[str, dict] = field(default_factory=dict)
    last_scale_up: Optional[str] = None
    burst_idle_since: Optional[str] = None


@dataclass
class WatcherState:
    """All mutable watcher state — persisted atomically after each change."""
    models: dict[str, dict] = field(default_factory=dict)
    # model_id → serialised ModelState fields

    total_provisioned: int = 0
    total_drained: int = 0


def _model_state_from_dict(model_id: str, data: dict) -> ModelState:
    return ModelState(
        model_id=model_id,
        status=data.get("status", "available"),
        slurm_job_ids=data.get("slurm_job_ids", []),
        vllm_port=data.get("vllm_port"),
        last_request_at=data.get("last_request_at"),
        idle_since=data.get("idle_since"),
        error_message=data.get("error_message", ""),
        gpu_count=data.get("gpu_count", 1),
        burst_jobs=data.get("burst_jobs", {}),
        last_scale_up=data.get("last_scale_up"),
        burst_idle_since=data.get("burst_idle_since"),
    )


# ---------------------------------------------------------------------------
# Persistence
# ---------------------------------------------------------------------------

def load_state() -> WatcherState:
    try:
        data = json.loads(Path(STATE_FILE).read_text())
        return WatcherState(
            models=data.get("models", {}),
            total_provisioned=data.get("total_provisioned", 0),
            total_drained=data.get("total_drained", 0),
        )
    except FileNotFoundError:
        log.info("No state file at %s — starting fresh", STATE_FILE)
        return WatcherState()
    except (json.JSONDecodeError, KeyError) as exc:
        log.warning("State file unreadable (%s) — starting fresh", exc)
        return WatcherState()


def persist(state: WatcherState) -> None:
    Path(STATE_FILE).parent.mkdir(parents=True, exist_ok=True)
    tmp = STATE_FILE + ".tmp"
    Path(tmp).write_text(json.dumps(asdict(state), indent=2, default=str))
    os.replace(tmp, STATE_FILE)
    os.chmod(STATE_FILE, 0o600)


# ---------------------------------------------------------------------------
# vLLM helpers
# ---------------------------------------------------------------------------

def _auth_headers() -> dict:
    return {"Authorization": f"Bearer {API_KEY}"} if API_KEY else {}


def vllm_healthy(port: int = VLLM_PORT, host: str = HEAD_HOST) -> bool:
    """Return True if the vLLM /health endpoint responds 200."""
    try:
        r = requests.get(
            f"http://{host}:{port}/health",
            headers=_auth_headers(),
            timeout=5,
        )
        return r.status_code == 200
    except requests.RequestException:
        return False


def fetch_metrics(port: int = VLLM_PORT, host: str = HEAD_HOST) -> dict[str, float]:
    """Parse vLLM Prometheus metrics. Used for idle detection."""
    import re
    try:
        r = requests.get(
            f"http://{host}:{port}/metrics",
            headers=_auth_headers(),
            timeout=10,
        )
        r.raise_for_status()
    except requests.RequestException:
        return {}

    out: dict[str, float] = {}
    for line in r.text.splitlines():
        if line.startswith("#") or not line.strip():
            continue
        m = re.match(r'^(vllm:\w+)(?:\{[^}]*\})?\s+([\d.]+(?:[eE][+-]?\d+)?)', line)
        if m:
            try:
                out[m.group(1)] = float(m.group(2))
            except ValueError:
                pass
    return out


# ---------------------------------------------------------------------------
# Ray helpers (for persistent model burst scaling)
# ---------------------------------------------------------------------------

def ray_gpu_node_ids() -> set[str]:
    try:
        import ray  # type: ignore
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
    except Exception:
        return set()


# ---------------------------------------------------------------------------
# Slurm helpers
# ---------------------------------------------------------------------------

def slurm_submit(mgr: ClusterManager) -> Optional[str]:
    result = mgr.submit_worker()
    return result.job_id if result.success else None


def slurm_submit_model(
    mgr: ClusterManager,
    entry: ModelEntry,
    port: int,
) -> Optional[str]:
    """Submit a Slurm job for a specific model. Returns job ID or None."""
    result = mgr.submit_model_worker(
        model_id=entry.model_id,
        model_path=entry.path,
        vllm_port=port,
        gpu_count=entry.gpu_count,
        quantization=entry.quantization if entry.quantization != "none" else "",
        max_model_len=entry.max_model_len,
    )
    return result.job_id if result.success else None


# ---------------------------------------------------------------------------
# Core logic — per-model tick
# ---------------------------------------------------------------------------

class ModelWatcher:
    """
    Orchestrates the lifecycle of all registered models.

    The ``tick()`` method is called on a fixed interval. It:
      1. Syncs model list from the registry
      2. Handles on-demand model state transitions
      3. Runs persistent model burst-scaling
      4. Persists state changes
    """

    def __init__(
        self,
        registry: ModelRegistry,
        mgr: ClusterManager,
        state: WatcherState,
    ) -> None:
        self.registry = registry
        self.mgr = mgr
        self.state = state
        self.known_ray_nodes: set[str] = set()
        self._stop = False

    # ----- Gateway signal: request an on-demand model -----

    def request_model(self, model_id: str) -> tuple[bool, str]:
        """
        Called when the gateway needs an on-demand model.
        Returns (accepted, message).
        """
        entry = self.registry.get_model(model_id)
        if entry is None:
            return False, f"Unknown model: {model_id}"

        if entry.tier == ModelTier.PERSISTENT:
            return True, "Persistent model — always serving"

        ms = self._get_model_state(entry)

        if ms.status == "serving":
            return True, "Already serving"

        if ms.status in ("requested", "provisioning"):
            return True, "Already starting"

        # Transition: available → requested
        ms.status = "requested"
        ms.last_request_at = _iso()
        self._save_model_state(ms)
        self.registry.update_status(model_id, ModelStatus.REQUESTED)
        log.info("Model %s requested — will provision on next tick", model_id)
        return True, "Accepted — provisioning will begin shortly"

    # ----- State accessors -----

    def _get_model_state(self, entry: ModelEntry) -> ModelState:
        """Get or create the mutable state for a model."""
        if entry.model_id in self.state.models:
            return _model_state_from_dict(entry.model_id, self.state.models[entry.model_id])
        ms = ModelState(
            model_id=entry.model_id,
            gpu_count=entry.gpu_count,
        )
        return ms

    def _save_model_state(self, ms: ModelState) -> None:
        """Write model state back into the watcher state dict."""
        self.state.models[ms.model_id] = asdict(ms)

    # ----- Main tick -----

    def tick(self) -> None:
        """One watcher cycle — handle all models."""
        changed = False

        # Rescan models periodically (picks up new models dropped into MODELS_DIR)
        self.registry.scan()

        for entry in self.registry.list_models():
            if entry.tier == ModelTier.PERSISTENT:
                changed |= self._tick_persistent(entry)
            else:
                changed |= self._tick_on_demand(entry)

        if changed:
            persist(self.state)

        # Heartbeat file
        try:
            Path(STATE_FILE).parent.joinpath("model_watcher_heartbeat").touch()
        except OSError:
            pass

    # ----- On-demand model lifecycle -----

    def _tick_on_demand(self, entry: ModelEntry) -> bool:
        """
        State machine tick for an on-demand model::

            available → requested → provisioning → serving → draining → available
        """
        ms = self._get_model_state(entry)
        changed = False

        if ms.status == "requested":
            changed = self._provision_model(entry, ms)

        elif ms.status == "provisioning":
            changed = self._check_provisioning(entry, ms)

        elif ms.status == "serving":
            changed = self._check_serving(entry, ms)

        elif ms.status == "draining":
            changed = self._drain_model(entry, ms)

        if changed:
            self._save_model_state(ms)

        return changed

    def _provision_model(self, entry: ModelEntry, ms: ModelState) -> bool:
        """Submit Slurm job for an on-demand model."""
        port = self.registry.allocate_port(entry.model_id)
        if port is None:
            ms.status = "error"
            ms.error_message = "No free ports in range"
            self.registry.update_status(entry.model_id, ModelStatus.ERROR,
                                        error_message=ms.error_message)
            log.error("No free ports for model %s", entry.model_id)
            return True

        ms.vllm_port = port
        job_id = slurm_submit_model(self.mgr, entry, port)
        if job_id is None:
            self.registry.release_port(entry.model_id)
            ms.status = "error"
            ms.error_message = "Slurm submission failed"
            self.registry.update_status(entry.model_id, ModelStatus.ERROR,
                                        error_message=ms.error_message)
            log.error("Failed to submit Slurm job for model %s", entry.model_id)
            return True

        ms.slurm_job_ids = [job_id]
        ms.status = "provisioning"
        self.registry.update_status(entry.model_id, ModelStatus.PROVISIONING,
                                    vllm_port=port)
        self.state.total_provisioned += 1
        log.info("Model %s provisioning: job=%s port=%d", entry.model_id, job_id, port)
        return True

    def _check_provisioning(self, entry: ModelEntry, ms: ModelState) -> bool:
        """Check if a provisioning model's vLLM is healthy yet."""
        # Check if Slurm job is still alive
        for jid in list(ms.slurm_job_ids):
            ws = self.mgr.get_worker_state(jid)
            if ws is None or ws in (WorkerState.FAILED, WorkerState.CANCELLED, WorkerState.COMPLETED):
                ms.status = "error"
                ms.error_message = f"Slurm job {jid} ended prematurely ({ws})"
                self.registry.update_status(entry.model_id, ModelStatus.ERROR,
                                            error_message=ms.error_message)
                self.registry.release_port(entry.model_id)
                log.error("Model %s: Slurm job %s ended: %s", entry.model_id, jid, ws)
                return True

        # Check if vLLM is ready
        if ms.vllm_port and vllm_healthy(port=ms.vllm_port):
            ms.status = "serving"
            ms.idle_since = None
            self.registry.update_status(entry.model_id, ModelStatus.SERVING,
                                        vllm_port=ms.vllm_port)
            log.info("Model %s is now SERVING on port %d", entry.model_id, ms.vllm_port)
            return True

        return False

    def _check_serving(self, entry: ModelEntry, ms: ModelState) -> bool:
        """Monitor a serving model for health and idle timeout."""
        if ms.vllm_port is None:
            return False

        # Health check
        if not vllm_healthy(port=ms.vllm_port):
            # If Slurm job is gone, the model crashed
            any_alive = False
            for jid in ms.slurm_job_ids:
                ws = self.mgr.get_worker_state(jid)
                if ws is not None and ws not in (WorkerState.FAILED, WorkerState.CANCELLED, WorkerState.COMPLETED):
                    any_alive = True
            if not any_alive:
                ms.status = "error"
                ms.error_message = "Slurm job ended while serving"
                self.registry.update_status(entry.model_id, ModelStatus.ERROR,
                                            error_message=ms.error_message)
                self.registry.release_port(entry.model_id)
                log.error("Model %s lost all Slurm jobs while serving", entry.model_id)
                return True
            # vLLM might be temporarily unresponsive — don't drain yet
            return False

        # Idle detection via metrics
        metrics = fetch_metrics(port=ms.vllm_port)
        waiting = int(metrics.get("vllm:num_requests_waiting", 0))
        running = int(metrics.get("vllm:num_requests_running", 0))

        if waiting == 0 and running == 0:
            if ms.idle_since is None:
                ms.idle_since = _iso()
                log.info("Model %s idle — timer started (%ds timeout)",
                         entry.model_id, IDLE_TIMEOUT)
                return True
            elif _seconds_since(ms.idle_since) >= IDLE_TIMEOUT:
                # Start draining
                ms.status = "draining"
                self.registry.update_status(entry.model_id, ModelStatus.DRAINING)
                log.info("Model %s idle timeout reached — draining", entry.model_id)
                return True
        else:
            if ms.idle_since is not None:
                ms.idle_since = None
                return True

        return False

    def _drain_model(self, entry: ModelEntry, ms: ModelState) -> bool:
        """Cancel Slurm jobs and return model to available."""
        for jid in ms.slurm_job_ids:
            self.mgr.cancel_worker(jid)
        ms.slurm_job_ids = []
        ms.status = "available"
        ms.idle_since = None
        ms.error_message = ""
        self.registry.release_port(entry.model_id)
        self.registry.update_status(entry.model_id, ModelStatus.AVAILABLE)
        self.state.total_drained += 1
        log.info("Model %s drained — returned to available", entry.model_id)
        return True

    # ----- Persistent model burst scaling -----
    # (simplified version of vllm_watcher.py logic)

    def _tick_persistent(self, entry: ModelEntry) -> bool:
        """Burst-scale the persistent model based on queue depth."""
        ms = self._get_model_state(entry)
        changed = False

        if not vllm_healthy():
            return False

        metrics = fetch_metrics()
        waiting = int(metrics.get("vllm:num_requests_waiting", 0))
        running = int(metrics.get("vllm:num_requests_running", 0))

        # Reconcile burst jobs against Slurm
        burst = ms.burst_jobs
        if burst:
            active = self.mgr.get_active_worker_ids(list(burst.keys()))
            dead = set(burst) - active
            for jid in dead:
                log.info("Persistent burst job %s gone — removing", jid)
                del burst[jid]
                changed = True

        n_burst = len(burst)

        # Scale-up: queue is deep
        if (
            waiting >= UP_THRESHOLD
            and n_burst < MAX_BURST
            and _seconds_since(ms.last_scale_up) >= UP_COOLDOWN
        ):
            ms.burst_idle_since = None
            jid = slurm_submit(self.mgr)
            if jid:
                burst[jid] = {"state": "pending", "submitted_at": _iso()}
                ms.last_scale_up = _iso()
                changed = True
                log.info("Persistent scale-up: job %s (%d/%d)", jid, n_burst + 1, MAX_BURST)

        # Scale-down: queue empty, burst workers idle
        elif waiting == 0 and running == 0 and n_burst > 0:
            if ms.burst_idle_since is None:
                ms.burst_idle_since = _iso()
                changed = True
            elif _seconds_since(ms.burst_idle_since) >= DOWN_IDLE_S:
                for jid in list(burst.keys()):
                    self.mgr.cancel_worker(jid)
                    del burst[jid]
                ms.burst_idle_since = None
                changed = True
                log.info("Persistent scale-down: cancelled %d burst jobs", n_burst)

        elif (waiting > 0 or running > 0) and ms.burst_idle_since is not None:
            ms.burst_idle_since = None
            changed = True

        ms.burst_jobs = burst
        if changed:
            self._save_model_state(ms)
        return changed

    # ----- Run loop -----

    def stop(self) -> None:
        self._stop = True

    def run_sync(self) -> None:
        """Blocking run loop — call ``stop()`` to exit."""
        while not self._stop:
            try:
                self.tick()
            except Exception:
                log.exception("Unhandled error in tick — continuing")
            time.sleep(POLL_S)


# ---------------------------------------------------------------------------
# HTTP API (aiohttp) — gateway signals land here
# ---------------------------------------------------------------------------

def create_http_app(watcher: ModelWatcher) -> web.Application:
    """Build the aiohttp app with the watcher's request handlers."""

    async def handle_request_model(request: web.Request) -> web.Response:
        model_id = request.match_info["model_id"]
        accepted, message = watcher.request_model(model_id)
        status_code = 200 if accepted else 404
        return web.json_response({"accepted": accepted, "message": message},
                                 status=status_code)

    async def handle_status(request: web.Request) -> web.Response:
        models_status = {}
        for entry in watcher.registry.list_models():
            ms = watcher._get_model_state(entry)
            models_status[entry.model_id] = {
                "status": ms.status,
                "tier": entry.tier.value,
                "vllm_port": ms.vllm_port,
                "slurm_jobs": ms.slurm_job_ids,
                "idle_since": ms.idle_since,
            }
        return web.json_response({
            "models": models_status,
            "total_provisioned": watcher.state.total_provisioned,
            "total_drained": watcher.state.total_drained,
        })

    app = web.Application()
    app.router.add_post("/request-model/{model_id}", handle_request_model)
    app.router.add_get("/status", handle_status)
    return app


# ---------------------------------------------------------------------------
# Entry point
# ---------------------------------------------------------------------------

def main() -> None:
    """Start the model watcher with HTTP API and tick loop."""
    log.info("StromaAI Model Watcher starting")

    # Validate
    if not API_KEY:
        log.error("STROMA_API_KEY is not set")
        sys.exit(1)

    # Build components
    registry = ModelRegistry()
    count = registry.scan()
    log.info("Model registry: %d model(s) found", count)

    mgr = ClusterManager.from_env()
    cluster_errors = mgr.validate()
    if cluster_errors:
        for msg in cluster_errors:
            log.error("ClusterManager error: %s", msg)
        sys.exit(1)

    state = load_state()
    watcher = ModelWatcher(registry, mgr, state)

    # Mark persistent model as serving
    persistent = registry.get_persistent_model()
    if persistent:
        registry.update_status(
            persistent.model_id, ModelStatus.SERVING,
            vllm_port=VLLM_PORT,
        )
        log.info("Persistent model: %s (port %d)", persistent.model_id, VLLM_PORT)

    # Restore on-demand model states from persisted state
    for model_id, mdata in state.models.items():
        entry = registry.get_model(model_id)
        if entry and entry.tier == ModelTier.ON_DEMAND:
            saved_status = mdata.get("status", "available")
            if saved_status == "serving" and mdata.get("vllm_port"):
                # Verify it's still healthy
                if vllm_healthy(port=mdata["vllm_port"]):
                    registry.update_status(model_id, ModelStatus.SERVING,
                                           vllm_port=mdata["vllm_port"])
                    log.info("Restored serving model: %s (port %d)",
                             model_id, mdata["vllm_port"])
                else:
                    log.warning("Model %s was serving but vLLM is down — resetting",
                                model_id)
                    mdata["status"] = "available"
            elif saved_status in ("requested", "provisioning"):
                log.info("Model %s was %s — resetting to available", model_id, saved_status)
                mdata["status"] = "available"

    # Signal handling
    def _on_signal(sig: int, _frame: object) -> None:
        log.info("Signal %d received — stopping", sig)
        watcher.stop()

    signal.signal(signal.SIGTERM, _on_signal)
    signal.signal(signal.SIGINT, _on_signal)

    # Run HTTP API in a background thread, tick loop in the main thread
    import threading

    http_app = create_http_app(watcher)

    def _run_http() -> None:
        loop = asyncio.new_event_loop()
        asyncio.set_event_loop(loop)
        runner = web.AppRunner(http_app)
        loop.run_until_complete(runner.setup())
        site = web.TCPSite(runner, "127.0.0.1", HTTP_PORT)
        loop.run_until_complete(site.start())
        log.info("Model watcher HTTP API listening on 127.0.0.1:%d", HTTP_PORT)
        loop.run_forever()

    http_thread = threading.Thread(target=_run_http, daemon=True)
    http_thread.start()

    # Main tick loop (blocking)
    log.info(
        "Model Watcher running — poll=%ds idle_timeout=%ds burst_max=%d",
        POLL_S, IDLE_TIMEOUT, MAX_BURST,
    )
    watcher.run_sync()

    persist(watcher.state)
    log.info(
        "Model Watcher stopped (provisioned=%d drained=%d)",
        watcher.state.total_provisioned,
        watcher.state.total_drained,
    )


if __name__ == "__main__":
    main()
