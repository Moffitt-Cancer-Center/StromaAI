"""
Unit tests for ModelRegistry (src/model_registry.py).

Tests model discovery from a mock filesystem, metadata inference,
VRAM estimation, port allocation, and OpenAI-compatible catalog output.
"""

from __future__ import annotations

import json
import os
import sys
import tempfile
from pathlib import Path

import pytest

# Add src/ to path so we can import model_registry without installing it
sys.path.insert(0, str(Path(__file__).parent.parent.parent / "src"))

from model_registry import (
    DTYPE_BYTES,
    INFERENCE_OVERHEAD,
    ModelEntry,
    ModelRegistry,
    ModelStatus,
    ModelTier,
    _detect_dtype,
    _detect_quantization,
    _estimate_vram_mb,
    _extract_param_count,
    _min_gpus,
)


# ---------------------------------------------------------------------------
# Fixtures: temporary "models" directory with realistic model layouts
# ---------------------------------------------------------------------------

@pytest.fixture()
def models_dir(tmp_path):
    """Create a temp directory with two model subdirectories."""
    # Model 1: quantised AWQ model (small — 7B)
    m1 = tmp_path / "Qwen2.5-Coder-7B-Instruct-AWQ"
    m1.mkdir()
    (m1 / "config.json").write_text(json.dumps({
        "architectures": ["Qwen2ForCausalLM"],
        "torch_dtype": "float16",
        "max_position_embeddings": 32768,
    }))
    (m1 / "quant_config.json").write_text(json.dumps({
        "quant_method": "awq",
        "bits": 4,
    }))
    # Fake safetensors index for param count
    (m1 / "model.safetensors.index.json").write_text(json.dumps({
        "metadata": {"total_size": 7_000_000_000 * 2},
    }))

    # Model 2: bf16 model (larger — 70B)
    m2 = tmp_path / "Llama-3.1-70B-Instruct"
    m2.mkdir()
    (m2 / "config.json").write_text(json.dumps({
        "architectures": ["LlamaForCausalLM"],
        "torch_dtype": "bfloat16",
        "max_position_embeddings": 131072,
    }))
    (m2 / "model.safetensors.index.json").write_text(json.dumps({
        "metadata": {"total_size": 70_000_000_000 * 2},
    }))

    # Not a model: empty directory
    (tmp_path / "not-a-model").mkdir()

    return tmp_path


@pytest.fixture()
def registry(models_dir, monkeypatch):
    """ModelRegistry pointed at the temp models_dir."""
    reg = ModelRegistry(
        models_dir=str(models_dir),
        persistent_model="Qwen2.5-Coder-7B-Instruct-AWQ",
        gpu_vram_mb=24576,
        port_start=8001,
        port_end=8010,
    )
    return reg


# ---------------------------------------------------------------------------
# Discovery
# ---------------------------------------------------------------------------

class TestDiscovery:

    def test_scan_finds_models(self, registry):
        count = registry.scan()
        assert count == 2

    def test_scan_ignores_non_model_dirs(self, registry):
        registry.scan()
        models = registry.list_models()
        ids = [m.model_id for m in models]
        assert "not-a-model" not in ids

    def test_list_models_returns_entries(self, registry):
        registry.scan()
        models = registry.list_models()
        assert len(models) == 2
        assert all(isinstance(m, ModelEntry) for m in models)

    def test_get_model_by_id(self, registry):
        registry.scan()
        m = registry.get_model("Qwen2.5-Coder-7B-Instruct-AWQ")
        assert m is not None
        assert m.model_id == "Qwen2.5-Coder-7B-Instruct-AWQ"

    def test_get_model_unknown_returns_none(self, registry):
        registry.scan()
        assert registry.get_model("nonexistent-model") is None


# ---------------------------------------------------------------------------
# Metadata inference
# ---------------------------------------------------------------------------

class TestMetadata:

    def test_architecture_detected(self, registry):
        registry.scan()
        qwen = registry.get_model("Qwen2.5-Coder-7B-Instruct-AWQ")
        assert qwen.architecture == "Qwen2ForCausalLM"

    def test_quantization_detected(self, registry):
        registry.scan()
        qwen = registry.get_model("Qwen2.5-Coder-7B-Instruct-AWQ")
        assert qwen.quantization == "awq"

    def test_no_quantization_for_bf16(self, registry):
        registry.scan()
        llama = registry.get_model("Llama-3.1-70B-Instruct")
        assert llama.quantization == "none"

    def test_max_model_len_extracted(self, registry):
        registry.scan()
        qwen = registry.get_model("Qwen2.5-Coder-7B-Instruct-AWQ")
        assert qwen.max_model_len == 32768


# ---------------------------------------------------------------------------
# Tier assignment
# ---------------------------------------------------------------------------

class TestTiers:

    def test_persistent_model_identified(self, registry):
        registry.scan()
        qwen = registry.get_model("Qwen2.5-Coder-7B-Instruct-AWQ")
        assert qwen.tier == ModelTier.PERSISTENT

    def test_other_models_are_on_demand(self, registry):
        registry.scan()
        llama = registry.get_model("Llama-3.1-70B-Instruct")
        assert llama.tier == ModelTier.ON_DEMAND

    def test_get_persistent_model(self, registry):
        registry.scan()
        p = registry.get_persistent_model()
        assert p is not None
        assert p.model_id == "Qwen2.5-Coder-7B-Instruct-AWQ"


# ---------------------------------------------------------------------------
# VRAM estimation helpers
# ---------------------------------------------------------------------------

class TestVRAMEstimation:

    def test_estimate_fp16(self):
        # 7B params @ fp16 (2 bytes) * 1.2 overhead = ~15.6 GB ≈ 16384 MB
        vram = _estimate_vram_mb(7_000_000_000, "fp16")
        assert 14000 < vram < 18000

    def test_estimate_awq(self):
        # 7B params @ awq (0.5 bytes) * 1.2 = ~3.9 GB
        vram = _estimate_vram_mb(7_000_000_000, "awq")
        assert 3000 < vram < 5000

    def test_min_gpus_fits_single(self):
        assert _min_gpus(20000, 24576) == 1

    def test_min_gpus_needs_two(self):
        assert _min_gpus(30000, 24576) == 2

    def test_min_gpus_needs_four(self):
        assert _min_gpus(60000, 24576) == 4

    def test_min_gpus_power_of_two(self):
        # 3 GPUs needed → rounds up to 4 (TP must be power of 2)
        assert _min_gpus(50000, 24576) == 4


# ---------------------------------------------------------------------------
# Status management
# ---------------------------------------------------------------------------

class TestStatusManagement:

    def test_initial_status_is_available(self, registry):
        registry.scan()
        llama = registry.get_model("Llama-3.1-70B-Instruct")
        assert llama.status == ModelStatus.AVAILABLE

    def test_update_status(self, registry):
        registry.scan()
        registry.update_status("Llama-3.1-70B-Instruct", ModelStatus.SERVING, vllm_port=8001)
        llama = registry.get_model("Llama-3.1-70B-Instruct")
        assert llama.status == ModelStatus.SERVING
        assert llama.vllm_port == 8001

    def test_get_serving_models(self, registry):
        registry.scan()
        registry.update_status("Qwen2.5-Coder-7B-Instruct-AWQ", ModelStatus.SERVING, vllm_port=8000)
        serving = registry.get_serving_models()
        assert len(serving) == 1
        assert serving[0].model_id == "Qwen2.5-Coder-7B-Instruct-AWQ"


# ---------------------------------------------------------------------------
# Port allocation
# ---------------------------------------------------------------------------

class TestPortAllocation:

    def test_allocate_port(self, registry):
        registry.scan()
        port = registry.allocate_port("Llama-3.1-70B-Instruct")
        assert 8001 <= port <= 8010

    def test_release_port(self, registry):
        registry.scan()
        port = registry.allocate_port("Llama-3.1-70B-Instruct")
        registry.release_port("Llama-3.1-70B-Instruct")
        # Port should be available again
        port2 = registry.allocate_port("Llama-3.1-70B-Instruct")
        assert port2 is not None

    def test_port_exhaustion_returns_none(self, registry, monkeypatch):
        """With a range of 10 ports, allocating 10 should exhaust them."""
        registry.scan()
        for i in range(10):
            registry.allocate_port(f"model-{i}")
        port = registry.allocate_port("overflow")
        assert port is None


# ---------------------------------------------------------------------------
# OpenAI-compatible output
# ---------------------------------------------------------------------------

class TestOpenAICompat:

    def test_openai_models_response_structure(self, registry):
        registry.scan()
        resp = registry.openai_models_response()
        assert resp["object"] == "list"
        assert len(resp["data"]) == 2

    def test_model_entry_to_openai(self, registry):
        registry.scan()
        qwen = registry.get_model("Qwen2.5-Coder-7B-Instruct-AWQ")
        obj = qwen.to_openai_model()
        assert obj["id"] == "Qwen2.5-Coder-7B-Instruct-AWQ"
        assert obj["object"] == "model"
        assert obj["owned_by"] == "stroma-ai"
        assert obj["meta"]["tier"] == "persistent"
        assert obj["meta"]["quantization"] == "awq"


# ---------------------------------------------------------------------------
# Quantization detection helper
# ---------------------------------------------------------------------------

class TestDetectQuantization:

    def test_from_quant_config(self, tmp_path):
        (tmp_path / "quant_config.json").write_text(json.dumps({
            "quant_method": "awq",
        }))
        assert _detect_quantization(tmp_path, {}) == "awq"

    def test_from_config_json(self, tmp_path):
        config = {"quantization_config": {"quant_method": "gptq"}}
        assert _detect_quantization(tmp_path, config) == "gptq"

    def test_from_dirname_awq(self, tmp_path):
        model_dir = tmp_path / "SomeModel-AWQ"
        model_dir.mkdir()
        assert _detect_quantization(model_dir, {}) == "awq"

    def test_no_quantization(self, tmp_path):
        assert _detect_quantization(tmp_path, {}) == "none"
