#!/usr/bin/env bash
# =============================================================================
# StromaAI — Client Connectivity Check
# =============================================================================
# Verifies that a researcher workstation (or CI runner) can reach all
# externally-facing StromaAI services through the nginx TLS reverse proxy.
#
# Unlike smoke-test.sh (which runs on the head node and tests internal URLs),
# this script tests ONLY the public HTTPS endpoint and authenticates with a
# real user token — exactly as a client tool (Kilo Code, openai SDK) would.
#
# Requirements on the workstation:
#   - curl, python3
#   - Network access to the StromaAI head node on port 443 (HTTPS)
#   - A StromaAI / Keycloak username and password
#
# Usage:
#   scripts/client-check.sh                          # auto-detect config.env
#   scripts/client-check.sh --config=~/client.env    # explicit config
#   scripts/client-check.sh --host=hpctpa3pc0070.moffitt.org --user=jdoe
#   scripts/client-check.sh --host=... --user=... --password=...
#   scripts/client-check.sh --help
#
# Options:
#   --config=FILE    Path to client.env or config.env
#   --host=HOST      StromaAI FQDN (overrides OPENAI_BASE_URL / STROMA_HOST)
#   --user=USER      Keycloak username (prompts if omitted)
#   --password=PW    Keycloak password (prompts if omitted)
#   --no-color       Disable ANSI color output
#   -h | --help      Show this message
#
# Tests:
#   1. HTTPS reachability  (GET /health → {"status":"ok"})
#   2. TLS certificate     (cert valid, not expired, matches hostname)
#   3. OIDC discovery      (GET /realms/stroma-ai/.well-known/openid-configuration)
#   4. User authentication (password grant → access_token)
#   5. Token claims        (issuer, audience, stroma_researcher role)
#   6. Authenticated API   (GET /v1/models with Bearer token)
#   7. OpenWebUI portal    (GET / → HTML login page)
#   8. KC console          (GET /admin → redirect to console)
#
# Exit codes:
#   0  All tests passed (or only optional tests skipped)
#   1  One or more required tests failed
# =============================================================================

set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ---------------------------------------------------------------------------
# Color setup
# ---------------------------------------------------------------------------
if [[ -t 1 && "${NO_COLOR:-}" == "" ]]; then
    RED='\033[0;31m'; YELLOW='\033[1;33m'; GREEN='\033[0;32m'
    CYAN='\033[0;36m'; BOLD='\033[1m'; DIM='\033[2m'; RESET='\033[0m'
else
    RED='' YELLOW='' GREEN='' CYAN='' BOLD='' DIM='' RESET=''
fi

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
CONFIG_FILE=""
HOST_OVERRIDE=""
USER_OVERRIDE=""
PASS_OVERRIDE=""

for _arg in "$@"; do
    case "${_arg}" in
        --config=*)   CONFIG_FILE="${_arg#--config=}" ;;
        --host=*)     HOST_OVERRIDE="${_arg#--host=}" ;;
        --user=*)     USER_OVERRIDE="${_arg#--user=}" ;;
        --password=*) PASS_OVERRIDE="${_arg#--password=}" ;;
        --no-color)   RED='' YELLOW='' GREEN='' CYAN='' BOLD='' DIM='' RESET='' ;;
        -h|--help)
            sed -n '2,/^# ===.*$/{ s/^# \{0,2\}//; p }' "$0" | head -50
            exit 0
            ;;
        *) echo "Unknown argument: ${_arg}. Use --help for usage." >&2; exit 1 ;;
    esac
done
unset _arg

# ---------------------------------------------------------------------------
# Locate and source config
# ---------------------------------------------------------------------------
if [[ -z "${CONFIG_FILE}" ]]; then
    for _p in \
        "${STROMA_INSTALL_DIR:+${STROMA_INSTALL_DIR}/client.env}" \
        "${HOME}/client.env" \
        "${HOME}/stroma-ai/client.env" \
        "${STROMA_INSTALL_DIR:+${STROMA_INSTALL_DIR}/config.env}" \
        "/cm/shared/apps/stroma-ai/config.env" \
        "/opt/stroma-ai/config.env"
    do
        [[ -z "${_p}" ]] && continue
        if [[ -f "${_p}" ]]; then CONFIG_FILE="${_p}"; break; fi
    done
fi

if [[ -n "${CONFIG_FILE}" && -f "${CONFIG_FILE}" ]]; then
    # shellcheck source=/dev/null
    source "${CONFIG_FILE}" 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# Resolve host
# Precedence: --host= > STROMA_HOST > extract from OPENAI_BASE_URL > STROMA_HEAD_HOST
# ---------------------------------------------------------------------------
if [[ -n "${HOST_OVERRIDE}" ]]; then
    STROMA_HOST="${HOST_OVERRIDE}"
elif [[ -z "${STROMA_HOST:-}" ]]; then
    if [[ -n "${OPENAI_BASE_URL:-}" ]]; then
        _tmp="${OPENAI_BASE_URL#https://}"; _tmp="${_tmp#http://}"
        STROMA_HOST="${_tmp%%/*}"; STROMA_HOST="${STROMA_HOST%%:*}"
    elif [[ -n "${STROMA_HEAD_HOST:-}" ]]; then
        STROMA_HOST="${STROMA_HEAD_HOST}"
    fi
fi

# KC realm path
KC_REALM_PATH="/realms/stroma-ai"
KC_TOKEN_URL="https://${STROMA_HOST}${KC_REALM_PATH}/protocol/openid-connect/token"
KC_DISCOVERY_URL="https://${STROMA_HOST}${KC_REALM_PATH}/.well-known/openid-configuration"
KC_CONSOLE_URL="https://${STROMA_HOST}/admin"

# OIDC client for ROPC login — stroma-cli is the designated public client
KC_CLIENT="${KC_CLIENT:-stroma-cli}"

# ---------------------------------------------------------------------------
# Pre-flight: require tools
# ---------------------------------------------------------------------------
for _cmd in curl python3; do
    command -v "${_cmd}" &>/dev/null || { echo "ERROR: ${_cmd} not found." >&2; exit 1; }
done

# ---------------------------------------------------------------------------
# Test harness
# ---------------------------------------------------------------------------
PASS=0; FAIL=0; SKIP=0

result() {
    local status="$1" desc="$2" detail="${3:-}"
    case "${status}" in
        PASS) PASS=$((PASS+1)); echo -e "  ${GREEN}PASS${RESET}  ${desc}${detail:+  ${DIM}(${detail})${RESET}}" ;;
        FAIL) FAIL=$((FAIL+1)); echo -e "  ${RED}FAIL${RESET}  ${desc}${detail:+  ${RED}${detail}${RESET}}" ;;
        SKIP) SKIP=$((SKIP+1)); echo -e "  ${YELLOW}SKIP${RESET}  ${desc}${detail:+  ${DIM}${detail}${RESET}}" ;;
    esac
}

http_get()    { curl -sk --max-time 15 "$@" 2>/dev/null || true; }
http_status() { local url="$1"; shift; curl -sk --max-time 15 -o /dev/null -w "%{http_code}" "$@" "${url}" 2>/dev/null || echo "000"; }
json_field()  {
    python3 -c "
import sys, json
try:
    d = json.loads(sys.argv[1])
    for k in sys.argv[2].split('.'):
        d = d[int(k)] if isinstance(d, list) else d[k]
    print(d)
except Exception:
    pass
" "$1" "$2" 2>/dev/null || true
}

hr() { printf "${DIM}%.0s─${RESET}" {1..62}; echo; }

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------
echo
echo -e "${BOLD}╔══════════════════════════════════════════════════════════════╗${RESET}"
printf  "${BOLD}║   StromaAI Client Connectivity Check  —  %-20s║${RESET}\n" "$(date '+%Y-%m-%d %H:%M %Z')"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${RESET}"
echo
echo -e "  ${CYAN}Host${RESET}     : ${STROMA_HOST:-${RED}(not set — use --host=)${RESET}}"
echo -e "  ${CYAN}Config${RESET}   : ${CONFIG_FILE:-(none)}"
echo -e "  ${CYAN}Client${RESET}   : ${KC_CLIENT}"
echo

if [[ -z "${STROMA_HOST:-}" ]]; then
    echo -e "${RED}ERROR: StromaAI host not set.${RESET}"
    echo -e "  Pass ${BOLD}--host=<fqdn>${RESET} or set ${BOLD}STROMA_HOST${RESET} / ${BOLD}OPENAI_BASE_URL${RESET} in config."
    exit 1
fi

# ---------------------------------------------------------------------------
# TEST 1 — HTTPS reachability
# ---------------------------------------------------------------------------
hr; echo -e "  ${BOLD}TEST 1${RESET}  HTTPS reachability (port 443)"
_body=$(http_get "https://${STROMA_HOST}/health")
_code=$(http_status "https://${STROMA_HOST}/health")
_status=$(json_field "${_body}" "status")
if [[ "${_status}" == "ok" ]]; then
    result PASS "HTTPS /health" "status=ok"
elif [[ "${_code}" == "000" ]]; then
    result FAIL "HTTPS /health" "connection refused or port 443 blocked — check firewall / VPN"
elif [[ "${_code}" == "502" || "${_code}" == "503" ]]; then
    result FAIL "HTTPS /health" "HTTP ${_code} — nginx is up but backend vLLM not responding"
else
    result FAIL "HTTPS /health" "HTTP ${_code} — unexpected response"
fi

# ---------------------------------------------------------------------------
# TEST 2 — TLS certificate validity
# ---------------------------------------------------------------------------
hr; echo -e "  ${BOLD}TEST 2${RESET}  TLS certificate"
_cert_info=$(curl -sv --max-time 10 "https://${STROMA_HOST}/health" 2>&1 | grep -E "subject:|issuer:|expire|SSL certificate verify" || true)
_tls_code=$(curl -sk --max-time 10 -o /dev/null -w "%{http_code}" \
    --cacert /dev/null "https://${STROMA_HOST}/health" 2>/dev/null || echo "tls_error")
# Use curl without -k to test actual TLS validity
_strict_code=$(curl -s --max-time 10 -o /dev/null -w "%{http_code}" \
    "https://${STROMA_HOST}/health" 2>/dev/null || echo "000")
if [[ "${_strict_code}" == "000" && "${_code}" != "000" ]]; then
    result FAIL "TLS certificate" "cert not trusted by system CA store — self-signed or internal CA not installed"
    echo -e "    ${DIM}Fix: install your institution's CA cert, or ask your admin for the CA bundle${RESET}"
elif [[ "${_code}" == "000" ]]; then
    result SKIP "TLS certificate" "skipped (host unreachable)"
else
    result PASS "TLS certificate" "trusted by system CA store"
fi

# ---------------------------------------------------------------------------
# TEST 3 — OIDC discovery document
# ---------------------------------------------------------------------------
hr; echo -e "  ${BOLD}TEST 3${RESET}  OIDC discovery document"
_disc=$(http_get "${KC_DISCOVERY_URL}")
_issuer=$(json_field "${_disc}" "issuer")
_token_ep=$(json_field "${_disc}" "token_endpoint")
if [[ -n "${_issuer}" && -n "${_token_ep}" ]]; then
    result PASS "OIDC discovery" "issuer=${_issuer}"
elif [[ "${_code}" == "000" ]]; then
    result SKIP "OIDC discovery" "skipped (host unreachable)"
else
    result FAIL "OIDC discovery" "no issuer in response — KC realm not reachable via nginx proxy"
    echo -e "    ${DIM}URL: ${KC_DISCOVERY_URL}${RESET}"
fi

# ---------------------------------------------------------------------------
# TEST 4 — User authentication (ROPC password grant)
# ---------------------------------------------------------------------------
hr; echo -e "  ${BOLD}TEST 4${RESET}  User authentication"
_ACCESS_TOKEN=""

if [[ -z "${_issuer:-}" ]]; then
    result SKIP "User authentication" "skipped (OIDC discovery failed)"
else
    # Prompt for credentials if not provided
    _auth_user="${USER_OVERRIDE:-}"
    _auth_pass="${PASS_OVERRIDE:-}"
    if [[ -z "${_auth_user}" ]]; then
        read -rp "  Username: " _auth_user
    fi
    if [[ -z "${_auth_pass}" ]]; then
        read -rsp "  Password for ${_auth_user}: " _auth_pass; echo
    fi

    _tok_resp=$(curl -sk --max-time 15 \
        -X POST "${KC_TOKEN_URL}" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "client_id=${KC_CLIENT}&grant_type=password&username=${_auth_user}&password=${_auth_pass}" \
        2>/dev/null || true)
    _ACCESS_TOKEN=$(json_field "${_tok_resp}" "access_token")
    _tok_err=$(json_field "${_tok_resp}" "error_description")

    if [[ -n "${_ACCESS_TOKEN}" ]]; then
        result PASS "User authentication" "token obtained for ${_auth_user}"
    else
        result FAIL "User authentication" "${_tok_err:-no token — check username/password}"
        echo -e "    ${DIM}Hint: ensure the user exists in Keycloak and has a password set${RESET}"
    fi
fi

# ---------------------------------------------------------------------------
# TEST 5 — Token claims (issuer, audience, stroma_researcher role)
# ---------------------------------------------------------------------------
hr; echo -e "  ${BOLD}TEST 5${RESET}  Token claims"
if [[ -z "${_ACCESS_TOKEN}" ]]; then
    result SKIP "Token claims" "no token"
else
    _claims=$(python3 -c "
import sys, json, base64
tok = sys.argv[1].split('.')
pad = lambda s: s + '=' * (-len(s) % 4)
try:
    payload = json.loads(base64.urlsafe_b64decode(pad(tok[1])))
    roles = payload.get('realm_access', {}).get('roles', [])
    print(json.dumps({
        'iss': payload.get('iss',''),
        'aud': payload.get('aud',''),
        'researcher': 'stroma_researcher' in roles,
        'sub': payload.get('preferred_username', payload.get('sub','')),
        'exp': payload.get('exp', 0),
    }))
except Exception as e:
    print(json.dumps({'error': str(e)}))
" "${_ACCESS_TOKEN}" 2>/dev/null || echo "{}")

    _tok_iss=$(json_field "${_claims}" "iss")
    _tok_researcher=$(json_field "${_claims}" "researcher")
    _tok_sub=$(json_field "${_claims}" "sub")
    _claim_errors=()

    if [[ "${_tok_researcher}" != "True" ]]; then
        _claim_errors+=("stroma_researcher role missing — contact admin to assign access")
    fi
    if [[ -z "${_tok_iss}" ]]; then
        _claim_errors+=("no issuer in token")
    fi

    if [[ ${#_claim_errors[@]} -eq 0 ]]; then
        result PASS "Token claims" "user=${_tok_sub} role=stroma_researcher iss=${_tok_iss}"
    else
        result FAIL "Token claims" "${_claim_errors[*]}"
    fi
fi

# ---------------------------------------------------------------------------
# TEST 6 — Authenticated API access (GET /v1/models)
# ---------------------------------------------------------------------------
hr; echo -e "  ${BOLD}TEST 6${RESET}  Authenticated API (/v1/models)"
if [[ -z "${_ACCESS_TOKEN}" ]]; then
    result SKIP "API access" "no token"
else
    _models_body=$(http_get "https://${STROMA_HOST}/v1/models" \
        -H "Authorization: Bearer ${_ACCESS_TOKEN}")
    _models_code=$(http_status "https://${STROMA_HOST}/v1/models" \
        -H "Authorization: Bearer ${_ACCESS_TOKEN}")
    _model_id=$(json_field "${_models_body}" "data.0.id")

    if [[ -n "${_model_id}" ]]; then
        result PASS "API access" "model=${_model_id}"
    elif [[ "${_models_code}" == "401" || "${_models_code}" == "403" ]]; then
        result FAIL "API access" "HTTP ${_models_code} — token rejected by gateway (check stroma_researcher role)"
    elif [[ "${_models_code}" == "503" || "${_models_code}" == "502" ]]; then
        result FAIL "API access" "HTTP ${_models_code} — gateway up but vLLM worker not running"
        echo -e "    ${DIM}Hint: no GPU job may be active — check Slurm queue or trigger a request${RESET}"
    elif [[ "${_models_code}" == "000" ]]; then
        result FAIL "API access" "connection failed"
    else
        result FAIL "API access" "HTTP ${_models_code} — ${_models_body:0:120}"
    fi
fi

# ---------------------------------------------------------------------------
# TEST 7 — OpenWebUI portal reachable
# ---------------------------------------------------------------------------
hr; echo -e "  ${BOLD}TEST 7${RESET}  OpenWebUI portal (https://${STROMA_HOST}/)"
_owui_code=$(http_status "https://${STROMA_HOST}/")
_owui_body=$(http_get "https://${STROMA_HOST}/")
# OpenWebUI returns 200 HTML with a <title> tag
if echo "${_owui_body}" | grep -qi "<title>"; then
    result PASS "OpenWebUI portal" "HTML page returned (HTTP ${_owui_code})"
elif [[ "${_owui_code}" == "000" ]]; then
    result FAIL "OpenWebUI portal" "connection failed"
elif [[ "${_owui_code}" == "302" || "${_owui_code}" == "301" ]]; then
    result PASS "OpenWebUI portal" "HTTP ${_owui_code} redirect (login flow)"
else
    result FAIL "OpenWebUI portal" "HTTP ${_owui_code} — unexpected response"
fi

# ---------------------------------------------------------------------------
# TEST 8 — Keycloak admin console reachable
# ---------------------------------------------------------------------------
hr; echo -e "  ${BOLD}TEST 8${RESET}  Keycloak admin console (${KC_CONSOLE_URL})"
_kc_code=$(http_status "${KC_CONSOLE_URL}")
if [[ "${_kc_code}" =~ ^(200|302|303)$ ]]; then
    result PASS "KC admin console" "HTTP ${_kc_code}"
elif [[ "${_kc_code}" == "000" ]]; then
    result FAIL "KC admin console" "connection failed — nginx may not be proxying /admin"
else
    result FAIL "KC admin console" "HTTP ${_kc_code}"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo
hr
_total=$((PASS + FAIL + SKIP))
echo -e "  ${GREEN}${PASS} passed${RESET}  ${RED}${FAIL} failed${RESET}  ${YELLOW}${SKIP} skipped${RESET}  (of ${_total} tests)"
echo
if [[ "${FAIL}" -eq 0 ]]; then
    echo -e "  ${GREEN}${BOLD}All checks passed — this workstation can reach StromaAI.${RESET}"
else
    echo -e "  ${RED}${BOLD}${FAIL} check(s) failed — see hints above.${RESET}"
    echo
    echo -e "  ${BOLD}Common fixes:${RESET}"
    echo -e "  • Test 1/2 fail (000):     You may need VPN or to be on the campus network"
    echo -e "  • Test 2 fail (TLS):       Install the Moffitt CA bundle: sudo trust anchor --store <ca.crt>"
    echo -e "  • Test 3 fail (discovery): nginx not proxying /realms/ — check nginx.conf KC upstream"
    echo -e "  • Test 4 fail (auth):      Wrong username/password, or user not synced from AD yet"
    echo -e "  • Test 5 fail (role):      User lacks stroma_researcher — contact platform admin"
    echo -e "  • Test 6 fail (502/503):   No vLLM worker running — GPU job not active"
    echo -e "  • Test 6 fail (401/403):   stroma_researcher role not in token (see Test 5)"
fi
echo
echo -e "  ${BOLD}Endpoint reference for this host:${RESET}"
echo -e "  ${DIM}API base     :${RESET} https://${STROMA_HOST}/v1"
echo -e "  ${DIM}Models       :${RESET} https://${STROMA_HOST}/v1/models"
echo -e "  ${DIM}Chat         :${RESET} https://${STROMA_HOST}/v1/chat/completions"
echo -e "  ${DIM}OpenWebUI    :${RESET} https://${STROMA_HOST}/"
echo -e "  ${DIM}OIDC token   :${RESET} https://${STROMA_HOST}/realms/stroma-ai/protocol/openid-connect/token"
echo -e "  ${DIM}KC console   :${RESET} https://${STROMA_HOST}/admin/master/console/"
echo
hr

[[ "${FAIL}" -eq 0 ]]; exit $?
