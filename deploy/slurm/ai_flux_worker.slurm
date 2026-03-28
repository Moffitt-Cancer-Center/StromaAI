#!/usr/bin/env bash
# =============================================================================
# AI_Flux — Slurm Burst Worker Script
# =============================================================================
# Submitted by the Watcher (src/vllm_watcher.py) via sbatch when queue depth
# exceeds the scale-up threshold. Each job starts ONE Ray worker process that
# joins the cluster and contributes its GPU to vLLM inference.
#
# Slurm directives:
#   --nodes=1 --exclusive — entire node dedicated to this single GPU job
#   --cpus-per-task=64    — matches typical L30 node core count; tune per site
#   --mem=900G            — leaves ~100G OS overhead from 1TB; tune per site
#   --time set at submit time by the Watcher (AI_FLUX_SLURM_WALLTIME)
#
# Environment variables passed by Watcher via --export:
#   AI_FLUX_HEAD_HOST  — hostname of Proxmox VM Ray head node
#   AI_FLUX_RAY_PORT   — Ray GCS port (default 6380)
#
# Site customization:
#   Edit the #SBATCH directives below to match your cluster's node shape.
#   Do NOT hardcode AI_FLUX_HEAD_HOST or AI_FLUX_RAY_PORT — the Watcher
#   passes these at submission time so no script edits are needed when the
#   head node hostname changes.
#
# RHEL / SELinux requirements:
#   setsebool -P container_use_cgroups 1
#   setsebool -P container_manage_cgroup 1
#   See docs/rhel-slurm-setup.md
# =============================================================================

#SBATCH --job-name=ai-flux-burst
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --gpus-per-node=1
#SBATCH --cpus-per-task=64
#SBATCH --mem=900G
#SBATCH --exclusive
#SBATCH --output=/shared/logs/ai-flux/slurm-%j.out
#SBATCH --error=/shared/logs/ai-flux/slurm-%j.err
# NOTE: --partition, --account, and --time are passed by the Watcher at
# submit time via sbatch CLI flags. Do NOT set them here to avoid conflicts.

set -euo pipefail

# ---------------------------------------------------------------------------
# Required environment — must be set by Watcher via --export
# ---------------------------------------------------------------------------
: "${AI_FLUX_HEAD_HOST:?ERROR: AI_FLUX_HEAD_HOST must be set via --export}"
: "${AI_FLUX_RAY_PORT:=6380}"

# ---------------------------------------------------------------------------
# Container configuration
# ---------------------------------------------------------------------------
AI_FLUX_CONTAINER="${AI_FLUX_CONTAINER:-/shared/containers/ai-flux-vllm.sif}"

# Detect container runtime (apptainer preferred; fall back to singularity)
if [[ -z "${CONTAINER_CMD:-}" ]]; then
    if command -v apptainer &>/dev/null; then
        CONTAINER_CMD="apptainer"
    elif command -v singularity &>/dev/null; then
        CONTAINER_CMD="singularity"
    else
        # Try loading a module — common on HPC systems
        module load apptainer 2>/dev/null || module load singularity 2>/dev/null || true
        if command -v apptainer &>/dev/null; then
            CONTAINER_CMD="apptainer"
        elif command -v singularity &>/dev/null; then
            CONTAINER_CMD="singularity"
        else
            echo "ERROR: Neither apptainer nor singularity found in PATH" >&2
            exit 1
        fi
    fi
fi

# GPU binding flag: use --nvccli for Apptainer 1.3+ with CDI, else --nv
GPU_FLAG="${AI_FLUX_CONTAINER_GPU_FLAG:---nv}"

# ---------------------------------------------------------------------------
# Verify container image exists
# ---------------------------------------------------------------------------
if [[ ! -f "${AI_FLUX_CONTAINER}" ]]; then
    echo "ERROR: Container image not found: ${AI_FLUX_CONTAINER}" >&2
    echo "Build it with: apptainer build ${AI_FLUX_CONTAINER} deploy/containers/ai-flux-vllm.def" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Log node context for diagnostics
# ---------------------------------------------------------------------------
echo "=== AI_Flux Burst Worker ==="
echo "Node     : $(hostname -f)"
echo "JobID    : ${SLURM_JOB_ID}"
echo "GPUs     : ${SLURM_GPUS_ON_NODE:-1}"
echo "Head     : ${AI_FLUX_HEAD_HOST}:${AI_FLUX_RAY_PORT}"
echo "Container: ${AI_FLUX_CONTAINER}"
echo "Runtime  : ${CONTAINER_CMD}"
nvidia-smi --query-gpu=name,memory.total,driver_version --format=csv,noheader 2>/dev/null || true
echo "============================"

# ---------------------------------------------------------------------------
# Start Ray worker
#
# --num-cpus / --num-gpus / --memory advertise this node's resources to the
# Ray scheduler so vLLM knows what's available.
#
# --block keeps the process alive (and the Slurm job running) for the
# duration of the allocation. When Slurm cancels the job, the container
# process exits, Ray detects the node has left, and vLLM stops sending work.
# ---------------------------------------------------------------------------
NODE_MEMORY_BYTES=$(( (SLURM_MEM_PER_NODE > 0 ? SLURM_MEM_PER_NODE : 900*1024) * 1024 * 1024 ))

exec "${CONTAINER_CMD}" exec \
    ${GPU_FLAG} \
    --bind /shared:/shared \
    "${AI_FLUX_CONTAINER}" \
    ray start \
        --address="${AI_FLUX_HEAD_HOST}:${AI_FLUX_RAY_PORT}" \
        --num-cpus="${SLURM_CPUS_PER_TASK:-64}" \
        --num-gpus=1 \
        --memory="${NODE_MEMORY_BYTES}" \
        --block
