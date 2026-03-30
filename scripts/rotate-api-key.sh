#!/usr/bin/env bash
# =============================================================================
# StromaAI — API Key Rotation
# =============================================================================
# Generates a new bearer token, updates config.env (and OOD conf if present),
# then restarts services in the correct dependency order and verifies health.
#
# Usage:
#   scripts/rotate-api-key.sh [--config /path/to/config.env] [--dry-run]
#
# The old config.env is backed up to config.env.bak.<timestamp> before
# modification so the previous key can be recovered if needed.
#
# Exit codes:
#   0 = rotation successful
#   1 = error (services not restarted, or health check failed)
# =============================================================================

set -euo pipefail

CONFIG_FILE="${STROMA_CONFIG:-/opt/ai-flux/config.env}"
DRY_RUN=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --config)  CONFIG_FILE="$2"; shift 2 ;;
        --dry-run) DRY_RUN=true; shift ;;
        -h|--help)
            echo "Usage: $0 [--config /path/to/config.env] [--dry-run]"
            exit 0
            ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

if [[ ! -f "${CONFIG_FILE}" ]]; then
    echo "ERROR: Config file not found: ${CONFIG_FILE}" >&2
    exit 1
fi

# Load current config
# shellcheck source=/dev/null
source "${CONFIG_FILE}"

HEAD_HOST="${STROMA_HEAD_HOST:-localhost}"
VLLM_PORT="${STROMA_VLLM_PORT:-8000}"
OOD_CONF="${STROMA_OOD_CONF:-}"

echo "=== StromaAI API Key Rotation ==="
echo "Config : ${CONFIG_FILE}"
[[ -n "${OOD_CONF}" && -f "${OOD_CONF}" ]] && echo "OOD    : ${OOD_CONF}"
echo

# Generate new key (32 bytes = 64 hex chars)
NEW_KEY=$(openssl rand -hex 32)
echo "New key: ${NEW_KEY:0:8}…  (first 8 chars shown)"

if [[ "${DRY_RUN}" == true ]]; then
    echo
    echo "DRY RUN — no files modified, no services restarted."
    exit 0
fi

# ---------------------------------------------------------------------------
# Backup and update config.env
# ---------------------------------------------------------------------------
BACKUP="${CONFIG_FILE}.bak.$(date +%Y%m%d_%H%M%S)"
cp "${CONFIG_FILE}" "${BACKUP}"
chmod 640 "${BACKUP}"
echo "Backup : ${BACKUP}"

sed -i "s|^STROMA_API_KEY=.*|STROMA_API_KEY=${NEW_KEY}|" "${CONFIG_FILE}"
echo "Updated: ${CONFIG_FILE}"

# ---------------------------------------------------------------------------
# Update OOD conf if it exists and references the key
# ---------------------------------------------------------------------------
if [[ -n "${OOD_CONF}" && -f "${OOD_CONF}" ]]; then
    if grep -q "^STROMA_API_KEY=" "${OOD_CONF}" 2>/dev/null; then
        OOD_BACKUP="${OOD_CONF}.bak.$(date +%Y%m%d_%H%M%S)"
        cp "${OOD_CONF}" "${OOD_BACKUP}"
        sed -i "s|^STROMA_API_KEY=.*|STROMA_API_KEY=${NEW_KEY}|" "${OOD_CONF}"
        echo "Updated: ${OOD_CONF} (backup: ${OOD_BACKUP})"
    fi
fi

# ---------------------------------------------------------------------------
# Restart services (vLLM before watcher — watcher depends on vLLM health)
# ---------------------------------------------------------------------------
echo
echo "--- Restarting services ---"
systemctl restart ai-flux-vllm
echo "  ai-flux-vllm     restarted"
systemctl restart ai-flux-watcher
echo "  ai-flux-watcher  restarted"

# ---------------------------------------------------------------------------
# Health check with new key (wait up to 120s for vLLM to come back)
# ---------------------------------------------------------------------------
echo
echo "--- Health check (waiting up to 120s) ---"
HTTP_CODE="000"
for i in $(seq 1 24); do
    sleep 5
    HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" \
        -H "Authorization: Bearer ${NEW_KEY}" \
        "http://${HEAD_HOST}:${VLLM_PORT}/health" 2>/dev/null || echo "000")
    if [[ "${HTTP_CODE}" == "200" ]]; then
        echo "  vLLM /health returned 200 after $((i * 5))s — rotation successful"
        break
    fi
    echo "  Waiting... (HTTP ${HTTP_CODE}) attempt ${i}/24"
done

echo
if [[ "${HTTP_CODE}" == "200" ]]; then
    echo "=== Key rotation complete ==="
    echo "Old key backed up to: ${BACKUP}"
    echo "New key is active."
    exit 0
else
    echo "ERROR: vLLM did not respond with 200 within 120s after rotation." >&2
    echo "       Investigate: journalctl -u ai-flux-vllm -n 50" >&2
    echo "       Previous config is backed up at: ${BACKUP}" >&2
    exit 1
fi
