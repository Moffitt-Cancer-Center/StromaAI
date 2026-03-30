#!/usr/bin/env bash
# =============================================================================
# StromaAI — Debug Bundle Generator
# =============================================================================
# Collects diagnostic information into a timestamped tarball for support.
# AI_FLUX_API_KEY is automatically redacted from all included files.
#
# Usage:
#   scripts/debug-bundle.sh [/path/to/output.tar.gz]
#
# Default output: /tmp/ai-flux-debug-<timestamp>.tar.gz
# =============================================================================

set -euo pipefail

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BUNDLE_NAME="ai-flux-debug-${TIMESTAMP}"
BUNDLE_DIR="/tmp/${BUNDLE_NAME}"
OUTPUT="${1:-/tmp/${BUNDLE_NAME}.tar.gz}"

CONFIG_FILE="${AI_FLUX_CONFIG:-/opt/ai-flux/config.env}"
STATE_FILE="${AI_FLUX_STATE_FILE:-/opt/ai-flux/watcher_state.json}"
SLURM_PARTITION="${AI_FLUX_SLURM_PARTITION:-ai-flux-gpu}"

# Load config if available (for PARTITION, HEAD_HOST, VLLM_PORT, etc.)
# shellcheck source=/dev/null
[[ -f "${CONFIG_FILE}" ]] && source "${CONFIG_FILE}" || true
SLURM_PARTITION="${AI_FLUX_SLURM_PARTITION:-${SLURM_PARTITION}}"
HEAD="${AI_FLUX_HEAD_HOST:-localhost}"
PORT="${AI_FLUX_VLLM_PORT:-8000}"

echo "=== StromaAI Debug Bundle ==="
echo "Collecting diagnostics..."
mkdir -p "${BUNDLE_DIR}"

# ---------------------------------------------------------------------------
# System info
# ---------------------------------------------------------------------------
{
    echo "=== System ==="
    echo "Date     : $(date)"
    echo "Hostname : $(hostname -f 2>/dev/null || hostname)"
    echo "Kernel   : $(uname -r)"
    echo "OS       : $(grep PRETTY_NAME /etc/os-release 2>/dev/null | cut -d= -f2 | tr -d '"' || echo 'unknown')"
    echo "Uptime   : $(uptime)"
    echo "Disk     : $(df -h /opt/ai-flux 2>/dev/null || true)"
} > "${BUNDLE_DIR}/system.txt"

# ---------------------------------------------------------------------------
# Systemd service status
# ---------------------------------------------------------------------------
{
    for svc in ray-head ai-flux-vllm ai-flux-watcher; do
        echo "=== ${svc} ==="
        systemctl status "${svc}" --no-pager 2>&1 || true
        echo
    done
} > "${BUNDLE_DIR}/service-status.txt"

# ---------------------------------------------------------------------------
# Journal logs (last 500 lines per service)
# ---------------------------------------------------------------------------
if command -v journalctl &>/dev/null; then
    for svc in ray-head ai-flux-vllm ai-flux-watcher; do
        journalctl -u "${svc}" -n 500 --no-pager --output=short-iso \
            > "${BUNDLE_DIR}/journal-${svc}.txt" 2>&1 || true
    done
fi

# ---------------------------------------------------------------------------
# Watcher state file
# ---------------------------------------------------------------------------
if [[ -f "${STATE_FILE}" ]]; then
    cp "${STATE_FILE}" "${BUNDLE_DIR}/watcher_state.json"
fi

# ---------------------------------------------------------------------------
# Config with API key redacted
# ---------------------------------------------------------------------------
if [[ -f "${CONFIG_FILE}" ]]; then
    sed 's/\(AI_FLUX_API_KEY=\).*/\1[REDACTED]/' "${CONFIG_FILE}" \
        > "${BUNDLE_DIR}/config.env.redacted"
fi

# ---------------------------------------------------------------------------
# Slurm jobs
# ---------------------------------------------------------------------------
if command -v squeue &>/dev/null; then
    {
        echo "=== squeue — ai-flux partition ==="
        squeue -p "${SLURM_PARTITION}" \
            -o "%.18i %.9P %.20j %.8u %.8T %.10M %.9l %.6D %R" 2>&1 || true
        echo
        echo "=== squeue — ai-flux-burst job name ==="
        squeue --name=ai-flux-burst \
            -o "%.18i %.9P %.20j %.8u %.8T %.10M %.9l %.6D %R" 2>&1 || true
    } > "${BUNDLE_DIR}/slurm-jobs.txt"
fi

# ---------------------------------------------------------------------------
# GPU info (head node)
# ---------------------------------------------------------------------------
if command -v nvidia-smi &>/dev/null; then
    nvidia-smi > "${BUNDLE_DIR}/nvidia-smi.txt" 2>&1 || true
    nvidia-smi \
        --query-gpu=index,name,driver_version,memory.total,memory.used,utilization.gpu,temperature.gpu \
        --format=csv > "${BUNDLE_DIR}/nvidia-smi-query.csv" 2>&1 || true
fi

# ---------------------------------------------------------------------------
# Ray status
# ---------------------------------------------------------------------------
if command -v ray &>/dev/null; then
    ray status > "${BUNDLE_DIR}/ray-status.txt" 2>&1 || true
fi

# ---------------------------------------------------------------------------
# vLLM health and metrics
# ---------------------------------------------------------------------------
{
    echo "=== GET /health ==="
    curl -s -m 5 "http://${HEAD}:${PORT}/health" 2>/dev/null || echo "(unreachable)"
    echo
    echo "=== GET /metrics (first 150 lines) ==="
    curl -s -m 5 "http://${HEAD}:${PORT}/metrics" 2>/dev/null | head -150 || echo "(unreachable)"
} > "${BUNDLE_DIR}/vllm-endpoints.txt"

# ---------------------------------------------------------------------------
# Create tarball and clean up staging directory
# ---------------------------------------------------------------------------
tar -czf "${OUTPUT}" -C /tmp "${BUNDLE_NAME}"
rm -rf "${BUNDLE_DIR}"

echo
echo "Bundle : ${OUTPUT}"
echo "Size   : $(du -sh "${OUTPUT}" | cut -f1)"
echo
echo "IMPORTANT: Review the bundle before sharing."
echo "           API keys are redacted from config.env but may appear in logs."
