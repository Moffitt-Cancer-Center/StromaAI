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
import math
import os
import re
import shutil
import subprocess
from dataclasses import dataclass, field
from enum import Enum
from typing import ClassVar, Optional

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

    # Slurm GPU resource request (--gres value).  Empty string = use --gpus-per-node=1.
    gres:           str = field(default="")
    # Number of logical GPUs advertised to Ray (must match GRES count above).
    gpus_per_node:  int = 1

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

        # HPC clusters often install Slurm under a non-standard prefix that
        # isn't on systemd's default PATH.  If STROMA_SLURM_BIN_DIR is set,
        # prepend it so shutil.which() can find sbatch/squeue/scancel.
        slurm_bin_dir = os.environ.get("STROMA_SLURM_BIN_DIR", "")
        if slurm_bin_dir:
            os.environ["PATH"] = slurm_bin_dir + os.pathsep + os.environ.get("PATH", "")

        instance = cls(
            partition    = os.environ.get("STROMA_SLURM_PARTITION", "stroma-ai-gpu"),
            account      = os.environ.get("STROMA_SLURM_ACCOUNT",   "stroma-ai-service"),
            slurm_script = os.environ.get("STROMA_SLURM_SCRIPT",    "/share/slurm/stroma_ai_worker.slurm"),
            walltime     = os.environ.get("STROMA_SLURM_WALLTIME",  "12:00:00"),
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
            gres            = os.environ.get("STROMA_SLURM_GRES", ""),
            gpus_per_node   = int(os.environ.get("STROMA_GPUS_PER_NODE", "1")),
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

        The worker script prefers the shared network venv for ``ray start``
        (same Python version as the head node — no version mismatch possible).
        It falls back to ``apptainer exec --nv <sif> ray start`` when the venv
        is not reachable or ``STROMA_WORKER_MODE=container`` is set.

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
            # GPU resource: explicit GRES type beats generic --gpus-per-node.
            # --gres and --gpus-per-node conflict when both appear; only pass
            # one to avoid Slurm allocating unexpected MIG slices or doubles.
            (f"--gres={self.gres}" if self.gres else "--gpus-per-node=1"),
            (
                f"--export=ALL"
                f",STROMA_HEAD_HOST={self.head_host}"
                f",STROMA_RAY_PORT={self.ray_port}"
                f",STROMA_INSTALL_DIR={self.install_dir}"
                f",STROMA_SHARED_ROOT={self.shared_root}"
                f",STROMA_CONTAINER={self.container_path}"
                f",STROMA_CONTAINER_GPU_FLAG={self.gpu_flag}"
                f",STROMA_GPUS_PER_NODE={self.gpus_per_node}"
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

    # ---------------------------------------------------------------------------
    # GPU resource discovery — query Slurm for available GPU types and VRAM
    # ---------------------------------------------------------------------------

    # Well-known GPU VRAM in MB.  Used when the GRES name doesn't embed a
    # memory hint (i.e. full GPUs, not MIG slices).
    _GPU_VRAM_TABLE: ClassVar[dict[str, int]] = {
        "a100":    81920,   # 80 GB
        "a100_80": 81920,
        "a100_40": 40960,
        "a30":     24576,   # 24 GB
        "a40":     49152,   # 48 GB
        "a10":     24576,
        "l40":     49152,
        "l40s":    49152,
        "l4":      24576,
        "h100":    81920,
        "h200":    143360,  # 141 GB
        "v100":    16384,   # 16 GB
        "v100s":   32768,   # 32 GB
        "t4":      16384,
        "rtx_4090": 24576,
        "rtx_3090": 24576,
        "rtx_a6000": 49152,
    }

    @staticmethod
    def _parse_gres_vram_mb(gres_type: str) -> Optional[int]:
        """Extract VRAM from a GRES type name.

        Handles MIG profiles like ``a30-2g.12gb`` (returns 12288) and full
        GPUs like ``a30`` (looked up in the table).  Returns None if the
        GPU type is unrecognised.
        """
        gres_lower = gres_type.lower()

        # MIG pattern: <gpu>-<compute>g.<mem>gb  e.g. a30-2g.12gb
        m = re.search(r'(\d+)\s*gb$', gres_lower)
        if m:
            return int(m.group(1)) * 1024

        # Full GPU — look up in table
        # Strip common prefixes/suffixes: "nvidia_", "gpu_", etc.
        clean = re.sub(r'^(nvidia[_-]?|gpu[_-]?)', '', gres_lower)
        for known, vram in ClusterManager._GPU_VRAM_TABLE.items():
            if known in clean or clean in known:
                return vram

        return None

    def query_gpu_types(self) -> list[dict]:
        """Query Slurm for GPU types available in the configured partition.

        Returns a list of dicts::

            [
                {"gres_type": "a30", "vram_mb": 24576, "idle_nodes": 3, "total_nodes": 10},
                {"gres_type": "a30-2g.12gb", "vram_mb": 12288, "idle_nodes": 2, "total_nodes": 4},
            ]

        Sorted by VRAM descending (biggest GPUs first).
        """
        try:
            result = subprocess.run(
                [
                    "sinfo",
                    f"--partition={self.partition}",
                    "--noheader",
                    "--Node",
                    "--Format=nodehost,gres,stateshort",
                ],
                capture_output=True, text=True, timeout=10, check=False,
            )
        except (subprocess.SubprocessError, FileNotFoundError) as exc:
            log.warning("sinfo query failed: %s", exc)
            return []

        if result.returncode != 0:
            log.warning("sinfo rc=%d: %s", result.returncode, result.stderr.strip())
            return []

        # Parse sinfo output: each line is "nodename  gres  state"
        # gres looks like "gpu:a30:1" or "gpu:a30-2g.12gb:2"
        gpu_info: dict[str, dict] = {}  # gres_type → {vram_mb, idle, total}

        for line in result.stdout.strip().splitlines():
            parts = line.split()
            if len(parts) < 3:
                continue
            _node, gres_str, state = parts[0], parts[1], parts[2]
            is_idle = state.lower() in ("idle", "mix", "mixed")

            # Parse GRES entries: "gpu:a30:1,gpu:a30-2g.12gb:2" or just "gpu:a30:1"
            for gres_entry in gres_str.split(","):
                gres_parts = gres_entry.split(":")
                if len(gres_parts) < 2 or gres_parts[0] != "gpu":
                    continue

                gres_type = gres_parts[1]
                vram = self._parse_gres_vram_mb(gres_type)
                if vram is None:
                    continue

                if gres_type not in gpu_info:
                    gpu_info[gres_type] = {
                        "gres_type": gres_type,
                        "vram_mb": vram,
                        "idle_nodes": 0,
                        "total_nodes": 0,
                    }

                gpu_info[gres_type]["total_nodes"] += 1
                if is_idle:
                    gpu_info[gres_type]["idle_nodes"] += 1

        types = sorted(gpu_info.values(), key=lambda x: x["vram_mb"], reverse=True)
        if types:
            log.info(
                "GPU types in partition %s: %s",
                self.partition,
                ", ".join(f"{t['gres_type']}({t['vram_mb']}MB, {t['idle_nodes']}/{t['total_nodes']} idle)" for t in types),
            )
        return types

    def select_gpu_for_model(
        self,
        vram_required_mb: int,
        gpu_count: int,
    ) -> tuple[Optional[str], int]:
        """Select the best GPU type and compute node count for a model.

        Parameters
        ----------
        vram_required_mb:
            Total VRAM the model needs (across all GPUs).
        gpu_count:
            Minimum number of GPUs required (tensor-parallel degree).

        Returns
        -------
        (gres_type, num_nodes) or (None, gpu_count) if discovery fails.
        ``gres_type`` is the Slurm GRES type string (e.g. "a30") to use
        in ``--gres=gpu:TYPE:N``.  When discovery fails, falls back to
        generic ``--gpus-per-node`` allocation.
        """
        types = self.query_gpu_types()
        if not types:
            log.warning("No GPU types discovered — falling back to generic allocation")
            num_nodes = max(1, math.ceil(gpu_count / self.gpus_per_node))
            return None, num_nodes

        per_gpu_vram = vram_required_mb / gpu_count if gpu_count > 0 else vram_required_mb

        # Filter to GPU types with enough VRAM per GPU
        suitable = [t for t in types if t["vram_mb"] >= per_gpu_vram]
        if not suitable:
            # No single GPU type has enough VRAM — try the biggest available
            # and increase GPU count to compensate
            biggest = types[0]
            adjusted_gpu_count = math.ceil(vram_required_mb / biggest["vram_mb"])
            # TP must be power-of-two
            tp = 1
            while tp < adjusted_gpu_count:
                tp *= 2
            adjusted_gpu_count = tp

            if biggest["idle_nodes"] >= adjusted_gpu_count:
                log.info(
                    "No GPU with %dMB VRAM; using %d× %s (%dMB each)",
                    int(per_gpu_vram), adjusted_gpu_count,
                    biggest["gres_type"], biggest["vram_mb"],
                )
                gpus_per_gres_node = int(biggest.get("total_nodes", 1) and 1)  # assume 1 per node
                num_nodes = max(1, math.ceil(adjusted_gpu_count / self.gpus_per_node))
                return biggest["gres_type"], num_nodes
            log.warning("Insufficient GPU resources for %dMB VRAM model", vram_required_mb)
            return None, max(1, math.ceil(gpu_count / self.gpus_per_node))

        # Prefer the smallest suitable GPU type with enough idle nodes
        # (don't waste big GPUs on models that fit smaller ones)
        suitable.sort(key=lambda t: t["vram_mb"])

        for candidate in suitable:
            nodes_needed = max(1, math.ceil(gpu_count / self.gpus_per_node))
            if candidate["idle_nodes"] >= nodes_needed:
                log.info(
                    "Selected GPU type %s (%dMB) for model needing %dMB/GPU, %d node(s)",
                    candidate["gres_type"], candidate["vram_mb"],
                    int(per_gpu_vram), nodes_needed,
                )
                return candidate["gres_type"], nodes_needed

        # No type has enough idle nodes — use the biggest with most availability
        best = max(suitable, key=lambda t: t["idle_nodes"])
        nodes_needed = max(1, math.ceil(gpu_count / self.gpus_per_node))
        log.warning(
            "Not enough idle %s nodes (%d/%d needed) — submitting anyway (Slurm will queue)",
            best["gres_type"], best["idle_nodes"], nodes_needed,
        )
        return best["gres_type"], nodes_needed

    def submit_model_worker(
        self,
        *,
        model_id: str,
        model_path: str,
        vllm_port: int,
        gpu_count: int = 1,
        vram_required_mb: int = 0,
        quantization: str = "",
        max_model_len: int = 0,
        slurm_script: Optional[str] = None,
    ) -> SubmitResult:
        """
        Submit a Slurm job that starts a vLLM process for a specific model.

        Unlike :meth:`submit_worker`, which launches a generic Ray worker,
        this method passes model-specific parameters to a dedicated Slurm
        script (``stroma_ai_model_worker.slurm``) so the worker can run
        ``vllm serve`` with the correct paths, ports, and GPU count.

        Parameters
        ----------
        model_id:
            Identifier for the model (used in logging / state keys).
        model_path:
            Filesystem path to the model weights directory.
        vllm_port:
            Port on which vLLM should listen for this model.
        gpu_count:
            Number of GPUs to request (tensor-parallel degree).
        vram_required_mb:
            Estimated VRAM needed for the model.  When >0, GPU-aware
            scheduling queries Slurm for available GPU types and targets
            nodes with sufficient VRAM (avoids MIG slices when full GPUs
            are needed).  0 = fall back to generic ``--gpus-per-node``.
        quantization:
            Quantization method name (e.g. ``awq``, ``gptq``), empty for none.
        max_model_len:
            Maximum context length override.  0 = vLLM auto-detects.
        slurm_script:
            Override for the Slurm script path; defaults to the model worker
            script derived from the configured ``slurm_script`` directory.

        Returns
        -------
        SubmitResult
        """
        if slurm_script is None:
            from pathlib import Path as _P
            slurm_script = str(
                _P(self.slurm_script).parent / "stroma_ai_model_worker.slurm"
            )

        # GPU-aware scheduling: query Slurm for available GPU types and
        # pick nodes with sufficient VRAM.  Falls back to generic
        # --gpus-per-node when discovery is unavailable.
        gres_type = None
        num_nodes = max(1, math.ceil(gpu_count / self.gpus_per_node))
        if vram_required_mb > 0:
            try:
                gres_type, num_nodes = self.select_gpu_for_model(
                    vram_required_mb, gpu_count,
                )
            except Exception as exc:
                log.warning(
                    "GPU type discovery failed — falling back to generic allocation: %s",
                    exc,
                )

        # Build GPU allocation args — specific type when available,
        # generic count otherwise.
        if gres_type:
            gpu_args = [f"--gres=gpu:{gres_type}:{self.gpus_per_node}"]
        else:
            gpu_args = [f"--gpus-per-node={self.gpus_per_node}"]

        # Build per-model export variables
        export_vars = (
            f"ALL"
            f",STROMA_HEAD_HOST={self.head_host}"
            f",STROMA_RAY_PORT={self.ray_port}"
            f",STROMA_INSTALL_DIR={self.install_dir}"
            f",STROMA_SHARED_ROOT={self.shared_root}"
            f",STROMA_CONTAINER={self.container_path}"
            f",STROMA_CONTAINER_GPU_FLAG={self.gpu_flag}"
            f",MODEL_ID={model_id}"
            f",MODEL_PATH={model_path}"
            f",VLLM_PORT={vllm_port}"
            f",TENSOR_PARALLEL_SIZE={gpu_count}"
            f",NUM_NODES={num_nodes}"
        )
        if quantization:
            export_vars += f",QUANTIZATION={quantization}"
        if max_model_len > 0:
            export_vars += f",MAX_MODEL_LEN={max_model_len}"

        cmd = [
            "sbatch",
            f"--partition={self.partition}",
            f"--account={self.account}",
            f"--time={self.walltime}",
            f"--nodes={num_nodes}",
            f"--ntasks-per-node=1",
            *gpu_args,
            f"--cpus-per-task={self.cpus}",
            f"--mem={self.mem}",
            f"--output={self.log_dir}/slurm-model-{model_id}-%j.out",
            f"--error={self.log_dir}/slurm-model-{model_id}-%j.err",
            f"--job-name=stroma-{model_id}",
            f"--export={export_vars}",
            slurm_script,
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
            msg = f"sbatch execution failed for model {model_id}: {exc}"
            log.error("%s", msg)
            return SubmitResult(success=False, error=msg)

        if result.returncode != 0:
            msg = f"sbatch rc={result.returncode} (model {model_id}): {result.stderr.strip()}"
            log.error("%s", msg)
            return SubmitResult(success=False, error=msg)

        match = re.search(r"Submitted batch job (\d+)", result.stdout)
        if not match:
            msg = f"Unexpected sbatch output: {result.stdout.strip()!r}"
            log.error("%s", msg)
            return SubmitResult(success=False, error=msg)

        job_id = match.group(1)
        log.info(
            "Submitted model worker: model=%s job=%s port=%d gpus=%d nodes=%d gres=%s",
            model_id, job_id, vllm_port, gpu_count, num_nodes,
            gres_type or "generic",
        )
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
