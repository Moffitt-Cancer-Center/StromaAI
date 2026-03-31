"""
Unit tests for ClusterManager (src/cluster_manager.py).

These tests mock all subprocess calls so they run without Slurm or Apptainer
installed. Tests are grouped by method and cover both happy-path and failure
scenarios.
"""

from __future__ import annotations

import subprocess
from unittest.mock import MagicMock, patch

import pytest

from src.cluster_manager import ClusterManager, SubmitResult, WorkerState


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

@pytest.fixture()
def mgr() -> ClusterManager:
    """A ClusterManager instance with known test parameters."""
    return ClusterManager(
        partition    = "test-gpu",
        account      = "test-account",
        slurm_script = "/share/slurm/stroma_ai_worker.slurm",
        walltime     = "1:00:00",
        cpus         = "8",
        mem          = "64G",
        log_dir      = "/tmp/stroma-test-logs",
        head_host    = "head.test.local",
        ray_port     = 6380,
        shared_root  = "/share",
        install_dir  = "/opt/stroma-test",
        container_path = "/share/containers/stroma-ai-vllm.sif",
        container_cmd  = "apptainer",
        gpu_flag       = "--nv",
        vllm_kv_threads = 16,
    )


# ---------------------------------------------------------------------------
# submit_worker
# ---------------------------------------------------------------------------

class TestSubmitWorker:

    def test_successful_submission(self, mgr):
        mock_run = MagicMock(return_value=MagicMock(
            returncode=0,
            stdout="Submitted batch job 42\n",
            stderr="",
        ))
        with patch("subprocess.run", mock_run):
            result = mgr.submit_worker()

        assert result.success is True
        assert result.job_id == "42"
        assert result.error is None

    def test_sbatch_nonzero_returncode(self, mgr):
        mock_run = MagicMock(return_value=MagicMock(
            returncode=1,
            stdout="",
            stderr="sbatch: error: invalid partition",
        ))
        with patch("subprocess.run", mock_run):
            result = mgr.submit_worker()

        assert result.success is False
        assert result.job_id is None
        assert "rc=1" in result.error

    def test_sbatch_not_found(self, mgr):
        with patch("subprocess.run", side_effect=FileNotFoundError("sbatch not found")):
            result = mgr.submit_worker()

        assert result.success is False
        assert "sbatch execution failed" in result.error

    def test_sbatch_timeout(self, mgr):
        with patch("subprocess.run", side_effect=subprocess.TimeoutExpired(cmd="sbatch", timeout=30)):
            result = mgr.submit_worker()

        assert result.success is False

    def test_unexpected_sbatch_output(self, mgr):
        mock_run = MagicMock(return_value=MagicMock(
            returncode=0,
            stdout="Unexpected output with no job ID\n",
            stderr="",
        ))
        with patch("subprocess.run", mock_run):
            result = mgr.submit_worker()

        assert result.success is False
        assert "Unexpected sbatch output" in result.error

    def test_export_args_contain_head_host(self, mgr):
        """Verify the critical --export flag includes STROMA_HEAD_HOST."""
        captured_cmd = []

        def _capture(*args, **kwargs):
            captured_cmd.extend(args[0])
            return MagicMock(returncode=0, stdout="Submitted batch job 99\n", stderr="")

        with patch("subprocess.run", _capture):
            mgr.submit_worker()

        export_arg = next((a for a in captured_cmd if a.startswith("--export=")), None)
        assert export_arg is not None
        assert "STROMA_HEAD_HOST=head.test.local" in export_arg
        assert "STROMA_RAY_PORT=6380" in export_arg
        assert "STROMA_SHARED_ROOT=/share" in export_arg


# ---------------------------------------------------------------------------
# get_worker_state
# ---------------------------------------------------------------------------

class TestGetWorkerState:

    @pytest.mark.parametrize("raw,expected", [
        ("PENDING",     WorkerState.PENDING),
        ("RUNNING",     WorkerState.RUNNING),
        ("COMPLETING",  WorkerState.COMPLETING),
        ("COMPLETED",   WorkerState.COMPLETED),
        ("FAILED",      WorkerState.FAILED),
        ("CANCELLED",   WorkerState.CANCELLED),
        ("TIMEOUT",     WorkerState.CANCELLED),
        ("NODE_FAIL",   WorkerState.FAILED),
        ("PREEMPTED",   WorkerState.CANCELLED),
    ])
    def test_known_states(self, mgr, raw, expected):
        mock_run = MagicMock(return_value=MagicMock(
            returncode=0, stdout=f"{raw}\n"
        ))
        with patch("subprocess.run", mock_run):
            assert mgr.get_worker_state("123") == expected

    def test_job_not_in_queue(self, mgr):
        mock_run = MagicMock(return_value=MagicMock(returncode=0, stdout=""))
        with patch("subprocess.run", mock_run):
            assert mgr.get_worker_state("999") is None

    def test_squeue_unavailable(self, mgr):
        with patch("subprocess.run", side_effect=FileNotFoundError):
            assert mgr.get_worker_state("1") is None

    def test_unknown_state_string(self, mgr):
        mock_run = MagicMock(return_value=MagicMock(
            returncode=0, stdout="SUSPENDED\n"
        ))
        with patch("subprocess.run", mock_run):
            assert mgr.get_worker_state("1") == WorkerState.UNKNOWN


# ---------------------------------------------------------------------------
# get_active_worker_ids
# ---------------------------------------------------------------------------

class TestGetActiveWorkerIds:

    def test_returns_active_subset(self, mgr):
        mock_run = MagicMock(return_value=MagicMock(
            returncode=0, stdout="101\n103\n"
        ))
        with patch("subprocess.run", mock_run):
            result = mgr.get_active_worker_ids(["101", "102", "103"])

        assert result == {"101", "103"}

    def test_empty_input(self, mgr):
        with patch("subprocess.run") as mock_run:
            result = mgr.get_active_worker_ids([])
        mock_run.assert_not_called()
        assert result == set()

    def test_squeue_failure_returns_full_set(self, mgr):
        with patch("subprocess.run", side_effect=FileNotFoundError):
            result = mgr.get_active_worker_ids(["1", "2"])
        assert result == {"1", "2"}


# ---------------------------------------------------------------------------
# cancel_worker
# ---------------------------------------------------------------------------

class TestCancelWorker:

    def test_successful_cancel(self, mgr):
        mock_run = MagicMock(return_value=MagicMock(returncode=0, stderr=""))
        with patch("subprocess.run", mock_run):
            assert mgr.cancel_worker("55") is True

    def test_scancel_failure(self, mgr):
        mock_run = MagicMock(return_value=MagicMock(
            returncode=1, stderr="scancel: error: job 55 not found"
        ))
        with patch("subprocess.run", mock_run):
            assert mgr.cancel_worker("55") is False

    def test_scancel_not_found(self, mgr):
        with patch("subprocess.run", side_effect=FileNotFoundError):
            assert mgr.cancel_worker("55") is False


# ---------------------------------------------------------------------------
# resolve_container_cmd
# ---------------------------------------------------------------------------

class TestResolveContainerCmd:

    def test_uses_explicit_container_cmd(self, mgr):
        mgr.container_cmd = "singularity"
        assert mgr.resolve_container_cmd() == "singularity"

    def test_auto_detects_apptainer(self):
        mgr_auto = ClusterManager(
            partition="p", account="a", slurm_script="/s", walltime="1:00:00",
            cpus="1", mem="1G", log_dir="/tmp", head_host="h", ray_port=6380,
            shared_root="/share", install_dir="/opt", container_path="/sif",
        )
        with patch("shutil.which", side_effect=lambda x: "/usr/bin/apptainer" if x == "apptainer" else None):
            assert mgr_auto.resolve_container_cmd() == "apptainer"

    def test_falls_back_to_singularity(self):
        mgr_auto = ClusterManager(
            partition="p", account="a", slurm_script="/s", walltime="1:00:00",
            cpus="1", mem="1G", log_dir="/tmp", head_host="h", ray_port=6380,
            shared_root="/share", install_dir="/opt", container_path="/sif",
        )
        with patch("shutil.which", side_effect=lambda x: "/usr/bin/singularity" if x == "singularity" else None):
            assert mgr_auto.resolve_container_cmd() == "singularity"

    def test_raises_if_neither_found(self):
        mgr_auto = ClusterManager(
            partition="p", account="a", slurm_script="/s", walltime="1:00:00",
            cpus="1", mem="1G", log_dir="/tmp", head_host="h", ray_port=6380,
            shared_root="/share", install_dir="/opt", container_path="/sif",
        )
        with patch("shutil.which", return_value=None):
            with pytest.raises(RuntimeError, match="apptainer"):
                mgr_auto.resolve_container_cmd()


# ---------------------------------------------------------------------------
# build_apptainer_exec_args
# ---------------------------------------------------------------------------

class TestBuildApptainerExecArgs:

    def test_basic_structure(self, mgr):
        args = mgr.build_apptainer_exec_args(["ray", "start", "--block"])
        assert args[0] == "apptainer"
        assert args[1] == "exec"
        assert mgr.gpu_flag in args
        assert mgr.container_path in args
        assert args[-3:] == ["ray", "start", "--block"]

    def test_extra_binds_included(self, mgr):
        args = mgr.build_apptainer_exec_args(
            ["echo", "test"],
            extra_binds=["/scratch:/scratch"],
        )
        bind_pairs = []
        for i, a in enumerate(args):
            if a == "--bind" and i + 1 < len(args):
                bind_pairs.append(args[i + 1])
        assert "/scratch:/scratch" in bind_pairs

    def test_shared_root_always_bound(self, mgr):
        args = mgr.build_apptainer_exec_args(["echo"])
        bind_args = []
        for i, a in enumerate(args):
            if a == "--bind":
                bind_args.append(args[i + 1])
        assert any("/share" in b for b in bind_args)


# ---------------------------------------------------------------------------
# from_env
# ---------------------------------------------------------------------------

class TestFromEnv:

    def test_reads_environment_variables(self, monkeypatch):
        monkeypatch.setenv("STROMA_SLURM_PARTITION", "my-partition")
        monkeypatch.setenv("STROMA_HEAD_HOST", "my-head.hpc.edu")
        monkeypatch.setenv("STROMA_RAY_PORT", "6381")
        monkeypatch.setenv("STROMA_CONTAINER", "/my/custom.sif")

        mgr = ClusterManager.from_env()

        assert mgr.partition    == "my-partition"
        assert mgr.head_host    == "my-head.hpc.edu"
        assert mgr.ray_port     == 6381
        assert mgr.container_path == "/my/custom.sif"

    def test_defaults_when_env_missing(self, monkeypatch):
        for var in (
            "STROMA_SLURM_PARTITION", "STROMA_HEAD_HOST", "STROMA_RAY_PORT",
            "STROMA_CONTAINER", "STROMA_INSTALL_DIR",
        ):
            monkeypatch.delenv(var, raising=False)

        mgr = ClusterManager.from_env()
        assert mgr.partition == "stroma-ai-gpu"
        assert mgr.head_host == "localhost"
        assert mgr.ray_port  == 6380
