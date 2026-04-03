#!/usr/bin/env python3
"""
StromaAI — ClusterManager
==========================
Abstracts HPC cluster operations (Slurm submission, state queries, job
cancellation) and Apptainer container management behind a clean interface.

All Slurm interactions are isolated here so the Watcher, CLI, and any future
orchestrators deal with typed return values rather than raw shell output.

Apptainer invocations use the same OCI-compatible .sif image for both:
  • Head-node tools     (ray head, vLLM serve)
  • Slurm burst workers (ray worker, GPU inference)

This ensures binary-level consistency across every node in the cluster.

Usage
-----
    from cluster_manager import ClusterManager, WorkerState

    mgr = ClusterManager.from_env()
    job_id = mgr.submit_worker()        # Returns Slurm job ID or raises
    state  = mgr.get_worker_state(job_id)
    active = mgr.get_active_worker_ids([job_id, ...])
    mgr.cancel_worker(job_id)

Environment variables
---------------------
All configuration comes from environment variables set in config.env.
See config/config.example.env for the full reference.
"""

from __future__ import annotations

import logging
import os
import re
import shutil
import subprocess
from dataclasses import dataclass, field
from enum import Enum
from typing import Optional

log = logging.getLogger("stroma-ai.cluster-manager")


# ---------------------------------------------------------------------------
# Types
# ---------------------------------------------------------------------------

class WorkerState(str, Enum):
    """Normalised Slurm job state as seen by the ClusterManager."""
    PENDING    = "pending"     # sbatch submitted; not yet RUNNING in Slurm
    CONFIGURING = "configuring"  # Slurm allocating resources (rare transition)
    RUNNING    = "running"     # Slurm is RUNNING; Ray may not have joined yet
    COMPLETING = "completing"  # Slurm wrapping up
    COMPLETED  = "completed"   # Job finished cleanly
    FAILED     = "failed"      # Job exited with non-zero status
    CANCELLED  = "cancelled"   # scancel'd or timed out
    UNKNOWN    = "unknown"     # Returned by squeue in unexpected states


# Map raw Slurm state strings → WorkerState
_SLURM_STATE_MAP: dict[str, WorkerState] = {
    "PENDING":     WorkerState.PENDING,
    "CONFIGURING": WorkerState.CONFIGURING,
    "RUNNING":     WorkerState.RUNNING,
    "COMPLETING":  WorkerState.COMPLETING,
    "COMPLETED":   WorkerState.COMPLETED,
    "FAILED":      WorkerState.FAILED,
    "CANCELLED":   WorkerState.CANCELLED,
    "TIMEOUT":     WorkerState.CANCELLED,
    "NODE_FAIL":   WorkerState.FAILED,
    "PREEMPTED":   WorkerState.CANCELLED,
}


@dataclass
class SubmitResult:
    """Result of a worker submission attempt."""
    success: bool
    job_id: Optional[str] = None
    error: Optional[str] = None


# ---------------------------------------------------------------------------
# ClusterManager
# ---------------------------------------------------------------------------

@dataclass
class ClusterManager:
    """
    Manages Slurm burst worker lifecycle and Apptainer container execution.

    Construct via ``ClusterManager.from_env()`` to pick up all parameters
    from the environment, or instantiate directly for testing.
    """

    # Slurm parameters
    partition:    str
    account:      str
    slurm_script: str
    walltime:     str
    cpus:         str
    mem:          str
    log_dir:      str

    # Cluster topology
    head_host:    str
    ray_port:     int
    shared_root:  str
    install_dir:  str

    # Container
    container_path: str
    container_cmd:  str = field(default="")
    gpu_flag:       str = field(default="--nv")

    # Tuning
    vllm_kv_threads: int = 32

    # ---------------------------------------------------------------------------
    # Factory
    # ---------------------------------------------------------------------------

    @classmethod
    def from_env(cls) -> "ClusterManager":
        """
        Create a ClusterManager from standard StromaAI environment variables.
        Raises RuntimeError if required variables are missing.
        """
        install_dir = os.environ.get("STROMA_INSTALL_DIR", "/opt/stroma-ai")

        instance = cls(
            partition    = os.environ.get("STROMA_SLURM_PARTITION", "stroma-ai-gpu"),
            account      = os.environ.get("STROMA_SLURM_ACCOUNT",   "stroma-ai-service"),
            slurm_script = os.environ.get("STROMA_SLURM_SCRIPT",    "/share/slurm/stroma_ai_worker.slurm"),
            walltime     = os.environ.get("STROMA_SLURM_WALLTIME",  "24:00:00"),
            cpus         = os.environ.get("STROMA_SLURM_CPUS",      "64"),
            mem          = os.environ.get("STROMA_SLURM_MEM",       "900G"),
            log_dir      = os.environ.get("STROMA_LOG_DIR",         f"{install_dir}/logs"),

            head_host    = os.environ.get("STROMA_HEAD_HOST",       "localhost"),
            ray_port     = int(os.environ.get("STROMA_RAY_PORT",    "6380")),
            shared_root  = os.environ.get("STROMA_SHARED_ROOT",     "/share"),
            install_dir  = install_dir,

            container_path  = os.environ.get(
                "STROMA_CONTAINER", "/share/containers/stroma-ai-vllm.sif"
            ),
            container_cmd   = os.environ.get("CONTAINER_CMD", ""),
            gpu_flag        = os.environ.get("STROMA_CONTAINER_GPU_FLAG", "--nv"),
            vllm_kv_threads = int(os.environ.get("STROMA_VLLM_CPU_KV_THREADS", "32")),
        )
        return instance

    # ---------------------------------------------------------------------------
    # Container tooling
    # ---------------------------------------------------------------------------

    def resolve_container_cmd(self) -> str:
        """
        Return the Apptainer/Singularity command available on this host.

        Priority:
          1. CONTAINER_CMD env var (explicit override)
          2. ``apptainer`` on PATH
          3. ``singularity`` on PATH (legacy alias)

        Raises RuntimeError if neither is found.
        """
        if self.container_cmd:
            return self.container_cmd

        for candidate in ("apptainer", "singularity"):
            if shutil.which(candidate):
                log.debug("Using container runtime: %s", candidate)
                return candidate

        raise RuntimeError(
            "Neither 'apptainer' nor 'singularity' found on PATH. "
            "Install Apptainer: https://apptainer.org/docs/admin/latest/installation.html"
        )

    def build_apptainer_exec_args(
        self,
        inner_command: list[str],
        *,
        extra_binds: Optional[list[str]] = None,
    ) -> list[str]:
        """
        Build a complete ``apptainer exec`` argument list for running
        ``inner_command`` inside the stroma-ai-vllm.sif container.

        Parameters
        ----------
        inner_command:
            The command + args to run inside the container (e.g. the
            ``ray start`` invocation).
        extra_binds:
            Additional ``--bind src:dest`` mount points beyond the defaults.

        Returns a list ready for ``subprocess.run()``.
        """
        cmd = self.resolve_container_cmd()
        default_binds = [
            f"{self.shared_root}:{self.shared_root}",  # model weights + scripts
        ]
        all_binds = default_binds + (extra_binds or [])

        args = [cmd, "exec", self.gpu_flag]
        for bind in all_binds:
            args += ["--bind", bind]
        args.append(self.container_path)
        args.extend(inner_command)
        return args

    # ---------------------------------------------------------------------------
    # Slurm operations
    # ---------------------------------------------------------------------------

    def submit_worker(self) -> SubmitResult:
        """
        Submit a burst worker job to Slurm via sbatch.

        The worker script is expected to:
          1. Call ``apptainer exec --nv <sif> ray start --address=<head> --num-gpus=1 --block``
          2. Export STROMA_HEAD_HOST, STROMA_RAY_PORT, and STROMA_SHARED_ROOT.

        Returns a SubmitResult. Does NOT raise on submission failure.
        """
        cmd = [
            "sbatch",
            f"--partition={self.partition}",
            f"--account={self.account}",
            f"--time={self.walltime}",
            f"--cpus-per-task={self.cpus}",
            f"--mem={self.mem}",
            f"--output={self.log_dir}/slurm-%j.out",
            f"--error={self.log_dir}/slurm-%j.err",
            (
                f"--export=ALL"
                f",STROMA_HEAD_HOST={self.head_host}"
                f",STROMA_RAY_PORT={self.ray_port}"
                f",STROMA_SHARED_ROOT={self.shared_root}"
                f",STROMA_CONTAINER={self.container_path}"
                f",STROMA_CONTAINER_GPU_FLAG={self.gpu_flag}"
                f",VLLM_CPU_KV_CACHE_THREADS={self.vllm_kv_threads}"
            ),
            self.slurm_script,
        ]

        try:
            result = subprocess.run(
                cmd,
                capture_output=True,
                text=True,
                timeout=30,
                check=False,
            )
        except (subprocess.SubprocessError, FileNotFoundError) as exc:
            msg = f"sbatch execution failed: {exc}"
            log.error("%s", msg)
            return SubmitResult(success=False, error=msg)

        if result.returncode != 0:
            msg = f"sbatch rc={result.returncode}: {result.stderr.strip()}"
            log.error("%s", msg)
            return SubmitResult(success=False, error=msg)

        match = re.search(r"Submitted batch job (\d+)", result.stdout)
        if not match:
            msg = f"Unexpected sbatch output: {result.stdout.strip()!r}"
            log.error("%s", msg)
            return SubmitResult(success=False, error=msg)

        job_id = match.group(1)
        log.info("Submitted burst worker job %s (partition=%s)", job_id, self.partition)
        return SubmitResult(success=True, job_id=job_id)

    def get_worker_state(self, job_id: str) -> Optional[WorkerState]:
        """
        Return the normalised state of a Slurm job, or None if the job
        is no longer present in the Slurm queue (completed, failed, purged).
        """
        try:
            result = subprocess.run(
                ["squeue", "-j", job_id, "-h", "-o", "%T"],
                capture_output=True,
                text=True,
                timeout=15,
                check=False,
            )
        except (subprocess.SubprocessError, FileNotFoundError):
            log.debug("squeue unavailable — returning None for job %s", job_id)
            return None

        raw = result.stdout.strip()
        if not raw:
            return None  # Job not in queue

        return _SLURM_STATE_MAP.get(raw.upper(), WorkerState.UNKNOWN)

    def get_active_worker_ids(self, job_ids: list[str]) -> set[str]:
        """
        Return the subset of ``job_ids`` that are still present in the
        Slurm queue in any state (PENDING, RUNNING, COMPLETING, etc.).

        Uses a single squeue call regardless of how many IDs are checked.
        """
        if not job_ids:
            return set()

        try:
            result = subprocess.run(
                ["squeue", "-j", ",".join(job_ids), "-h", "-o", "%i"],
                capture_output=True,
                text=True,
                timeout=15,
                check=False,
            )
        except (subprocess.SubprocessError, FileNotFoundError):
            log.debug("squeue unavailable — assuming all jobs active")
            return set(job_ids)

        return {line.strip() for line in result.stdout.splitlines() if line.strip()}

    def cancel_worker(self, job_id: str) -> bool:
        """
        Cancel a Slurm job via scancel.

        Returns True on success, False on failure. Always logs the outcome
        and never raises.
        """
        try:
            result = subprocess.run(
                ["scancel", job_id],
                capture_output=True,
                text=True,
                timeout=15,
                check=False,
            )
        except (subprocess.SubprocessError, FileNotFoundError) as exc:
            log.error("scancel %s failed: %s", job_id, exc)
            return False

        if result.returncode == 0:
            log.info("Cancelled Slurm job %s", job_id)
            return True

        log.warning(
            "scancel %s rc=%d: %s",
            job_id,
            result.returncode,
            result.stderr.strip(),
        )
        return False

    def cancel_all_workers(self, job_ids: list[str]) -> dict[str, bool]:
        """Cancel multiple workers and return a dict of {job_id: success}."""
        return {jid: self.cancel_worker(jid) for jid in job_ids}

    # ---------------------------------------------------------------------------
    # Validation
    # ---------------------------------------------------------------------------

    def validate(self) -> list[str]:
        """
        Run pre-flight checks. Returns a list of error strings (empty = OK).

        Designed to be called at startup by the Watcher or stroma-cli.
        """
        errors: list[str] = []

        import os as _os  # noqa: PLC0415 — localised import for clarity
        from pathlib import Path

        if not Path(self.slurm_script).exists():
            errors.append(
                f"Slurm worker script not found: {self.slurm_script}  "
                f"(set STROMA_SLURM_SCRIPT or copy deploy/slurm/ to {self.shared_root}/slurm/)"
            )

        if not Path(self.container_path).exists():
            errors.append(
                f"Container image not found: {self.container_path}  "
                f"(build with: apptainer build <sif> deploy/containers/stroma-ai-vllm.def)"
            )

        try:
            self.resolve_container_cmd()
        except RuntimeError as exc:
            errors.append(str(exc))

        # Validate Slurm tooling is reachable
        for tool in ("sbatch", "squeue", "scancel"):
            if not shutil.which(tool):
                errors.append(
                    f"Slurm command not found: {tool}  "
                    f"(is this running on a Slurm head node?)"
                )

        return errors
