#!/usr/bin/env bash
# =============================================================================
# StromaAI — Slurm Burst Worker Script
# =============================================================================
# Submitted by the Watcher (src/vllm_watcher.py) via sbatch when queue depth
# exceeds the scale-up threshold. Each job starts ONE Ray worker process that
# joins the cluster and contributes its GPU to vLLM inference.
#
# Slurm directives:
#   --nodes=1 --exclusive — entire node dedicated to this single GPU job
#   --cpus-per-task=64    — matches typical HPC GPU node core count; tune per site
#   --mem=900G            — leaves ~100G OS overhead from 1TB; tune per site
#   --time set at submit time by the Watcher (STROMA_SLURM_WALLTIME)
#
# Environment variables passed by Watcher via --export:
#   STROMA_HEAD_HOST  — hostname of Proxmox VM Ray head node
#   STROMA_RAY_PORT   — Ray GCS port (default 6380)
#
# Site customization:
#   Edit the #SBATCH directives below to match your cluster's node shape.
#   Do NOT hardcode STROMA_HEAD_HOST or STROMA_RAY_PORT — the Watcher
#   passes these at submission time so no script edits are needed when the
#   head node hostname changes.
#
# RHEL / SELinux requirements:
#   setsebool -P container_use_cgroups 1
#   setsebool -P container_manage_cgroup 1
#   See docs/rhel-slurm-setup.md
# =============================================================================

#SBATCH --job-name=stroma-ai-burst
#SBATCH --nodes=1
#SBATCH --ntasks=1
#SBATCH --gpus-per-node=1
#SBATCH --exclusive
# NOTE: --output and --error paths are passed by the Watcher via sbatch CLI
# flags using STROMA_LOG_DIR from config.env. The paths below are fallbacks
# for manual sbatch runs only. Run 'mkdir -p ${STROMA_INSTALL_DIR}/logs' on
# the head node before first use, matching your STROMA_LOG_DIR setting.
#SBATCH --output=/opt/stroma-ai/logs/slurm-%j.out
#SBATCH --error=/opt/stroma-ai/logs/slurm-%j.err
# NOTE: --partition, --account, --time, --cpus-per-task, and --mem are all
# passed by the Watcher at submit time via sbatch CLI flags. Do NOT set them
# here to avoid conflicts. Tune STROMA_SLURM_CPUS and STROMA_SLURM_MEM
# in config.env to match your worker node hardware.

set -euo pipefail

# ---------------------------------------------------------------------------
# Required environment — must be set by Watcher via --export
# ---------------------------------------------------------------------------
: "${STROMA_HEAD_HOST:?ERROR: STROMA_HEAD_HOST must be set via --export}"
: "${STROMA_RAY_PORT:=6380}"
: "${STROMA_SHARED_ROOT:=/share}"

# ---------------------------------------------------------------------------
# Container configuration
# ---------------------------------------------------------------------------
STROMA_CONTAINER="${STROMA_CONTAINER:-/share/containers/stroma-ai-vllm.sif}"

# ---------------------------------------------------------------------------
# Load environment modules if available (common in HPC environments)
# Try loading CUDA/NVIDIA drivers if they're module-managed
# ---------------------------------------------------------------------------
if command -v module &>/dev/null; then
    # Try loading CUDA/NVIDIA modules (required for GPU access)
    for mod in cuda nvidia nvidia-driver; do
        if module load "${mod}" &>/dev/null 2>&1; then
            echo "Loaded module: ${mod}"
            break
        fi
    done
fi

# Detect container runtime (apptainer preferred; fall back to singularity)
if [[ -z "${CONTAINER_CMD:-}" ]]; then
    if command -v apptainer &>/dev/null; then
        CONTAINER_CMD="apptainer"
    elif command -v singularity &>/dev/null; then
        CONTAINER_CMD="singularity"
    else
        # Try loading a module — common on HPC systems
        if command -v module &>/dev/null; then
            module load apptainer 2>/dev/null || module load singularity 2>/dev/null || true
        fi
        if command -v apptainer &>/dev/null; then
            CONTAINER_CMD="apptainer"
        elif command -v singularity &>/dev/null; then
            CONTAINER_CMD="singularity"
        else
            echo "ERROR: Neither apptainer nor singularity found in PATH" >&2
            echo "ERROR: If using environment modules, ensure apptainer/singularity module is available" >&2
            exit 1
        fi
    fi
fi

# GPU binding flag: use --nvccli for Apptainer 1.3+ with CDI, else --nv
GPU_FLAG="${STROMA_CONTAINER_GPU_FLAG:---nv}"

# ---------------------------------------------------------------------------
# Verify container image exists
# ---------------------------------------------------------------------------
if [[ ! -f "${STROMA_CONTAINER}" ]]; then
    echo "ERROR: Container image not found: ${STROMA_CONTAINER}" >&2
    echo "Build it with: apptainer build ${STROMA_CONTAINER} deploy/containers/stroma-ai-vllm.def" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Log node context for diagnostics
# ---------------------------------------------------------------------------
echo "=== StromaAI Burst Worker ==="
echo "Node     : $(hostname -f)"
echo "JobID    : ${SLURM_JOB_ID}"
echo "GPUs     : ${SLURM_GPUS_ON_NODE:-1}"
echo "Head     : ${STROMA_HEAD_HOST}:${STROMA_RAY_PORT}"
echo "Container: ${STROMA_CONTAINER}"
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

# ---------------------------------------------------------------------------
# Optional NUMA binding
# Bind the worker process to the NUMA node closest to the GPU for better
# PCIe bandwidth and CPU cache utilization on multi-socket nodes.
# Set STROMA_NUMA_BIND in config.env (e.g., 0). Leave unset to skip.
# Requires numactl to be installed on the compute node.
# ---------------------------------------------------------------------------
NUMACTL_OPTS=()
if [[ -n "${STROMA_NUMA_BIND:-}" ]]; then
    if command -v numactl &>/dev/null; then
        NUMACTL_OPTS=(numactl --cpunodebind="${STROMA_NUMA_BIND}" --membind="${STROMA_NUMA_BIND}")
        echo "NUMA: binding worker to node ${STROMA_NUMA_BIND}"
    else
        echo "WARNING: STROMA_NUMA_BIND=${STROMA_NUMA_BIND} is set but numactl is not installed — skipping" >&2
    fi
fi

exec ${NUMACTL_OPTS[@]:+"${NUMACTL_OPTS[@]}"} "${CONTAINER_CMD}" exec \
    ${GPU_FLAG} \
    --bind "${STROMA_SHARED_ROOT}:${STROMA_SHARED_ROOT}" \
    "${STROMA_CONTAINER}" \
    ray start \
        --address="${STROMA_HEAD_HOST}:${STROMA_RAY_PORT}" \
        --num-cpus="${SLURM_CPUS_PER_TASK:-64}" \
        --num-gpus="${STROMA_GPUS_PER_NODE:-1}" \
        --memory="${NODE_MEMORY_BYTES}" \
        --block
