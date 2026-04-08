"""
Unit tests for ModelWatcher (src/model_watcher.py).

Mocks Slurm, vLLM health checks, and the model registry to test the per-model
state machine transitions without any cluster infrastructure.
"""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path
from unittest.mock import MagicMock, patch

import pytest

# Add src/ to path so we can import model_watcher without installing it
sys.path.insert(0, str(Path(__file__).parent.parent.parent / "src"))

from model_registry import ModelEntry, ModelRegistry, ModelStatus, ModelTier
from model_watcher import (
    ModelState,
    ModelWatcher,
    WatcherState,
    _model_state_from_dict,
    load_state,
    persist,
)


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

def _make_entry(
    model_id: str = "test-model",
    tier: ModelTier = ModelTier.ON_DEMAND,
    gpu_count: int = 1,
    vram_required_mb: int = 10000,
    quantization: str = "awq",
    max_model_len: int = 4096,
) -> ModelEntry:
    return ModelEntry(
        model_id=model_id,
        path=f"/share/models/{model_id}",
        display_name=model_id,
        architecture="TestArch",
        param_count=7_000_000_000,
        dtype="fp16",
        quantization=quantization,
        vram_required_mb=vram_required_mb,
        gpu_count=gpu_count,
        max_model_len=max_model_len,
        tier=tier,
        status=ModelStatus.AVAILABLE,
    )


@pytest.fixture()
def registry():
    """A mock ModelRegistry with one on-demand and one persistent model."""
    reg = MagicMock(spec=ModelRegistry)
    persistent = _make_entry("coder-model", tier=ModelTier.PERSISTENT)
    on_demand = _make_entry("big-model", tier=ModelTier.ON_DEMAND)
    reg.list_models.return_value = [persistent, on_demand]
    reg.get_model.side_effect = lambda mid: {
        "coder-model": persistent,
        "big-model": on_demand,
    }.get(mid)
    reg.get_persistent_model.return_value = persistent
    reg.allocate_port.return_value = 8001
    reg.scan.return_value = 2
    return reg


@pytest.fixture()
def mgr():
    """A mock ClusterManager."""
    from cluster_manager import SubmitResult, WorkerState
    m = MagicMock()
    m.submit_model_worker.return_value = SubmitResult(success=True, job_id="12345")
    m.submit_worker.return_value = SubmitResult(success=True, job_id="99999")
    m.get_worker_state.return_value = WorkerState.RUNNING
    m.get_active_worker_ids.return_value = set()
    m.validate.return_value = []
    return m


@pytest.fixture()
def watcher(registry, mgr, tmp_path):
    import model_watcher as mw
    # Redirect state persistence to a temp dir so tests don't write to /opt/stroma-ai/
    mw.STATE_FILE = str(tmp_path / "model_watcher_state.json")
    state = WatcherState()
    return ModelWatcher(registry, mgr, state)


# ---------------------------------------------------------------------------
# Request model signal
# ---------------------------------------------------------------------------

class TestRequestModel:

    def test_request_unknown_model(self, watcher):
        watcher.registry.get_model.return_value = None
        accepted, msg = watcher.request_model("nonexistent")
        assert accepted is False

    def test_request_persistent_model(self, watcher):
        accepted, msg = watcher.request_model("coder-model")
        assert accepted is True
        assert "persistent" in msg.lower() or "always" in msg.lower()

    def test_request_on_demand_model_transitions(self, watcher):
        accepted, msg = watcher.request_model("big-model")
        assert accepted is True
        # Registry should be informed
        watcher.registry.update_status.assert_called_with(
            "big-model", ModelStatus.REQUESTED
        )

    def test_request_already_serving(self, watcher):
        # Pre-set model state to serving
        watcher.state.models["big-model"] = {
            "model_id": "big-model",
            "status": "serving",
            "slurm_job_ids": ["123"],
            "vllm_port": 8001,
            "last_request_at": None,
            "idle_since": None,
            "error_message": "",
            "gpu_count": 1,
            "burst_jobs": {},
            "last_scale_up": None,
            "burst_idle_since": None,
        }
        accepted, msg = watcher.request_model("big-model")
        assert accepted is True
        assert "serving" in msg.lower()

    def test_request_already_provisioning(self, watcher):
        watcher.state.models["big-model"] = {
            "model_id": "big-model",
            "status": "provisioning",
            "slurm_job_ids": ["123"],
            "vllm_port": 8001,
            "last_request_at": None,
            "idle_since": None,
            "error_message": "",
            "gpu_count": 1,
            "burst_jobs": {},
            "last_scale_up": None,
            "burst_idle_since": None,
        }
        accepted, msg = watcher.request_model("big-model")
        assert accepted is True
        assert "starting" in msg.lower()


# ---------------------------------------------------------------------------
# On-demand model lifecycle
# ---------------------------------------------------------------------------

class TestOnDemandLifecycle:

    def test_provision_submits_slurm_job(self, watcher, registry, mgr):
        """requested → provisioning should submit a Slurm job."""
        watcher.request_model("big-model")
        # Tick to process the request
        watcher.tick()
        mgr.submit_model_worker.assert_called_once()

    def test_provision_failure_sets_error(self, watcher, registry, mgr):
        from cluster_manager import SubmitResult
        mgr.submit_model_worker.return_value = SubmitResult(success=False, error="no GPUs")
        watcher.request_model("big-model")
        watcher.tick()
        registry.update_status.assert_any_call(
            "big-model", ModelStatus.ERROR, error_message="Slurm submission failed"
        )

    def test_port_exhaustion_sets_error(self, watcher, registry, mgr):
        registry.allocate_port.return_value = None
        watcher.request_model("big-model")
        watcher.tick()
        registry.update_status.assert_any_call(
            "big-model", ModelStatus.ERROR, error_message="No free ports in range"
        )

    @patch("model_watcher.vllm_healthy", return_value=True)
    def test_provisioning_to_serving(self, mock_health, watcher, registry, mgr):
        """provisioning → serving when vLLM health check passes."""
        # Set up as provisioning
        watcher.state.models["big-model"] = {
            "model_id": "big-model",
            "status": "provisioning",
            "slurm_job_ids": ["12345"],
            "vllm_port": 8001,
            "last_request_at": None,
            "idle_since": None,
            "error_message": "",
            "gpu_count": 1,
            "burst_jobs": {},
            "last_scale_up": None,
            "burst_idle_since": None,
        }
        watcher.tick()
        registry.update_status.assert_any_call(
            "big-model", ModelStatus.SERVING, vllm_port=8001
        )

    @patch("model_watcher.vllm_healthy", return_value=True)
    @patch("model_watcher.fetch_metrics", return_value={
        "vllm:num_requests_waiting": 0,
        "vllm:num_requests_running": 0,
    })
    def test_serving_starts_idle_timer(self, mock_metrics, mock_health, watcher, registry, mgr):
        """serving + no activity → idle timer starts."""
        watcher.state.models["big-model"] = {
            "model_id": "big-model",
            "status": "serving",
            "slurm_job_ids": ["12345"],
            "vllm_port": 8001,
            "last_request_at": None,
            "idle_since": None,
            "error_message": "",
            "gpu_count": 1,
            "burst_jobs": {},
            "last_scale_up": None,
            "burst_idle_since": None,
        }
        watcher.tick()
        ms_data = watcher.state.models.get("big-model", {})
        assert ms_data.get("idle_since") is not None


# ---------------------------------------------------------------------------
# State persistence
# ---------------------------------------------------------------------------

class TestPersistence:

    def test_load_missing_file(self, tmp_path, monkeypatch):
        monkeypatch.setenv("STROMA_MODEL_STATE_FILE", str(tmp_path / "nonexistent.json"))
        import model_watcher as mw
        old = mw.STATE_FILE
        mw.STATE_FILE = str(tmp_path / "nonexistent.json")
        try:
            state = load_state()
            assert state.models == {}
        finally:
            mw.STATE_FILE = old

    def test_persist_and_load(self, tmp_path):
        import model_watcher as mw
        path = str(tmp_path / "state.json")
        old = mw.STATE_FILE
        mw.STATE_FILE = path
        try:
            state = WatcherState()
            state.models["test"] = {"status": "serving"}
            state.total_provisioned = 5
            persist(state)
            loaded = load_state()
            assert loaded.models["test"]["status"] == "serving"
            assert loaded.total_provisioned == 5
        finally:
            mw.STATE_FILE = old


# ---------------------------------------------------------------------------
# ModelState helper
# ---------------------------------------------------------------------------

class TestModelStateHelper:

    def test_from_dict_defaults(self):
        ms = _model_state_from_dict("test", {})
        assert ms.model_id == "test"
        assert ms.status == "available"
        assert ms.slurm_job_ids == []

    def test_from_dict_full(self):
        data = {
            "status": "serving",
            "slurm_job_ids": ["123"],
            "vllm_port": 8005,
            "gpu_count": 4,
        }
        ms = _model_state_from_dict("test", data)
        assert ms.status == "serving"
        assert ms.vllm_port == 8005
        assert ms.gpu_count == 4
