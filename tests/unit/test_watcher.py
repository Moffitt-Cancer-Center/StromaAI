"""
Unit tests for src/vllm_watcher.py

Tests are fully isolated: no real Slurm, Ray, or network connections.
All external calls (subprocess, requests) are mocked.

Run:
    pip install -r tests/requirements.txt
    pytest tests/unit/test_watcher.py -v
"""

from __future__ import annotations

import importlib
import json
import os
import sys
import time
from datetime import datetime, timezone
from pathlib import Path
from typing import Any
from unittest.mock import MagicMock, call, patch

import pytest

# ---------------------------------------------------------------------------
# Add src/ to path so we can import vllm_watcher without installing it
# ---------------------------------------------------------------------------
sys.path.insert(0, str(Path(__file__).parent.parent.parent / "src"))


def _load_watcher(env_overrides: dict[str, str] | None = None):
    """Import vllm_watcher with optional environment variable overrides."""
    env = {
        "STROMA_HEAD_HOST": "test-head",
        "STROMA_RAY_PORT": "6380",
        "STROMA_VLLM_PORT": "8000",
        "STROMA_API_KEY": "test-secret-key",
        "STROMA_MAX_BURST_WORKERS": "3",
        "STROMA_SCALE_UP_THRESHOLD": "2",
        "STROMA_SCALE_DOWN_IDLE_SECONDS": "300",
        "STROMA_SCALE_UP_COOLDOWN": "120",
        "STROMA_WATCHER_POLL_INTERVAL": "30",
        "STROMA_SLURM_PARTITION": "gpu-test",
        "STROMA_SLURM_ACCOUNT": "test-acct",
        "STROMA_SLURM_SCRIPT": "/share/slurm/ai_flux_worker.slurm",
        "STROMA_SLURM_WALLTIME": "1-00:00:00",
        "STROMA_STATE_FILE": "/tmp/ai_flux_test_state.json",
    }
    if env_overrides:
        env.update(env_overrides)

    # Patch environment before (re)importing the module
    with patch.dict(os.environ, env, clear=False):
        if "vllm_watcher" in sys.modules:
            del sys.modules["vllm_watcher"]
        import vllm_watcher  # noqa: PLC0415
        importlib.reload(vllm_watcher)
    return vllm_watcher


@pytest.fixture
def watcher():
    """Return a freshly imported watcher module with test environment."""
    return _load_watcher()


@pytest.fixture
def tmp_state_file(tmp_path):
    """Return a temp path for state persistence tests."""
    return str(tmp_path / "watcher_state.json")


# =============================================================================
# State persistence
# =============================================================================

class TestStatePersistence:
    def test_load_state_returns_fresh_when_missing(self, watcher, tmp_state_file):
        """load_state() returns a clean WatcherState when the file doesn't exist."""
        with patch.object(watcher, "STATE_FILE", tmp_state_file):
            state = watcher.load_state()
        assert state.jobs == {}
        assert state.last_scale_up is None
        assert state.total_submitted == 0
        assert state.total_cancelled == 0

    def test_persist_and_reload(self, watcher, tmp_state_file):
        """State written by persist() can be read back identically by load_state()."""
        with patch.object(watcher, "STATE_FILE", tmp_state_file):
            state = watcher.WatcherState(
                jobs={"42": {"state": "pending", "submitted_at": "2026-03-28T00:00:00+00:00"}},
                total_submitted=1,
            )
            watcher.persist(state)
            reloaded = watcher.load_state()

        assert reloaded.jobs == state.jobs
        assert reloaded.total_submitted == 1

    def test_persist_is_atomic(self, watcher, tmp_state_file):
        """persist() writes to a .tmp file first, then renames — no partial writes."""
        with patch.object(watcher, "STATE_FILE", tmp_state_file):
            watcher.persist(watcher.WatcherState())
            # The .tmp file should not exist after a clean persist
            assert not Path(tmp_state_file + ".tmp").exists()
            assert Path(tmp_state_file).exists()

    def test_load_state_handles_corrupt_json(self, watcher, tmp_state_file):
        """load_state() returns a fresh state if the file contains invalid JSON."""
        Path(tmp_state_file).write_text("{{not valid json}}")
        with patch.object(watcher, "STATE_FILE", tmp_state_file):
            state = watcher.load_state()
        assert state.jobs == {}

    def test_load_state_handles_partial_fields(self, watcher, tmp_state_file):
        """load_state() handles JSON with missing optional fields (backward compat)."""
        Path(tmp_state_file).write_text(json.dumps({"jobs": {}, "total_submitted": 7}))
        with patch.object(watcher, "STATE_FILE", tmp_state_file):
            state = watcher.load_state()
        assert state.total_submitted == 7
        assert state.total_cancelled == 0


# =============================================================================
# vLLM health and metrics parsing
# =============================================================================

class TestVllmHealth:
    def test_vllm_healthy_returns_true_on_200(self, watcher, requests_mock):
        requests_mock.get("http://test-head:8000/health", status_code=200)
        assert watcher.vllm_healthy() is True

    def test_vllm_healthy_returns_false_on_non_200(self, watcher, requests_mock):
        requests_mock.get("http://test-head:8000/health", status_code=503)
        assert watcher.vllm_healthy() is False

    def test_vllm_healthy_returns_false_on_connection_error(self, watcher, requests_mock):
        import requests as req_lib
        requests_mock.get("http://test-head:8000/health", exc=req_lib.ConnectionError)
        assert watcher.vllm_healthy() is False


class TestFetchMetrics:
    SAMPLE_METRICS = """\
# HELP vllm:num_requests_waiting Number of requests waiting
# TYPE vllm:num_requests_waiting gauge
vllm:num_requests_waiting 5.0
# HELP vllm:num_requests_running Number of requests running
# TYPE vllm:num_requests_running gauge
vllm:num_requests_running{model_name="ai-flux-coder"} 2.0
# HELP vllm:cpu_kv_cache_usage_perc CPU KV cache usage
vllm:cpu_kv_cache_usage_perc 0.34
vllm:gpu_cache_usage_perc 0.72
"""

    def test_parses_plain_metric(self, watcher, requests_mock):
        requests_mock.get("http://test-head:8000/metrics", text=self.SAMPLE_METRICS)
        m = watcher.fetch_metrics()
        assert m["vllm:num_requests_waiting"] == 5.0

    def test_parses_labeled_metric(self, watcher, requests_mock):
        requests_mock.get("http://test-head:8000/metrics", text=self.SAMPLE_METRICS)
        m = watcher.fetch_metrics()
        assert m["vllm:num_requests_running"] == 2.0

    def test_parses_float_metrics(self, watcher, requests_mock):
        requests_mock.get("http://test-head:8000/metrics", text=self.SAMPLE_METRICS)
        m = watcher.fetch_metrics()
        assert m["vllm:cpu_kv_cache_usage_perc"] == pytest.approx(0.34)
        assert m["vllm:gpu_cache_usage_perc"] == pytest.approx(0.72)

    def test_returns_empty_on_request_failure(self, watcher, requests_mock):
        import requests as req_lib
        requests_mock.get("http://test-head:8000/metrics", exc=req_lib.ConnectionError)
        assert watcher.fetch_metrics() == {}

    def test_ignores_comment_lines(self, watcher, requests_mock):
        requests_mock.get("http://test-head:8000/metrics", text=self.SAMPLE_METRICS)
        m = watcher.fetch_metrics()
        # Comment lines start with #, should not appear as keys
        assert not any(k.startswith("#") for k in m)

    def test_auth_header_sent(self, watcher, requests_mock):
        adapter = requests_mock.get("http://test-head:8000/metrics", text="")
        watcher.fetch_metrics()
        assert adapter.last_request.headers.get("Authorization") == "Bearer test-secret-key"


# =============================================================================
# Time helpers
# =============================================================================

class TestTimeHelpers:
    def test_seconds_since_returns_inf_for_none(self, watcher):
        assert watcher._seconds_since(None) == float("inf")

    def test_seconds_since_returns_inf_for_invalid(self, watcher):
        assert watcher._seconds_since("not-a-timestamp") == float("inf")

    def test_seconds_since_recent(self, watcher):
        recent = datetime.now(timezone.utc).isoformat()
        elapsed = watcher._seconds_since(recent)
        assert 0 <= elapsed < 2  # should be nearly zero

    def test_seconds_since_past(self, watcher):
        past = "2000-01-01T00:00:00+00:00"
        elapsed = watcher._seconds_since(past)
        assert elapsed > 1_000_000  # many years ago


# =============================================================================
# Slurm integration helpers
# =============================================================================

class TestSlurmSubmit:
    def test_returns_job_id_on_success(self, watcher):
        mock_result = MagicMock(returncode=0, stdout="Submitted batch job 12345\n", stderr="")
        with patch("subprocess.run", return_value=mock_result):
            jid = watcher.slurm_submit()
        assert jid == "12345"

    def test_returns_none_on_nonzero_returncode(self, watcher):
        mock_result = MagicMock(returncode=1, stdout="", stderr="Partition not found")
        with patch("subprocess.run", return_value=mock_result):
            jid = watcher.slurm_submit()
        assert jid is None

    def test_returns_none_when_sbatch_missing(self, watcher):
        with patch("subprocess.run", side_effect=FileNotFoundError("sbatch not found")):
            jid = watcher.slurm_submit()
        assert jid is None

    def test_returns_none_on_unexpected_output(self, watcher):
        mock_result = MagicMock(returncode=0, stdout="Unexpected output\n", stderr="")
        with patch("subprocess.run", return_value=mock_result):
            jid = watcher.slurm_submit()
        assert jid is None

    def test_sbatch_includes_partition_and_account(self, watcher):
        mock_result = MagicMock(returncode=0, stdout="Submitted batch job 99\n", stderr="")
        with patch("subprocess.run", return_value=mock_result) as mock_sub:
            watcher.slurm_submit()
        cmd = mock_sub.call_args[0][0]
        assert "--partition=gpu-test" in cmd
        assert "--account=test-acct" in cmd

    def test_sbatch_exports_head_host_and_ray_port(self, watcher):
        mock_result = MagicMock(returncode=0, stdout="Submitted batch job 99\n", stderr="")
        with patch("subprocess.run", return_value=mock_result) as mock_sub:
            watcher.slurm_submit()
        cmd = mock_sub.call_args[0][0]
        export_arg = next(a for a in cmd if a.startswith("--export="))
        assert "STROMA_HEAD_HOST=test-head" in export_arg
        assert "STROMA_RAY_PORT=6380" in export_arg


class TestSlurmJobState:
    def test_returns_running_state(self, watcher):
        mock_result = MagicMock(returncode=0, stdout="RUNNING\n", stderr="")
        with patch("subprocess.run", return_value=mock_result):
            assert watcher.slurm_job_state("42") == "RUNNING"

    def test_returns_none_for_missing_job(self, watcher):
        mock_result = MagicMock(returncode=0, stdout="", stderr="")
        with patch("subprocess.run", return_value=mock_result):
            assert watcher.slurm_job_state("99") is None

    def test_returns_none_on_squeue_failure(self, watcher):
        with patch("subprocess.run", side_effect=FileNotFoundError):
            assert watcher.slurm_job_state("42") is None


class TestSlurmActiveIds:
    def test_returns_active_subset(self, watcher):
        mock_result = MagicMock(returncode=0, stdout="42\n43\n", stderr="")
        with patch("subprocess.run", return_value=mock_result):
            active = watcher.slurm_active_ids(["42", "43", "99"])
        assert active == {"42", "43"}

    def test_returns_empty_for_empty_input(self, watcher):
        with patch("subprocess.run") as mock_sub:
            active = watcher.slurm_active_ids([])
        mock_sub.assert_not_called()
        assert active == set()

    def test_returns_empty_on_squeue_failure(self, watcher):
        with patch("subprocess.run", side_effect=FileNotFoundError):
            assert watcher.slurm_active_ids(["42"]) == set()


class TestSlurmCancel:
    def test_calls_scancel(self, watcher):
        mock_result = MagicMock(returncode=0, stdout="", stderr="")
        with patch("subprocess.run", return_value=mock_result) as mock_sub:
            watcher.slurm_cancel("42")
        cmd = mock_sub.call_args[0][0]
        assert "scancel" in cmd
        assert "42" in cmd

    def test_does_not_raise_on_failure(self, watcher):
        """scancel errors are logged but must not propagate."""
        with patch("subprocess.run", side_effect=FileNotFoundError):
            watcher.slurm_cancel("42")  # should not raise


# =============================================================================
# State machine logic
# =============================================================================

class TestReconcileAgainstSlurm:
    def test_removes_jobs_no_longer_in_slurm(self, watcher):
        state = watcher.WatcherState(
            jobs={"42": {"state": "running"}, "99": {"state": "joined"}}
        )
        # Only job 42 is still active in Slurm
        with patch.object(watcher, "slurm_active_ids", return_value={"42"}):
            changed = watcher.reconcile_against_slurm(state)
        assert changed is True
        assert "99" not in state.jobs
        assert "42" in state.jobs

    def test_no_change_when_all_active(self, watcher):
        state = watcher.WatcherState(jobs={"42": {"state": "running"}})
        with patch.object(watcher, "slurm_active_ids", return_value={"42"}):
            changed = watcher.reconcile_against_slurm(state)
        assert changed is False

    def test_no_op_when_no_jobs(self, watcher):
        state = watcher.WatcherState()
        with patch.object(watcher, "slurm_active_ids") as mock_active:
            changed = watcher.reconcile_against_slurm(state)
        mock_active.assert_not_called()
        assert changed is False


class TestAdvancePendingJobs:
    def test_pending_transitions_to_running(self, watcher):
        state = watcher.WatcherState(jobs={"42": {"state": "pending"}})
        with patch.object(watcher, "slurm_job_state", return_value="RUNNING"):
            watcher.advance_pending_jobs(state, set())
        assert state.jobs["42"]["state"] == "running"

    def test_pending_removed_when_slurm_job_gone(self, watcher):
        state = watcher.WatcherState(jobs={"42": {"state": "pending"}})
        with patch.object(watcher, "slurm_job_state", return_value=None):
            watcher.advance_pending_jobs(state, set())
        assert "42" not in state.jobs

    def test_running_transitions_to_joined_when_new_ray_node(self, watcher):
        state = watcher.WatcherState(jobs={"42": {"state": "running", "ray_node_id": None}})
        existing = {"node-AAA"}
        new_node = "node-BBB"
        with patch.object(watcher, "ray_gpu_node_ids", return_value={*existing, new_node}):
            watcher.advance_pending_jobs(state, existing)
        assert state.jobs["42"]["state"] == "joined"
        assert state.jobs["42"]["ray_node_id"] == new_node

    def test_running_removed_when_slurm_done_and_no_ray_node(self, watcher):
        state = watcher.WatcherState(jobs={"42": {"state": "running", "ray_node_id": None}})
        with patch.object(watcher, "ray_gpu_node_ids", return_value=set()), \
             patch.object(watcher, "slurm_job_state", return_value=None):
            watcher.advance_pending_jobs(state, set())
        assert "42" not in state.jobs


class TestScaleUpOk:
    def test_returns_true_within_burst_limit_and_past_cooldown(self, watcher):
        state = watcher.WatcherState(jobs={}, last_scale_up=None)
        with patch.object(watcher, "MAX_BURST", 3), \
             patch.object(watcher, "UP_COOLDOWN", 120):
            assert watcher.scale_up_ok(state) is True

    def test_returns_false_when_at_burst_limit(self, watcher):
        state = watcher.WatcherState(
            jobs={"1": {}, "2": {}, "3": {}},  # 3 == MAX_BURST
        )
        with patch.object(watcher, "MAX_BURST", 3):
            assert watcher.scale_up_ok(state) is False

    def test_returns_false_within_cooldown(self, watcher):
        recent = datetime.now(timezone.utc).isoformat()
        state = watcher.WatcherState(jobs={}, last_scale_up=recent)
        with patch.object(watcher, "MAX_BURST", 3), \
             patch.object(watcher, "UP_COOLDOWN", 120):
            assert watcher.scale_up_ok(state) is False


# =============================================================================
# Full tick integration (everything mocked)
# =============================================================================

class TestTick:
    def _make_state(self, watcher):
        return watcher.WatcherState()

    def test_tick_submits_job_when_queue_exceeds_threshold(self, watcher, tmp_state_file):
        state = watcher.WatcherState()
        with patch.object(watcher, "STATE_FILE", tmp_state_file), \
             patch.object(watcher, "vllm_healthy", return_value=True), \
             patch.object(watcher, "fetch_metrics",
                          return_value={"vllm:num_requests_waiting": 5.0,
                                        "vllm:num_requests_running": 0.0}), \
             patch.object(watcher, "reconcile_against_slurm", return_value=False), \
             patch.object(watcher, "advance_pending_jobs", return_value=set()), \
             patch.object(watcher, "slurm_submit", return_value="555") as mock_submit, \
             patch.object(watcher, "MAX_BURST", 3), \
             patch.object(watcher, "UP_THRESHOLD", 2), \
             patch.object(watcher, "UP_COOLDOWN", 0):
            watcher.tick(state, set())
        mock_submit.assert_called_once()
        assert "555" in state.jobs

    def test_tick_skips_scaling_when_vllm_unhealthy(self, watcher, tmp_state_file):
        state = watcher.WatcherState()
        with patch.object(watcher, "STATE_FILE", tmp_state_file), \
             patch.object(watcher, "vllm_healthy", return_value=False), \
             patch.object(watcher, "reconcile_against_slurm", return_value=False), \
             patch.object(watcher, "slurm_submit") as mock_submit:
            watcher.tick(state, set())
        mock_submit.assert_not_called()

    def test_tick_starts_idle_timer_when_queue_empty_and_burst_active(
        self, watcher, tmp_state_file
    ):
        state = watcher.WatcherState(
            jobs={"42": {"state": "joined"}},
            idle_since=None,
        )
        with patch.object(watcher, "STATE_FILE", tmp_state_file), \
             patch.object(watcher, "vllm_healthy", return_value=True), \
             patch.object(watcher, "fetch_metrics",
                          return_value={"vllm:num_requests_waiting": 0.0,
                                        "vllm:num_requests_running": 0.0}), \
             patch.object(watcher, "reconcile_against_slurm", return_value=False), \
             patch.object(watcher, "advance_pending_jobs", return_value=set()):
            watcher.tick(state, set())
        assert state.idle_since is not None

    def test_tick_cancels_jobs_after_idle_threshold(self, watcher, tmp_state_file):
        old_iso = "2000-01-01T00:00:00+00:00"  # very old — idle threshold exceeded
        state = watcher.WatcherState(
            jobs={"42": {"state": "joined"}},
            idle_since=old_iso,
        )
        with patch.object(watcher, "STATE_FILE", tmp_state_file), \
             patch.object(watcher, "vllm_healthy", return_value=True), \
             patch.object(watcher, "fetch_metrics",
                          return_value={"vllm:num_requests_waiting": 0.0,
                                        "vllm:num_requests_running": 0.0}), \
             patch.object(watcher, "reconcile_against_slurm", return_value=False), \
             patch.object(watcher, "advance_pending_jobs", return_value=set()), \
             patch.object(watcher, "slurm_cancel") as mock_cancel, \
             patch.object(watcher, "DOWN_IDLE_S", 300):
            watcher.tick(state, set())
        mock_cancel.assert_called_once_with("42")
        assert "42" not in state.jobs

    def test_tick_resets_idle_timer_when_requests_resume(self, watcher, tmp_state_file):
        # waiting=1 is below UP_THRESHOLD (2) so scale-up is not attempted;
        # the "activity seen" elif branch should clear idle_since.
        state = watcher.WatcherState(
            jobs={"42": {"state": "joined"}},
            idle_since="2026-03-28T00:00:00+00:00",
        )
        with patch.object(watcher, "STATE_FILE", tmp_state_file), \
             patch.object(watcher, "vllm_healthy", return_value=True), \
             patch.object(watcher, "fetch_metrics",
                          return_value={"vllm:num_requests_waiting": 1.0,
                                        "vllm:num_requests_running": 1.0}), \
             patch.object(watcher, "reconcile_against_slurm", return_value=False), \
             patch.object(watcher, "advance_pending_jobs", return_value=set()):
            watcher.tick(state, set())
        assert state.idle_since is None

    def test_tick_does_not_exceed_max_burst(self, watcher, tmp_state_file):
        # 3 jobs already at MAX_BURST=3
        state = watcher.WatcherState(
            jobs={"1": {"state": "joined"},
                  "2": {"state": "joined"},
                  "3": {"state": "joined"}},
        )
        with patch.object(watcher, "STATE_FILE", tmp_state_file), \
             patch.object(watcher, "vllm_healthy", return_value=True), \
             patch.object(watcher, "fetch_metrics",
                          return_value={"vllm:num_requests_waiting": 10.0,
                                        "vllm:num_requests_running": 0.0}), \
             patch.object(watcher, "reconcile_against_slurm", return_value=False), \
             patch.object(watcher, "advance_pending_jobs", return_value=set()), \
             patch.object(watcher, "MAX_BURST", 3), \
             patch.object(watcher, "slurm_submit") as mock_submit:
            watcher.tick(state, set())
        mock_submit.assert_not_called()
