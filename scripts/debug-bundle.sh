#!/usr/bin/env bash
# =============================================================================
# StromaAI — Debug Bundle Generator
# =============================================================================
# Collects diagnostic information into a timestamped tarball for support.
# STROMA_API_KEY is automatically redacted from all included files.
#
# Usage:
#   scripts/debug-bundle.sh [options] [/path/to/output.tar.gz]
#
# Options:
#   --dry-run              List what would be collected without creating a bundle
#   --output-dir <dir>     Directory for the bundle file (default: /tmp)
#   -h, --help             Show this help message
#
# Default output: /tmp/stroma-ai-debug-<timestamp>.tar.gz
# =============================================================================

set -euo pipefail

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BUNDLE_NAME="stroma-ai-debug-${TIMESTAMP}"
DRY_RUN=false
OUTPUT_DIR="/tmp"
OUTPUT=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --dry-run)       DRY_RUN=true; shift ;;
        --output-dir)    OUTPUT_DIR="$2"; shift 2 ;;
        -h|--help)
            sed -n '/^# Usage:/,/^# ====/p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        -*)  echo "Unknown option: $1" >&2; exit 1 ;;
        *)   OUTPUT="$1"; shift ;;  # positional — backward compatible
    esac
done

BUNDLE_DIR="${OUTPUT_DIR}/${BUNDLE_NAME}"
OUTPUT="${OUTPUT:-${OUTPUT_DIR}/${BUNDLE_NAME}.tar.gz}"

_resolve_config_file() {
    [[ -n "${CONFIG_FILE:-}" ]] && return 0
    local _paths=(
        "${STROMA_INSTALL_DIR:+${STROMA_INSTALL_DIR}/config.env}"
        "/cm/shared/apps/stroma-ai/config.env"
        "/opt/stroma-ai/config.env"
        "/opt/apps/stroma-ai/config.env"
        "/usr/local/stroma-ai/config.env"
        "${HOME}/stroma-ai/config.env"
    )
    local _p
    for _p in "${_paths[@]}"; do
        [[ -z "${_p}" ]] && continue
        if [[ -f "${_p}" ]]; then CONFIG_FILE="${_p}"; return 0; fi
    done
}

CONFIG_FILE="${STROMA_CONFIG:-}"
_resolve_config_file
STATE_FILE="${STROMA_STATE_FILE:-$(dirname "${CONFIG_FILE:-/opt/stroma-ai/config.env}")/state/watcher_state.json}"
SLURM_PARTITION="${STROMA_SLURM_PARTITION:-stroma-ai-gpu}"

# Load config if available (for PARTITION, HEAD_HOST, VLLM_PORT, etc.)
# shellcheck source=/dev/null
[[ -f "${CONFIG_FILE}" ]] && source "${CONFIG_FILE}" || true
SLURM_PARTITION="${STROMA_SLURM_PARTITION:-${SLURM_PARTITION}}"
HEAD="${STROMA_HEAD_HOST:-localhost}"
PORT="${STROMA_VLLM_PORT:-8000}"

if [[ "${DRY_RUN}" == "true" ]]; then
    echo "=== DRY-RUN — would collect ==="
    echo "  System info, kernel, uptime, disk usage"
    echo "  Systemd status for: ray-head, stroma-ai-vllm, stroma-ai-watcher, stroma-ai-model-watcher"
    command -v journalctl &>/dev/null && echo "  Journal logs (last 500 lines per service)"
    [[ -f "${STATE_FILE}" ]] && echo "  Watcher state: ${STATE_FILE}"
    [[ -f "${CONFIG_FILE}" ]] && echo "  Config (API key redacted): ${CONFIG_FILE}"
    command -v squeue &>/dev/null    && echo "  Slurm jobs for partition: ${SLURM_PARTITION}"
    command -v nvidia-smi &>/dev/null && echo "  GPU info (nvidia-smi)"
    command -v ray &>/dev/null        && echo "  Ray status"
    echo "  vLLM health/metrics: http://${HEAD}:${PORT}/"
    echo
    echo "Output: ${OUTPUT}"
    exit 0
fi

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
    echo "Disk     : $(df -h "${STROMA_INSTALL_DIR:-$(dirname "${CONFIG_FILE:-/opt/stroma-ai/config.env}")}" 2>/dev/null || true)"
} > "${BUNDLE_DIR}/system.txt"

# ---------------------------------------------------------------------------
# Systemd service status
# ---------------------------------------------------------------------------
{
    for svc in ray-head stroma-ai-vllm stroma-ai-watcher stroma-ai-model-watcher; do
        echo "=== ${svc} ==="
        systemctl status "${svc}" --no-pager 2>&1 || true
        echo
    done
} > "${BUNDLE_DIR}/service-status.txt"

# ---------------------------------------------------------------------------
# Journal logs (last 500 lines per service)
# ---------------------------------------------------------------------------
if command -v journalctl &>/dev/null; then
    for svc in ray-head stroma-ai-vllm stroma-ai-watcher stroma-ai-model-watcher; do
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
# Model watcher state file
# ---------------------------------------------------------------------------
MODEL_STATE_FILE="${STROMA_MODEL_STATE_FILE:-$(dirname "${CONFIG_FILE:-/opt/stroma-ai/config.env}")/state/model_watcher_state.json}"
if [[ -f "${MODEL_STATE_FILE}" ]]; then
    cp "${MODEL_STATE_FILE}" "${BUNDLE_DIR}/model_watcher_state.json"
fi

# ---------------------------------------------------------------------------
# Config with API key redacted
# ---------------------------------------------------------------------------
if [[ -f "${CONFIG_FILE}" ]]; then
    sed 's/\(STROMA_API_KEY=\).*/\1[REDACTED]/' "${CONFIG_FILE}" \
        > "${BUNDLE_DIR}/config.env.redacted"
fi

# ---------------------------------------------------------------------------
# Slurm jobs
# ---------------------------------------------------------------------------
if command -v squeue &>/dev/null; then
    {
        echo "=== squeue — stroma-ai partition ==="
        squeue -p "${SLURM_PARTITION}" \
            -o "%.18i %.9P %.20j %.8u %.8T %.10M %.9l %.6D %R" 2>&1 || true
        echo
        echo "=== squeue — stroma-ai-burst job name ==="
        squeue --name=stroma-ai-burst \
            -o "%.18i %.9P %.20j %.8u %.8T %.10M %.9l %.6D %R" 2>&1 || true
        echo
        echo "=== squeue — stroma-ai-model job name ==="
        squeue --name=stroma-ai-model \
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
    echo "=== GET /health (persistent vLLM :${PORT}) ==="
    curl -s -m 5 "http://${HEAD}:${PORT}/health" 2>/dev/null || echo "(unreachable)"
    echo
    echo "=== GET /metrics (persistent vLLM, first 150 lines) ==="
    curl -s -m 5 "http://${HEAD}:${PORT}/metrics" 2>/dev/null | head -150 || echo "(unreachable)"
} > "${BUNDLE_DIR}/vllm-endpoints.txt"

# ---------------------------------------------------------------------------
# Model watcher HTTP API
# ---------------------------------------------------------------------------
WATCHER_PORT="${STROMA_WATCHER_PORT:-9100}"
{
    echo "=== GET /status (model-watcher :${WATCHER_PORT}) ==="
    curl -s -m 5 "http://localhost:${WATCHER_PORT}/status" 2>/dev/null || echo "(unreachable)"
} > "${BUNDLE_DIR}/model-watcher-api.txt"

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
