#!/usr/bin/env bash
# =============================================================================
# StromaAI — Configuration Validator
# =============================================================================
# Validates config.env before starting services. Run after install or any
# config change to catch obvious errors before they cause silent failures.
#
# Usage:
#   scripts/check-config.sh [--config /path/to/config.env]
#
# Exit codes:
#   0 = all checks passed (warnings may still be present)
#   1 = one or more errors found
#   2 = config file not found
# =============================================================================

set -euo pipefail

CONFIG_FILE="${AI_FLUX_CONFIG:-/opt/ai-flux/config.env}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --config) CONFIG_FILE="$2"; shift 2 ;;
        -h|--help)
            echo "Usage: $0 [--config /path/to/config.env]"
            exit 0
            ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

if [[ ! -f "${CONFIG_FILE}" ]]; then
    echo "ERROR: Config file not found: ${CONFIG_FILE}" >&2
    echo "       Copy config/config.example.env to ${CONFIG_FILE} and fill in your values." >&2
    exit 2
fi

# shellcheck source=/dev/null
source "${CONFIG_FILE}"

ERRORS=0
WARNINGS=0

_error() { echo "  [ERROR]   $*"; (( ERRORS++ )) || true; }
_warn()  { echo "  [WARN]    $*"; (( WARNINGS++ )) || true; }
_ok()    { echo "  [OK]      $*"; }

echo "=== StromaAI Config Check: ${CONFIG_FILE} ==="
echo

# ---------------------------------------------------------------------------
# Required variables
# ---------------------------------------------------------------------------
echo "--- Required variables ---"
REQUIRED_VARS=(
    AI_FLUX_HEAD_HOST
    AI_FLUX_VLLM_PORT
    AI_FLUX_RAY_PORT
    AI_FLUX_API_KEY
    AI_FLUX_MODEL_PATH
    AI_FLUX_MODEL_NAME
    AI_FLUX_CONTAINER
    AI_FLUX_SLURM_PARTITION
    AI_FLUX_SLURM_ACCOUNT
    AI_FLUX_SLURM_SCRIPT
)
for var in "${REQUIRED_VARS[@]}"; do
    val="${!var:-}"
    if [[ -z "$val" ]]; then
        _error "${var} is not set"
    elif [[ "$val" == CHANGEME* ]]; then
        _error "${var} is still the placeholder value — update before deploying"
    else
        _ok "${var} is set"
    fi
done

# ---------------------------------------------------------------------------
# Hostname / address validation
# ---------------------------------------------------------------------------
echo
echo "--- Hostname ---"
if [[ "${AI_FLUX_HEAD_HOST:-}" =~ ^[a-zA-Z0-9._-]+$ ]]; then
    _ok "AI_FLUX_HEAD_HOST=${AI_FLUX_HEAD_HOST} looks valid"
else
    _error "AI_FLUX_HEAD_HOST='${AI_FLUX_HEAD_HOST:-<unset>}' contains invalid characters"
fi

# ---------------------------------------------------------------------------
# Numeric port validation
# ---------------------------------------------------------------------------
echo
echo "--- Ports ---"
for var in AI_FLUX_VLLM_PORT AI_FLUX_RAY_PORT AI_FLUX_HTTPS_PORT AI_FLUX_RAY_DASHBOARD_PORT; do
    val="${!var:-}"
    if [[ -z "$val" ]]; then
        _warn "${var} not set (optional)"
    elif [[ "$val" =~ ^[0-9]+$ ]] && (( val >= 1 && val <= 65535 )); then
        _ok "${var}=${val}"
    else
        _error "${var}=${val} is not a valid port number (1–65535)"
    fi
done

# ---------------------------------------------------------------------------
# Path existence checks
# ---------------------------------------------------------------------------
echo
echo "--- Paths ---"

if [[ -f "${AI_FLUX_MODEL_PATH:-/nonexistent}" || -d "${AI_FLUX_MODEL_PATH:-/nonexistent}" ]]; then
    _ok "Model path exists: ${AI_FLUX_MODEL_PATH}"
else
    _warn "Model path not found: ${AI_FLUX_MODEL_PATH:-<unset>} (OK if building on a different host)"
fi

if [[ -f "${AI_FLUX_CONTAINER:-/nonexistent}" ]]; then
    _ok "Container image exists: ${AI_FLUX_CONTAINER}"
else
    _warn "Container image not found: ${AI_FLUX_CONTAINER:-<unset>} (build before starting workers)"
fi

if [[ -f "${AI_FLUX_SLURM_SCRIPT:-/nonexistent}" ]]; then
    _ok "Slurm script exists: ${AI_FLUX_SLURM_SCRIPT}"
else
    _warn "Slurm script not found: ${AI_FLUX_SLURM_SCRIPT:-<unset>} (must be on shared storage)"
fi

# ---------------------------------------------------------------------------
# Slurm partition check (only if sinfo is available)
# ---------------------------------------------------------------------------
echo
echo "--- Slurm ---"
if command -v sinfo &>/dev/null 2>&1; then
    if sinfo -p "${AI_FLUX_SLURM_PARTITION:-}" -h &>/dev/null 2>&1; then
        _ok "Partition exists: ${AI_FLUX_SLURM_PARTITION}"
    else
        _error "Slurm partition not found: '${AI_FLUX_SLURM_PARTITION:-<unset>}'"
    fi
    if command -v sacctmgr &>/dev/null 2>&1; then
        if sacctmgr -n show account "${AI_FLUX_SLURM_ACCOUNT:-}" &>/dev/null 2>&1; then
            _ok "Slurm account exists: ${AI_FLUX_SLURM_ACCOUNT}"
        else
            _warn "Could not verify Slurm account: ${AI_FLUX_SLURM_ACCOUNT:-<unset>}"
        fi
    fi
else
    _warn "sinfo not found — skipping Slurm checks (run on the head node to verify)"
fi

# ---------------------------------------------------------------------------
# Scaling parameters
# ---------------------------------------------------------------------------
echo
echo "--- Scaling ---"
max_burst="${AI_FLUX_MAX_BURST_WORKERS:-0}"
if [[ "${max_burst}" =~ ^[0-9]+$ ]] && (( max_burst > 0 )); then
    _ok "AI_FLUX_MAX_BURST_WORKERS=${max_burst}"
else
    _error "AI_FLUX_MAX_BURST_WORKERS must be a positive integer (got '${max_burst}')"
fi

up_thresh="${AI_FLUX_SCALE_UP_THRESHOLD:-0}"
if [[ "${up_thresh}" =~ ^[0-9]+$ ]] && (( up_thresh > 0 )); then
    _ok "AI_FLUX_SCALE_UP_THRESHOLD=${up_thresh}"
else
    _error "AI_FLUX_SCALE_UP_THRESHOLD must be a positive integer (got '${up_thresh}')"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
echo "=============================="
if (( ERRORS > 0 )); then
    echo "RESULT: FAILED — ${ERRORS} error(s), ${WARNINGS} warning(s)"
    echo "        Fix errors before starting StromaAI services."
    exit 1
elif (( WARNINGS > 0 )); then
    echo "RESULT: PASSED with ${WARNINGS} warning(s)"
    echo "        Review warnings before production deployment."
    exit 0
else
    echo "RESULT: PASSED — config looks good"
    exit 0
fi
