#!/usr/bin/env python3
"""
StromaAI — Model Registry
==========================
Auto-discovers models on the shared filesystem and exposes a catalog with
hardware-aware metadata (VRAM requirements, GPU count, quantization type).

The registry is consumed by:
  - **Gateway** — aggregated ``/v1/models`` endpoint and model-aware routing
  - **Model Watcher** — per-model lifecycle management (start/stop via Slurm)

Discovery
---------
Recursively scans ``STROMA_MODELS_DIR`` for directories containing a
``config.json`` (HuggingFace model format).  Each valid model directory
becomes a ``ModelEntry`` in the catalog.

Metadata inference
------------------
1. Reads ``config.json`` for architecture, parameter count hints, and dtype.
2. Checks for ``quantize_config.json`` (GPTQ) or ``quant_config.json`` (AWQ).
3. Infers quantization from directory name conventions (``-AWQ``, ``-GPTQ``).
4. Computes VRAM requirements using the same constants as ``hfmodel-check``.
5. Infers minimum GPU count from VRAM vs per-GPU capacity.

Overrides
---------
Drop a ``stroma.yaml`` file in any model directory to override auto-detected
values (gpu_count, quantization, max_model_len, tier, display_name).

Environment variables
---------------------
  STROMA_MODELS_DIR         Root directory to scan (default: /share/models)
  STROMA_PERSISTENT_MODEL   Model ID that stays always-on (matched by dirname)
  STROMA_GPU_VRAM_MB        Per-GPU VRAM in MB for planning (default: 24576 = 24GB)
  STROMA_MODEL_PORT_RANGE_START  First port for on-demand vLLM instances (default: 8001)
  STROMA_MODEL_PORT_RANGE_END    Last port for on-demand vLLM instances (default: 8099)

Requires
--------
  pip install pyyaml  (optional — only for stroma.yaml overrides)
"""

from __future__ import annotations

import json
import logging
import math
import os
import re
import threading
import time
from dataclasses import dataclass, field
from enum import Enum
from pathlib import Path
from typing import Optional

log = logging.getLogger("stroma-ai.model-registry")

# ---------------------------------------------------------------------------
# Constants — same values as hfmodel-check for consistency
# ---------------------------------------------------------------------------

# Bytes per parameter for common dtypes / quantization schemes
DTYPE_BYTES: dict[str, float] = {
    "fp32":     4.0,
    "float32":  4.0,
    "fp16":     2.0,
    "float16":  2.0,
    "bf16":     2.0,
    "bfloat16": 2.0,
    "int8":     1.0,
    "gptq":     0.5,
    "awq":      0.5,
    "int4":     0.5,
}

# Overhead multiplier: KV cache, activations, framework buffers
INFERENCE_OVERHEAD = 1.20


# ---------------------------------------------------------------------------
# Types
# ---------------------------------------------------------------------------

class ModelTier(str, Enum):
    """How the model is managed by the watcher."""
    PERSISTENT = "persistent"  # Always-on, existing burst-scale behaviour
    ON_DEMAND  = "on-demand"   # Spun up via Slurm when requested, drained after idle


class ModelStatus(str, Enum):
    """Runtime status of a model."""
    AVAILABLE    = "available"     # Known, no GPUs allocated
    REQUESTED    = "requested"     # Gateway signalled watcher
    PROVISIONING = "provisioning"  # Slurm job submitted, vLLM loading
    SERVING      = "serving"       # vLLM healthy, accepting requests
    DRAINING     = "draining"      # Idle timeout hit, cancelling jobs
    ERROR        = "error"         # Failed to start or crashed


@dataclass
class ModelEntry:
    """A single model in the registry catalog."""
    model_id: str             # Unique ID derived from directory name
    path: str                 # Absolute path to model weights
    display_name: str         # Human-readable name for UI display
    architecture: str         # Model architecture (e.g. Qwen2ForCausalLM)
    param_count: int          # Total learnable parameters (0 = unknown)
    dtype: str                # Detected native dtype (bf16, fp16, etc.)
    quantization: str         # Detected quantization (awq, gptq, or "none")
    vram_required_mb: int     # Estimated VRAM needed (with overhead)
    gpu_count: int            # Minimum GPUs needed for this model
    max_model_len: int        # Maximum context length (tokens)
    tier: ModelTier           # persistent or on-demand
    status: ModelStatus       # Runtime status (managed by watcher)

    # Runtime fields (set by watcher, not discovery)
    vllm_port: Optional[int] = None
    slurm_job_ids: list[str] = field(default_factory=list)
    error_message: str = ""

    def to_openai_model(self) -> dict:
        """Return an OpenAI-compatible model object for /v1/models."""
        return {
            "id": self.model_id,
            "object": "model",
            "created": int(time.time()),
            "owned_by": "stroma-ai",
            "meta": {
                "display_name": self.display_name,
                "architecture": self.architecture,
                "parameters": self.param_count,
                "quantization": self.quantization,
                "gpu_count": self.gpu_count,
                "max_model_len": self.max_model_len,
                "vram_required_mb": self.vram_required_mb,
                "tier": self.tier.value,
                "status": self.status.value,
            },
        }


# ---------------------------------------------------------------------------
# Config
# ---------------------------------------------------------------------------

MODELS_DIR       = os.environ.get("STROMA_MODELS_DIR", "/share/models")
PERSISTENT_MODEL = os.environ.get("STROMA_PERSISTENT_MODEL", "")
GPU_VRAM_MB      = int(os.environ.get("STROMA_GPU_VRAM_MB", "24576"))
PORT_START       = int(os.environ.get("STROMA_MODEL_PORT_RANGE_START", "8001"))
PORT_END         = int(os.environ.get("STROMA_MODEL_PORT_RANGE_END", "8099"))


# ---------------------------------------------------------------------------
# Internal helpers
# ---------------------------------------------------------------------------

def _estimate_vram_mb(param_count: int, dtype: str) -> int:
    """Estimate total VRAM (MB) needed for inference including overhead."""
    bpp = DTYPE_BYTES.get(dtype, 2.0)
    return int(param_count * bpp * INFERENCE_OVERHEAD / (1024 * 1024))


def _min_gpus(vram_required_mb: int, per_gpu_mb: int) -> int:
    """Minimum GPU count (power-of-two for tensor parallelism)."""
    if per_gpu_mb <= 0 or vram_required_mb <= 0:
        return 1
    n = math.ceil(vram_required_mb / per_gpu_mb)
    if n <= 1:
        return 1
    # TP must be power-of-two
    tp = 1
    while tp < n:
        tp *= 2
    return min(tp, 16)


def _detect_quantization(model_dir: Path, config: dict) -> str:
    """
    Detect quantization type from:
      1. quant_config.json / quantize_config.json in model dir
      2. quantization_config in config.json
      3. Directory name conventions (-AWQ, -GPTQ)
    """
    # Check for AWQ config file
    for name in ("quant_config.json", "quantize_config.json"):
        qpath = model_dir / name
        if qpath.exists():
            try:
                qcfg = json.loads(qpath.read_text())
                quant_method = qcfg.get("quant_method", "").lower()
                if quant_method in ("awq", "gptq"):
                    return quant_method
            except (json.JSONDecodeError, OSError):
                pass

    # Check config.json quantization_config
    qcfg = config.get("quantization_config", {})
    if isinstance(qcfg, dict):
        quant_method = qcfg.get("quant_method", "").lower()
        if quant_method in ("awq", "gptq"):
            return quant_method

    # Infer from directory name
    dirname = model_dir.name.lower()
    if "-awq" in dirname or "_awq" in dirname:
        return "awq"
    if "-gptq" in dirname or "_gptq" in dirname:
        return "gptq"

    return "none"


def _detect_dtype(config: dict, quantization: str) -> str:
    """Determine the effective dtype for VRAM calculation."""
    if quantization in ("awq", "gptq"):
        return quantization

    torch_dtype = config.get("torch_dtype", "")
    if torch_dtype in DTYPE_BYTES:
        return torch_dtype

    return "bf16"  # safe default for modern models


def _extract_param_count(config: dict, model_dir: Path) -> int:
    """
    Extract parameter count from:
      1. config.json num_parameters field
      2. safetensors index metadata
      3. Directory name (e.g. "32B", "7B")
    Returns 0 if unknown.
    """
    # Direct field in config.json (some models have this)
    for key in ("num_parameters", "n_params"):
        val = config.get(key)
        if isinstance(val, int) and val > 0:
            return val

    # Safetensors index
    idx_path = model_dir / "model.safetensors.index.json"
    if idx_path.exists():
        try:
            idx = json.loads(idx_path.read_text())
            metadata = idx.get("metadata", {})
            total = metadata.get("total_size")
            if isinstance(total, (int, float)) and total > 0:
                # total_size is in bytes; estimate params assuming fp16 (2 bytes/param)
                return int(total / 2)
        except (json.JSONDecodeError, OSError):
            pass

    # Parse from directory name
    size_re = re.compile(r"(?<![a-zA-Z0-9])(\d+(?:\.\d+)?)\s*([bB])(?![a-zA-Z0-9])")
    for m in size_re.finditer(model_dir.name):
        try:
            value = float(m.group(1))
            if 0.1 <= value <= 1000:  # sanity check
                return int(value * 1_000_000_000)
        except ValueError:
            pass

    return 0


def _extract_max_model_len(config: dict) -> int:
    """Extract maximum context length from config.json."""
    for key in (
        "max_position_embeddings",
        "max_sequence_length",
        "n_positions",
        "seq_length",
        "sliding_window",
    ):
        val = config.get(key)
        if isinstance(val, int) and val > 0:
            return val
    return 4096  # conservative default


def _load_overrides(model_dir: Path) -> dict:
    """Load optional stroma.yaml sidecar for admin overrides."""
    override_path = model_dir / "stroma.yaml"
    if not override_path.exists():
        return {}

    try:
        import yaml  # noqa: PLC0415
        return yaml.safe_load(override_path.read_text()) or {}
    except ImportError:
        log.warning(
            "stroma.yaml found at %s but PyYAML not installed — ignoring overrides",
            override_path,
        )
        return {}
    except Exception as exc:
        log.warning("Failed to parse %s: %s", override_path, exc)
        return {}


def _make_display_name(model_dir: Path) -> str:
    """Generate a human-readable display name from directory structure."""
    # Use org/model format if parent is not the models root
    parent = model_dir.parent.name
    name = model_dir.name
    if parent and parent.lower() not in ("models",):
        return f"{parent}/{name}"
    return name


def _scan_model_dir(model_dir: Path, persistent_model: str = "") -> Optional[ModelEntry]:
    """
    Examine a single directory and return a ModelEntry if it's a valid model.
    Returns None for non-model directories.
    """
    config_path = model_dir / "config.json"
    if not config_path.exists():
        return None

    try:
        config = json.loads(config_path.read_text())
    except (json.JSONDecodeError, OSError) as exc:
        log.warning("Skipping %s — bad config.json: %s", model_dir, exc)
        return None

    if not isinstance(config, dict):
        return None

    # Must look like a model (has model_type or architectures)
    if not config.get("model_type") and not config.get("architectures"):
        return None

    quantization = _detect_quantization(model_dir, config)
    dtype = _detect_dtype(config, quantization)
    param_count = _extract_param_count(config, model_dir)
    max_model_len = _extract_max_model_len(config)

    # Compute VRAM
    if param_count > 0:
        vram_required_mb = _estimate_vram_mb(param_count, dtype)
    else:
        vram_required_mb = 0

    gpu_count = _min_gpus(vram_required_mb, GPU_VRAM_MB) if vram_required_mb > 0 else 1

    # Architecture
    architectures = config.get("architectures", [])
    architecture = architectures[0] if architectures else config.get("model_type", "unknown")

    # Display name
    display_name = _make_display_name(model_dir)
    model_id = model_dir.name

    # Determine tier
    is_persistent = (
        persistent_model
        and (
            model_id == persistent_model
            or model_dir.name == persistent_model
            or str(model_dir) == persistent_model
            or display_name == persistent_model
        )
    )
    tier = ModelTier.PERSISTENT if is_persistent else ModelTier.ON_DEMAND

    # Apply overrides
    overrides = _load_overrides(model_dir)
    if overrides.get("gpu_count"):
        gpu_count = int(overrides["gpu_count"])
    if overrides.get("max_model_len"):
        max_model_len = int(overrides["max_model_len"])
    if overrides.get("quantization"):
        quantization = str(overrides["quantization"])
        dtype = _detect_dtype(config, quantization)
        if param_count > 0:
            vram_required_mb = _estimate_vram_mb(param_count, dtype)
    if overrides.get("display_name"):
        display_name = str(overrides["display_name"])
    if overrides.get("tier"):
        tier_str = str(overrides["tier"]).lower()
        if tier_str == "persistent":
            tier = ModelTier.PERSISTENT
        elif tier_str == "on-demand":
            tier = ModelTier.ON_DEMAND

    return ModelEntry(
        model_id=model_id,
        path=str(model_dir),
        display_name=display_name,
        architecture=architecture,
        param_count=param_count,
        dtype=dtype,
        quantization=quantization,
        vram_required_mb=vram_required_mb,
        gpu_count=gpu_count,
        max_model_len=max_model_len,
        tier=tier,
        status=ModelStatus.AVAILABLE,
    )


# ---------------------------------------------------------------------------
# Registry
# ---------------------------------------------------------------------------

class ModelRegistry:
    """
    Thread-safe model catalog. Scans the filesystem for models and tracks
    their runtime status.

    Usage::

        registry = ModelRegistry()
        registry.scan()
        for model in registry.list_models():
            print(model.model_id, model.status)
    """

    def __init__(
        self,
        models_dir: str = MODELS_DIR,
        persistent_model: str = PERSISTENT_MODEL,
        gpu_vram_mb: int = GPU_VRAM_MB,
        port_start: int = PORT_START,
        port_end: int = PORT_END,
    ) -> None:
        self._models_dir = Path(models_dir)
        self._persistent_model = persistent_model
        self._gpu_vram_mb = gpu_vram_mb
        self._port_start = port_start
        self._port_end = port_end

        self._models: dict[str, ModelEntry] = {}
        self._lock = threading.Lock()
        self._allocated_ports: set[int] = set()
        self._last_scan: float = 0.0

    def scan(self) -> int:
        """
        Scan the models directory and update the catalog.
        Preserves runtime state (status, ports, jobs) for existing models.
        Returns the number of models discovered.
        """
        if not self._models_dir.exists():
            log.warning("Models directory does not exist: %s", self._models_dir)
            return 0

        discovered: dict[str, ModelEntry] = {}

        # Walk up to 2 levels deep: models_dir/org/model/ or models_dir/model/
        for entry in sorted(self._models_dir.iterdir()):
            if not entry.is_dir():
                continue

            # Check if this directory is itself a model
            model = _scan_model_dir(entry, self._persistent_model)
            if model:
                discovered[model.model_id] = model
                continue

            # Check subdirectories (org/model structure)
            for sub in sorted(entry.iterdir()):
                if sub.is_dir():
                    model = _scan_model_dir(sub, self._persistent_model)
                    if model:
                        discovered[model.model_id] = model

        with self._lock:
            # Preserve runtime state for models that still exist on disk
            for model_id, new_entry in discovered.items():
                existing = self._models.get(model_id)
                if existing:
                    new_entry.status = existing.status
                    new_entry.vllm_port = existing.vllm_port
                    new_entry.slurm_job_ids = existing.slurm_job_ids
                    new_entry.error_message = existing.error_message

            # Remove models no longer on disk (but warn about active ones)
            for model_id in list(self._models.keys()):
                if model_id not in discovered:
                    old = self._models[model_id]
                    if old.status in (ModelStatus.SERVING, ModelStatus.PROVISIONING):
                        log.warning(
                            "Model %s removed from disk but still %s — marking error",
                            model_id, old.status.value,
                        )
                    if old.vllm_port:
                        self._allocated_ports.discard(old.vllm_port)

            self._models = discovered
            self._last_scan = time.monotonic()

        log.info(
            "Scan complete: %d model(s) discovered in %s",
            len(discovered), self._models_dir,
        )
        for m in discovered.values():
            gpu_info = f"{m.gpu_count}× GPU" if m.gpu_count > 1 else "1 GPU"
            vram_info = f"{m.vram_required_mb / 1024:.1f}GB" if m.vram_required_mb else "unknown"
            log.info(
                "  %-40s  %s  %s  %s  %s",
                m.display_name, m.quantization or "native", vram_info, gpu_info, m.tier.value,
            )

        return len(discovered)

    # -----------------------------------------------------------------------
    # Queries
    # -----------------------------------------------------------------------

    def list_models(self) -> list[ModelEntry]:
        """Return all models in the catalog."""
        with self._lock:
            return list(self._models.values())

    def get_model(self, model_id: str) -> Optional[ModelEntry]:
        """Look up a model by ID. Also matches by display_name."""
        with self._lock:
            if model_id in self._models:
                return self._models[model_id]
            # Fallback: match by display_name (OWU sends display name)
            for m in self._models.values():
                if m.display_name == model_id:
                    return m
                # Also match the served-model-name pattern
                if m.model_id.lower() == model_id.lower():
                    return m
            return None

    def get_serving_models(self) -> list[ModelEntry]:
        """Return only models currently serving."""
        with self._lock:
            return [m for m in self._models.values() if m.status == ModelStatus.SERVING]

    def get_persistent_model(self) -> Optional[ModelEntry]:
        """Return the persistent (always-on) model if configured."""
        with self._lock:
            for m in self._models.values():
                if m.tier == ModelTier.PERSISTENT:
                    return m
            return None

    # -----------------------------------------------------------------------
    # Status management (called by watcher)
    # -----------------------------------------------------------------------

    def update_status(self, model_id: str, status: ModelStatus, **kwargs: object) -> bool:
        """
        Update a model's runtime status. Returns False if model not found.
        Accepts optional kwargs: vllm_port, slurm_job_ids, error_message.
        """
        with self._lock:
            model = self._models.get(model_id)
            if not model:
                return False

            old_status = model.status
            model.status = status

            if "vllm_port" in kwargs:
                model.vllm_port = kwargs["vllm_port"]  # type: ignore[assignment]
            if "slurm_job_ids" in kwargs:
                model.slurm_job_ids = kwargs["slurm_job_ids"]  # type: ignore[assignment]
            if "error_message" in kwargs:
                model.error_message = kwargs["error_message"]  # type: ignore[assignment]

            if old_status != status:
                log.info(
                    "Model %s: %s → %s",
                    model_id, old_status.value, status.value,
                )
            return True

    # -----------------------------------------------------------------------
    # Port management
    # -----------------------------------------------------------------------

    def allocate_port(self, model_id: str) -> Optional[int]:
        """Assign a free port from the range. Returns None if exhausted."""
        with self._lock:
            model = self._models.get(model_id)
            if not model:
                return None
            if model.vllm_port:
                return model.vllm_port

            for port in range(self._port_start, self._port_end + 1):
                if port not in self._allocated_ports:
                    self._allocated_ports.add(port)
                    model.vllm_port = port
                    return port

            log.error("Port range exhausted (%d-%d)", self._port_start, self._port_end)
            return None

    def release_port(self, model_id: str) -> None:
        """Release a model's allocated port back to the pool."""
        with self._lock:
            model = self._models.get(model_id)
            if model and model.vllm_port:
                self._allocated_ports.discard(model.vllm_port)
                model.vllm_port = None

    # -----------------------------------------------------------------------
    # OpenAI-compatible catalog
    # -----------------------------------------------------------------------

    def openai_models_response(self) -> dict:
        """Return the full catalog in OpenAI /v1/models format."""
        models = self.list_models()
        return {
            "object": "list",
            "data": [m.to_openai_model() for m in models],
        }
