#!/usr/bin/env bash
# =============================================================================
# StromaAI — Slurm Model Worker Script
# =============================================================================
# Submitted by the Model Watcher (src/model_watcher.py) when an on-demand
# model is requested.  Starts a vLLM inference server for a SPECIFIC model
# on a dedicated port.
#
# Unlike stroma_ai_worker.slurm (which starts a generic Ray worker), this
# script runs ``vllm serve <MODEL_PATH>`` directly so the model is
# independently addressable by the gateway.
#
# Environment variables passed by Watcher via --export:
#   MODEL_ID              — model identifier (for logging/state)
#   MODEL_PATH            — absolute path to HuggingFace model weights
#   VLLM_PORT             — port for this model's vLLM HTTP server
#   TENSOR_PARALLEL_SIZE  — number of GPUs for tensor parallelism (default: 1)
#   QUANTIZATION          — quantization method (awq, gptq, or empty)
#   MAX_MODEL_LEN         — max context length (0 = auto-detect)
#   STROMA_HEAD_HOST      — head node hostname
#   STROMA_RAY_PORT       — Ray GCS port
#   STROMA_INSTALL_DIR    — install directory
#   STROMA_SHARED_ROOT    — shared filesystem root
#   STROMA_CONTAINER      — path to Apptainer .sif
#   STROMA_CONTAINER_GPU_FLAG — GPU binding flag (--nv or --nvccli)
#
# =============================================================================

#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --exclusive
#SBATCH --time=12:00:00
#SBATCH --output=/tmp/stroma-ai-model-%j.out
#SBATCH --error=/tmp/stroma-ai-model-%j.err

set -euo pipefail

# ---------------------------------------------------------------------------
# Required environment
# ---------------------------------------------------------------------------
: "${MODEL_ID:?ERROR: MODEL_ID must be set via --export}"
: "${MODEL_PATH:?ERROR: MODEL_PATH must be set via --export}"
: "${VLLM_PORT:?ERROR: VLLM_PORT must be set via --export}"
: "${STROMA_HEAD_HOST:?ERROR: STROMA_HEAD_HOST must be set via --export}"
: "${STROMA_RAY_PORT:=6380}"
: "${STROMA_SHARED_ROOT:=/share}"
: "${STROMA_INSTALL_DIR:=/opt/stroma-ai}"
: "${TENSOR_PARALLEL_SIZE:=1}"
: "${QUANTIZATION:=}"
: "${MAX_MODEL_LEN:=0}"

# ---------------------------------------------------------------------------
# Load environment modules if available (HPC)
# ---------------------------------------------------------------------------
if command -v module &>/dev/null; then
    for mod in cuda nvidia nvidia-driver; do
        if module load "${mod}" &>/dev/null 2>&1; then
            echo "Loaded module: ${mod}"
            break
        fi
    done
fi

# ---------------------------------------------------------------------------
# Worker mode detection (same as stroma_ai_worker.slurm)
# ---------------------------------------------------------------------------
STROMA_VENV="${STROMA_INSTALL_DIR}/venv"

if [[ "${STROMA_WORKER_MODE:-auto}" != "container" && -x "${STROMA_VENV}/bin/python3" ]]; then
    WORKER_MODE=venv
    PYTHON="${STROMA_VENV}/bin/python3"
else
    WORKER_MODE=container
    STROMA_CONTAINER="${STROMA_CONTAINER:-/share/containers/stroma-ai-vllm.sif}"

    if [[ -z "${CONTAINER_CMD:-}" ]]; then
        if command -v apptainer &>/dev/null; then
            CONTAINER_CMD="apptainer"
        elif command -v singularity &>/dev/null; then
            CONTAINER_CMD="singularity"
        else
            if command -v module &>/dev/null; then
                module load apptainer 2>/dev/null || module load singularity 2>/dev/null || true
            fi
            if command -v apptainer &>/dev/null; then
                CONTAINER_CMD="apptainer"
            elif command -v singularity &>/dev/null; then
                CONTAINER_CMD="singularity"
            else
                echo "ERROR: Neither apptainer nor singularity found" >&2
                exit 1
            fi
        fi
    fi

    GPU_FLAG="${STROMA_CONTAINER_GPU_FLAG:---nv}"

    if [[ ! -f "${STROMA_CONTAINER}" ]]; then
        echo "ERROR: Container image not found: ${STROMA_CONTAINER}" >&2
        exit 1
    fi
fi

# ---------------------------------------------------------------------------
# Log diagnostic context
# ---------------------------------------------------------------------------
echo "=== StromaAI Model Worker ==="
echo "Model    : ${MODEL_ID}"
echo "Path     : ${MODEL_PATH}"
echo "Port     : ${VLLM_PORT}"
echo "TP Size  : ${TENSOR_PARALLEL_SIZE}"
echo "Quant    : ${QUANTIZATION:-none}"
echo "MaxLen   : ${MAX_MODEL_LEN}"
echo "Node     : $(hostname -f)"
echo "JobID    : ${SLURM_JOB_ID}"
echo "GPUs     : ${SLURM_GPUS_ON_NODE:-${TENSOR_PARALLEL_SIZE}}"
echo "Head     : ${STROMA_HEAD_HOST}:${STROMA_RAY_PORT}"
echo "Mode     : ${WORKER_MODE}"
nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader 2>/dev/null || true
echo "=============================="

# ---------------------------------------------------------------------------
# Build vLLM arguments
# ---------------------------------------------------------------------------
VLLM_ARGS=(
    --model "${MODEL_PATH}"
    --host 0.0.0.0
    --port "${VLLM_PORT}"
    --tensor-parallel-size "${TENSOR_PARALLEL_SIZE}"
    --trust-remote-code
    --disable-log-requests
)

# Add quantization if specified
if [[ -n "${QUANTIZATION}" ]]; then
    VLLM_ARGS+=(--quantization "${QUANTIZATION}")
fi

# Add max model length if specified (0 = auto-detect)
if [[ "${MAX_MODEL_LEN}" -gt 0 ]]; then
    VLLM_ARGS+=(--max-model-len "${MAX_MODEL_LEN}")
fi

# Add API key if set (so the gateway can authenticate)
if [[ -n "${STROMA_API_KEY:-}" ]]; then
    VLLM_ARGS+=(--api-key "${STROMA_API_KEY}")
fi

# Use distributed executor for multi-GPU tensor parallelism
if [[ "${TENSOR_PARALLEL_SIZE}" -gt 1 ]]; then
    VLLM_ARGS+=(--distributed-executor-backend ray)
fi

# ---------------------------------------------------------------------------
# Start vLLM
# ---------------------------------------------------------------------------
echo "Starting vLLM: ${VLLM_ARGS[*]}"

if [[ "${WORKER_MODE}" == "venv" ]]; then
    exec "${PYTHON}" -m vllm.entrypoints.openai.api_server "${VLLM_ARGS[@]}"
else
    exec "${CONTAINER_CMD}" exec \
        ${GPU_FLAG} \
        --bind "${STROMA_SHARED_ROOT}:${STROMA_SHARED_ROOT}" \
        "${STROMA_CONTAINER}" \
        python3 -m vllm.entrypoints.openai.api_server "${VLLM_ARGS[@]}"
fi
