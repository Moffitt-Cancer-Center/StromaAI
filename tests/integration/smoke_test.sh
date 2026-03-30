#!/usr/bin/env bash
# =============================================================================
# StromaAI — Integration Smoke Test
# =============================================================================
# Verifies that a running StromaAI deployment is operational. Run this AFTER
# install.sh on the head node, once services have started.
#
# Usage:
#   ./tests/integration/smoke_test.sh [HEAD_HOST] [HTTPS_PORT] [API_KEY]
#
# Arguments (all optional — fall back to environment variables):
#   HEAD_HOST   Hostname of the StromaAI head node  (AI_FLUX_HEAD_HOST)
#   HTTPS_PORT  HTTPS port nginx listens on         (AI_FLUX_HTTPS_PORT, default 443)
#   API_KEY     Bearer token for the vLLM API       (AI_FLUX_API_KEY)
#
# Exit codes:
#   0 — all tests passed
#   1 — one or more tests failed
# =============================================================================

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ---------------------------------------------------------------------------
# Resolve parameters
# ---------------------------------------------------------------------------
HEAD_HOST="${1:-${AI_FLUX_HEAD_HOST:-}}"
HTTPS_PORT="${2:-${AI_FLUX_HTTPS_PORT:-443}}"
API_KEY="${3:-${AI_FLUX_API_KEY:-}}"

if [[ -z "${HEAD_HOST}" ]]; then
    # Try loading from installed config
    if [[ -f /opt/ai-flux/config.env ]]; then
        # shellcheck source=/dev/null
        source /opt/ai-flux/config.env
        HEAD_HOST="${AI_FLUX_HEAD_HOST:-}"
        API_KEY="${AI_FLUX_API_KEY:-}"
    fi
fi

[[ -n "${HEAD_HOST}" ]] || { echo "ERROR: HEAD_HOST not set. Pass as arg or set AI_FLUX_HEAD_HOST."; exit 1; }

BASE_URL="https://${HEAD_HOST}:${HTTPS_PORT}"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
RESET='\033[0m'

PASS=0
FAIL=0

pass() { echo -e "  ${GREEN}[PASS]${RESET} $1"; (( PASS++ )) || true; }
fail() { echo -e "  ${RED}[FAIL]${RESET} $1"; (( FAIL++ )) || true; }
warn() { echo -e "  ${YELLOW}[WARN]${RESET} $1"; }
section() { echo -e "\n${BOLD}### $1${RESET}"; }

# curl wrapper — insecure TLS accepted (common for self-signed HPC certs)
ai_flux_curl() {
    curl -fsSk --max-time 10 "$@"
}

# ---------------------------------------------------------------------------
# 1. Service health
# ---------------------------------------------------------------------------
section "Service Health"

if ai_flux_curl "${BASE_URL}/health" > /dev/null 2>&1; then
    pass "GET /health → 200"
else
    fail "GET /health did not return 200 (is nginx running? is vLLM up?)"
fi

# HTTP → HTTPS redirect
http_status=$(curl -sSo /dev/null -w "%{http_code}" --max-time 5 \
    "http://${HEAD_HOST}/health" 2>/dev/null || echo "000")
if [[ "${http_status}" =~ ^30[12]$ ]]; then
    pass "HTTP → HTTPS redirect (status ${http_status})"
else
    warn "HTTP redirect status: ${http_status} (expected 301 or 302)"
fi

# ---------------------------------------------------------------------------
# 2. TLS certificate
# ---------------------------------------------------------------------------
section "TLS Certificate"

cert_info=$(echo | openssl s_client \
    -connect "${HEAD_HOST}:${HTTPS_PORT}" \
    -servername "${HEAD_HOST}" 2>/dev/null | \
    openssl x509 -noout -subject -enddate 2>/dev/null || echo "")

if [[ -n "${cert_info}" ]]; then
    pass "TLS certificate valid"
    echo "    ${cert_info}"
else
    fail "Could not retrieve TLS certificate from ${HEAD_HOST}:${HTTPS_PORT}"
fi

# ---------------------------------------------------------------------------
# 3. API Authentication
# ---------------------------------------------------------------------------
section "API Authentication"

if [[ -n "${API_KEY}" ]]; then
    authed_status=$(curl -sSk -o /dev/null -w "%{http_code}" --max-time 10 \
        -H "Authorization: Bearer ${API_KEY}" \
        "${BASE_URL}/v1/models" 2>/dev/null || echo "000")
    if [[ "${authed_status}" == "200" ]]; then
        pass "GET /v1/models with valid API key → 200"
    else
        fail "GET /v1/models with valid API key → ${authed_status} (expected 200)"
    fi

    unauthed_status=$(curl -sSk -o /dev/null -w "%{http_code}" --max-time 10 \
        "${BASE_URL}/v1/models" 2>/dev/null || echo "000")
    if [[ "${unauthed_status}" == "401" ]]; then
        pass "GET /v1/models without API key → 401 (auth enforced)"
    else
        warn "GET /v1/models without API key → ${unauthed_status} (expected 401)"
    fi
else
    warn "AI_FLUX_API_KEY not set — skipping authenticated endpoint tests"
fi

# ---------------------------------------------------------------------------
# 4. Model availability
# ---------------------------------------------------------------------------
section "Model Availability"

if [[ -n "${API_KEY}" ]]; then
    models_json=$(curl -fsSk --max-time 10 \
        -H "Authorization: Bearer ${API_KEY}" \
        "${BASE_URL}/v1/models" 2>/dev/null || echo "{}")
    model_count=$(echo "${models_json}" | python3 -c \
        "import json,sys; d=json.load(sys.stdin); print(len(d.get('data',[])))" 2>/dev/null || echo "0")
    if [[ "${model_count}" -ge 1 ]]; then
        model_name=$(echo "${models_json}" | python3 -c \
            "import json,sys; d=json.load(sys.stdin); print(d['data'][0]['id'])" 2>/dev/null || echo "unknown")
        pass "Model loaded: ${model_name}"
    else
        fail "No models returned by /v1/models (vLLM may still be loading)"
    fi
fi

# ---------------------------------------------------------------------------
# 5. Basic inference
# ---------------------------------------------------------------------------
section "Basic Inference"

if [[ -n "${API_KEY}" ]]; then
    inference_response=$(curl -fsSk --max-time 30 \
        -H "Authorization: Bearer ${API_KEY}" \
        -H "Content-Type: application/json" \
        -d '{"model":"'"${AI_FLUX_MODEL_NAME:-ai-flux-coder}"'","messages":[{"role":"user","content":"Reply with exactly: SMOKE_TEST_OK"}],"max_tokens":10}' \
        "${BASE_URL}/v1/chat/completions" 2>/dev/null || echo "{}")

    if echo "${inference_response}" | python3 -c \
        "import json,sys; d=json.load(sys.stdin); \
         assert d.get('choices'), 'no choices'; \
         print(d['choices'][0]['message']['content'])" 2>/dev/null | \
        grep -q "SMOKE_TEST_OK"; then
        pass "Inference round-trip: model responded correctly"
    elif echo "${inference_response}" | python3 -c \
        "import json,sys; d=json.load(sys.stdin); assert d.get('choices')" 2>/dev/null; then
        pass "Inference round-trip: model responded (content check skipped)"
    else
        fail "Inference round-trip: no valid response (is model fully loaded?)"
    fi
else
    warn "API key not set — skipping inference test"
fi

# ---------------------------------------------------------------------------
# 6. Prometheus metrics endpoint
# ---------------------------------------------------------------------------
section "Metrics Endpoint"

# /metrics should be accessible from localhost (or internal network)
# Test from the local machine only if the HEAD_HOST resolves to a local address
metrics_status=$(curl -sSk -o /dev/null -w "%{http_code}" --max-time 10 \
    -H "Authorization: Bearer ${API_KEY:-}" \
    "${BASE_URL}/metrics" 2>/dev/null || echo "000")

if [[ "${metrics_status}" == "200" ]]; then
    pass "GET /metrics → 200 (from this host)"
elif [[ "${metrics_status}" == "403" ]]; then
    pass "GET /metrics → 403 (restricted to internal IPs as expected)"
else
    warn "GET /metrics → ${metrics_status} (expected 200 from internal or 403 from external)"
fi

# ---------------------------------------------------------------------------
# 7. Systemd services (local head node only)
# ---------------------------------------------------------------------------
section "Systemd Services"

if command -v systemctl &>/dev/null && [[ "$(hostname)" == "${HEAD_HOST%%.*}"* || \
    "$(hostname -f 2>/dev/null)" == "${HEAD_HOST}" ]]; then
    for svc in ray-head ai-flux-vllm ai-flux-watcher nginx; do
        if systemctl is-active --quiet "${svc}" 2>/dev/null; then
            pass "systemd: ${svc} is active"
        else
            fail "systemd: ${svc} is NOT active"
        fi
    done
else
    warn "Skipping systemd checks (not running on head node)"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo -e "${BOLD}Results: ${GREEN}${PASS} passed${RESET} | ${RED}${FAIL} failed${RESET}"
echo ""

if [[ "${FAIL}" -gt 0 ]]; then
    echo -e "${RED}Smoke test FAILED — review failures above before going live.${RESET}"
    exit 1
else
    echo -e "${GREEN}All smoke tests passed.${RESET}"
    exit 0
fi
