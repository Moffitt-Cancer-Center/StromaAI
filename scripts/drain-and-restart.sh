#!/usr/bin/env bash
# =============================================================================
# StromaAI — Drain and Restart
# =============================================================================
# Gracefully quiesces in-flight inference requests, then restarts all
# StromaAI services in the correct dependency order. Use for planned
# maintenance, container image updates, or any config change that requires
# a full service restart.
#
# Sequence:
#   1. Stop the watcher (prevents new Slurm job submissions)
#   2. Poll vLLM /metrics until all requests drain (or timeout reached)
#   3. Stop stroma-ai-vllm and ray-head
#   4. Start ray-head; wait for it to become active
#   5. Start stroma-ai-vllm; poll /health until 200 (or timeout)
#   6. Start stroma-ai-watcher
#   7. Print final service status
#
# Usage:
#   scripts/drain-and-restart.sh [options]
#
# Options:
#   --drain-timeout <sec>   Max seconds to wait for requests to drain (default: 300)
#   --start-timeout <sec>   Max seconds to wait for vLLM startup (default: 300)
# =============================================================================

set -euo pipefail

CONFIG_FILE="${STROMA_CONFIG:-/opt/stroma-ai/config.env}"
DRAIN_TIMEOUT=300
START_TIMEOUT=300

while [[ $# -gt 0 ]]; do
    case "$1" in
        --drain-timeout) DRAIN_TIMEOUT="$2"; shift 2 ;;
        --start-timeout) START_TIMEOUT="$2"; shift 2 ;;
        -h|--help)
            echo "Usage: $0 [--drain-timeout <sec>] [--start-timeout <sec>]"
            exit 0
            ;;
        *) echo "Unknown argument: $1" >&2; exit 1 ;;
    esac
done

# shellcheck source=/dev/null
[[ -f "${CONFIG_FILE}" ]] && source "${CONFIG_FILE}" || true

HEAD="${STROMA_HEAD_HOST:-localhost}"
VLLM_PORT="${STROMA_VLLM_PORT:-8000}"
API_KEY="${STROMA_API_KEY:-}"
AUTH_HDR=()
[[ -n "${API_KEY}" ]] && AUTH_HDR=(-H "Authorization: Bearer ${API_KEY}")

_running_requests() {
    curl -sf -m 5 "${AUTH_HDR[@]}" "http://${HEAD}:${VLLM_PORT}/metrics" 2>/dev/null \
        | grep '^vllm:num_requests_running ' \
        | awk '{print int($2)}' \
        || echo "0"
}

echo "=== StromaAI Drain and Restart ==="
echo "$(date)"
echo

# ---------------------------------------------------------------------------
# Step 1: Stop watcher
# ---------------------------------------------------------------------------
echo "[1/7] Stopping stroma-ai-watcher ..."
systemctl stop stroma-ai-watcher 2>/dev/null || true
echo "      Done — no new Slurm submissions will be made."

# ---------------------------------------------------------------------------
# Step 2: Drain in-flight requests
# ---------------------------------------------------------------------------
echo "[2/7] Draining in-flight requests (timeout: ${DRAIN_TIMEOUT}s) ..."
ELAPSED=0
while (( ELAPSED < DRAIN_TIMEOUT )); do
    N=$(_running_requests)
    if [[ "${N}" == "0" || -z "${N}" ]]; then
        echo "      Queue empty — proceeding."
        break
    fi
    echo "      ${N} request(s) still running (${ELAPSED}s elapsed) ..."
    sleep 10
    (( ELAPSED += 10 ))
done
if (( ELAPSED >= DRAIN_TIMEOUT )); then
    echo "WARNING: Drain timeout (${DRAIN_TIMEOUT}s) reached. Proceeding anyway." >&2
    echo "         In-flight requests may be interrupted." >&2
fi

# ---------------------------------------------------------------------------
# Step 3: Stop vLLM and Ray
# ---------------------------------------------------------------------------
echo "[3/7] Stopping stroma-ai-vllm and ray-head ..."
systemctl stop stroma-ai-vllm 2>/dev/null || true
sleep 5
systemctl stop ray-head 2>/dev/null || true
echo "      Done."

# ---------------------------------------------------------------------------
# Step 4: Start Ray head
# ---------------------------------------------------------------------------
echo "[4/7] Starting ray-head ..."
systemctl start ray-head
sleep 5
if systemctl is-active --quiet ray-head; then
    echo "      ray-head is active."
else
    echo "ERROR: ray-head failed to start." >&2
    journalctl -u ray-head -n 30 --no-pager >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Step 5: Start vLLM and wait for /health
# ---------------------------------------------------------------------------
echo "[5/7] Starting stroma-ai-vllm (waiting up to ${START_TIMEOUT}s) ..."
systemctl start stroma-ai-vllm
HTTP_CODE="000"
ELAPSED=0
INTERVAL=10
while (( ELAPSED < START_TIMEOUT )); do
    sleep "${INTERVAL}"
    ELAPSED=$(( ELAPSED + INTERVAL ))
    HTTP_CODE=$(curl -sf -o /dev/null -w "%{http_code}" \
        "${AUTH_HDR[@]}" "http://${HEAD}:${VLLM_PORT}/health" 2>/dev/null || echo "000")
    if [[ "${HTTP_CODE}" == "200" ]]; then
        echo "      vLLM /health 200 after ${ELAPSED}s."
        break
    fi
    echo "      Waiting for vLLM ... (HTTP ${HTTP_CODE}) ${ELAPSED}s/${START_TIMEOUT}s"
done
if [[ "${HTTP_CODE}" != "200" ]]; then
    echo "ERROR: vLLM did not become healthy within ${START_TIMEOUT}s." >&2
    journalctl -u stroma-ai-vllm -n 40 --no-pager >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Step 6: Start watcher
# ---------------------------------------------------------------------------
echo "[6/7] Starting stroma-ai-watcher ..."
systemctl start stroma-ai-watcher
sleep 3
if systemctl is-active --quiet stroma-ai-watcher; then
    echo "      stroma-ai-watcher is active."
else
    echo "ERROR: stroma-ai-watcher failed to start." >&2
    journalctl -u stroma-ai-watcher -n 20 --no-pager >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# Step 7: Final verification
# ---------------------------------------------------------------------------
echo "[7/7] Final service status:"
for svc in ray-head stroma-ai-vllm stroma-ai-watcher; do
    state=$(systemctl is-active "${svc}" 2>/dev/null || echo "inactive")
    printf "      %-24s %s\n" "${svc}" "${state}"
done

echo
echo "=== Drain and restart complete ==="
echo "$(date)"
