#!/usr/bin/env bash
# =============================================================================
# StromaAI — Platform Smoke Test
# =============================================================================
# Verifies all services are reachable and correctly configured from any
# machine with network access to the StromaAI platform.
#
# Runs 13 tests covering:
#   1.  nginx TLS endpoint (head node)
#   2.  vLLM /v1/models via nginx (model loaded check)
#   3.  Keycloak direct HTTP (pod-head container)
#   4.  Keycloak realm via nginx TLS proxy
#   5.  Keycloak admin credentials
#   6.  stroma-ai realm existence
#   7.  OIDC clients registered (stroma-gateway, openwebui)
#   8.  OpenWebUI direct HTTP (pod-head)
#   9.  OpenWebUI via nginx TLS proxy
#   10. Gateway health check (direct)
#   11. OIDC user token (end-to-end KC login)
#   12. Authenticated vLLM inference (full E2E)
#   13. client.env world-readable and populated (user onboarding)
#
# Usage:
#   scripts/smoke-test.sh                        # reads config.env auto-detect
#   scripts/smoke-test.sh --config=/path/to/config.env
#   scripts/smoke-test.sh --head=host --kc=host  # explicit hosts
#   scripts/smoke-test.sh --skip-auth            # skip tests needing KC admin pass
#   scripts/smoke-test.sh --help
#
# Options:
#   --config=FILE       Path to config.env (auto-detected if omitted)
#   --head=HOST         FQDN/IP of the StromaAI head node (nginx + vLLM)
#   --kc=HOST           FQDN/IP of the Keycloak/OpenWebUI host
#   --api-key=KEY       STROMA_API_KEY override
#   --kc-admin-pass=PW  Keycloak admin password (from deploy/keycloak/.env)
#   --skip-auth         Skip tests that require the KC admin password
#   --no-color          Disable ANSI color output
#   -h | --help         Show this message
#
# Exit codes:
#   0  All tests passed
#   1  One or more tests failed
# =============================================================================

# -e is intentionally omitted — a smoke test must run all tests even when
# individual curl/python calls return non-zero.
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
HEAD_HOST=""
KC_HOST=""
API_KEY_OVERRIDE=""
KC_ADMIN_PASS_OVERRIDE=""
SKIP_AUTH=0
for _arg in "$@"; do
    case "${_arg}" in
        --config=*)       CONFIG_FILE="${_arg#--config=}" ;;
        --head=*)         HEAD_HOST="${_arg#--head=}" ;;
        --kc=*)           KC_HOST="${_arg#--kc=}" ;;
        --api-key=*)      API_KEY_OVERRIDE="${_arg#--api-key=}" ;;
        --kc-admin-pass=*) KC_ADMIN_PASS_OVERRIDE="${_arg#--kc-admin-pass=}" ;;
        --skip-auth)      SKIP_AUTH=1 ;;
        --no-color)       RED='' YELLOW='' GREEN='' CYAN='' BOLD='' DIM='' RESET='' ;;
        -h|--help)
            sed -n '2,/^# ===.*$/{ s/^# \{0,2\}//; p }' "$0" | head -40
            exit 0
            ;;
        *) echo "Unknown argument: ${_arg}. Use --help for usage." >&2; exit 1 ;;
    esac
done
unset _arg

# ---------------------------------------------------------------------------
# Locate config.env
# ---------------------------------------------------------------------------
if [[ -z "${CONFIG_FILE}" ]]; then
    for _p in \
        "${STROMA_INSTALL_DIR:+${STROMA_INSTALL_DIR}/config.env}" \
        "/cm/shared/apps/stroma-ai/config.env" \
        "/opt/stroma-ai/config.env" \
        "/opt/apps/stroma-ai/config.env" \
        "${HOME}/stroma-ai/config.env"
    do
        [[ -z "${_p}" ]] && continue
        if [[ -f "${_p}" ]]; then CONFIG_FILE="${_p}"; break; fi
    done
fi

# Source config if found
if [[ -n "${CONFIG_FILE}" && -f "${CONFIG_FILE}" ]]; then
    # shellcheck source=/dev/null
    source "${CONFIG_FILE}"
fi

# ---------------------------------------------------------------------------
# Resolve runtime values (flag > config.env > sensible default)
# ---------------------------------------------------------------------------
HEAD="${HEAD_HOST:-${STROMA_HEAD_HOST:-}}"

# KC host: --kc= flag > extract from KC_INTERNAL_URL > fall back to HEAD
if [[ -n "${KC_HOST:-}" ]]; then
    KC="${KC_HOST}"
elif [[ -n "${KC_INTERNAL_URL:-}" ]]; then
    _kc_tmp="${KC_INTERNAL_URL#http://}"; _kc_tmp="${_kc_tmp#https://}"
    KC="${_kc_tmp%%:*}"; KC="${KC%%/*}"
else
    KC="${STROMA_HEAD_HOST:-}"
fi

# KC port: from KC_INTERNAL_URL if available
if [[ -n "${KC_INTERNAL_URL:-}" ]]; then
    _kc_tmp="${KC_INTERNAL_URL#*://}"
    _kc_port="${_kc_tmp#*:}"; _kc_port="${_kc_port%%/*}"
    KC_PORT="${KC_PORT:-${_kc_port:-8080}}"
else
    KC_PORT="${KC_PORT:-8080}"
fi

# OpenWebUI host: extract from OPENWEBUI_INTERNAL_URL (may differ from KC host)
if [[ -n "${OPENWEBUI_INTERNAL_URL:-}" ]]; then
    _owu_tmp="${OPENWEBUI_INTERNAL_URL#http://}"; _owu_tmp="${_owu_tmp#https://}"
    OWU_HOST="${_owu_tmp%%:*}"; OWU_HOST="${OWU_HOST%%/*}"
    _owu_port="${_owu_tmp#*:}"; _owu_port="${_owu_port%%/*}"
    OWU_PORT="${OPENWEBUI_PORT:-${_owu_port:-3000}}"
else
    OWU_HOST="${KC}"
    OWU_PORT="${OPENWEBUI_PORT:-3000}"
fi

API_KEY="${API_KEY_OVERRIDE:-${STROMA_API_KEY:-}}"
# KC admin password: --kc-admin-pass= > KC_ADMIN_PASSWORD from config.env > deploy/keycloak/.env (later)
KC_ADMIN_PASS="${KC_ADMIN_PASS_OVERRIDE:-${KC_ADMIN_PASSWORD:-}}"
GW_PORT="${GATEWAY_PORT:-9000}"

# ---------------------------------------------------------------------------
# Pre-flight: require basic tools
# ---------------------------------------------------------------------------
for _cmd in curl python3; do
    command -v "${_cmd}" &>/dev/null || { echo "ERROR: ${_cmd} not found." >&2; exit 1; }
done

# ---------------------------------------------------------------------------
# Test harness
# ---------------------------------------------------------------------------
PASS=0; FAIL=0; SKIP=0
_results=()   # accumulated for summary line at the end

result() {
    # Print inline immediately so progress is visible even if the script exits early.
    local status="$1" desc="$2" detail="${3:-}"
    case "${status}" in
        PASS)
            PASS=$((PASS+1))
            echo -e "  ${GREEN}PASS${RESET}  ${desc}${detail:+  ${DIM}(${detail})${RESET}}"
            _results+=("PASS")
            ;;
        FAIL)
            FAIL=$((FAIL+1))
            echo -e "  ${RED}FAIL${RESET}  ${desc}${detail:+  ${RED}${detail}${RESET}}"
            _results+=("FAIL")
            ;;
        SKIP)
            SKIP=$((SKIP+1))
            echo -e "  ${YELLOW}SKIP${RESET}  ${desc}${detail:+  ${DIM}${detail}${RESET}}"
            _results+=("SKIP")
            ;;
    esac
}

# http_get URL [extra curl args...] → body (empty on error; never exits non-zero)
http_get() {
    local url="$1"; shift
    curl -sk --max-time 10 "$@" "${url}" 2>/dev/null || true
}

# http_status URL [extra curl args...] → HTTP status code string ("000" = connection failed)
http_status() {
    local url="$1"; shift
    curl -sk --max-time 10 -o /dev/null -w "%{http_code}" "$@" "${url}" 2>/dev/null || echo "000"
}

# json_field BODY FIELD → value (empty if not found / not JSON)
json_field() {
    python3 -c "
import sys, json
try:
    d = json.loads(sys.argv[1])
    # support nested: 'data.0.id'
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
printf  "${BOLD}║   StromaAI Smoke Test  —  %-35s║${RESET}\n" "$(date '+%Y-%m-%d %H:%M %Z')"
echo -e "${BOLD}╚══════════════════════════════════════════════════════════════╝${RESET}"
echo
if [[ -n "${CONFIG_FILE}" ]]; then
    echo -e "  ${CYAN}Config${RESET}   : ${CONFIG_FILE}"
else
    echo -e "  ${YELLOW}Config${RESET}   : not found — set --config= or STROMA_INSTALL_DIR"
fi
echo -e "  ${CYAN}Head${RESET}     : ${HEAD:-${RED}(not set — use --head=)${RESET}}"
echo -e "  ${CYAN}Keycloak${RESET} : ${KC}:${KC_PORT}"
echo -e "  ${CYAN}OpenWebUI${RESET}: ${OWU_HOST}:${OWU_PORT}"
[[ "${SKIP_AUTH}" -eq 1 ]] && \
    echo -e "  ${YELLOW}Auth tests${RESET}: skipped (--skip-auth)"
echo

if [[ -z "${HEAD}" ]]; then
    echo -e "${RED}ERROR: HEAD host not set. Pass --head=<hostname> or set STROMA_HEAD_HOST in config.env${RESET}" >&2
    exit 1
fi

# ---------------------------------------------------------------------------
# TEST 1 — nginx TLS health endpoint
# ---------------------------------------------------------------------------
hr; echo -e "  ${BOLD}TEST 1${RESET}  nginx TLS health"
body=$(http_get "https://${HEAD}/health")
http_code=$(http_status "https://${HEAD}/health")
status=$(json_field "${body}" "status")
if [[ "${status}" == "ok" ]]; then
    result PASS "nginx TLS /health" "status=ok"
elif [[ "${http_code}" == "000" ]]; then
    result FAIL "nginx TLS /health" "connection failed — nginx down or port 443 blocked on ${HEAD}"
elif [[ "${http_code}" == "502" || "${http_code}" == "503" ]]; then
    result FAIL "nginx TLS /health" "HTTP ${http_code} — nginx up but vLLM backend not responding"
else
    result FAIL "nginx TLS /health" "HTTP ${http_code} — got: ${body:0:100}"
fi

# ---------------------------------------------------------------------------
# TEST 2 — vLLM /v1/models (direct port, API key auth)
# All /v1/ traffic now routes through the OIDC gateway — STROMA_API_KEY is an
# internal secret and is no longer valid over the public HTTPS endpoint.
# Obtain a client_credentials token from Keycloak and use it to test the model
# list endpoint via the gateway, which exercises the full OIDC validation path.
# ---------------------------------------------------------------------------
hr; echo -e "  ${BOLD}TEST 2${RESET}  vLLM /v1/models via gateway (OIDC)"
_t2_secret="${KC_GATEWAY_CLIENT_SECRET:-}"
if [[ -z "${_t2_secret}" ]]; then
    result SKIP "vLLM /v1/models" "KC_GATEWAY_CLIENT_SECRET not in config.env — add it first"
else
    _t2_tbody=$(http_get \
        "http://${KC}:${KC_PORT}/realms/stroma-ai/protocol/openid-connect/token" \
        -X POST \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "grant_type=client_credentials&client_id=stroma-gateway&client_secret=${_t2_secret}")
    _t2_token=$(json_field "${_t2_tbody}" "access_token")
    if [[ -z "${_t2_token}" ]]; then
        _t2_err=$(json_field "${_t2_tbody}" "error_description")
        result FAIL "vLLM /v1/models" "could not get OIDC token: ${_t2_err:-${_t2_tbody:0:80}}"
    else
        body=$(http_get "https://${HEAD}/v1/models" -H "Authorization: Bearer ${_t2_token}")
        model_id=$(json_field "${body}" "data.0.id")
        if [[ -n "${model_id}" ]]; then
            result PASS "vLLM /v1/models" "model=${model_id}"
        else
            result FAIL "vLLM /v1/models" "got: ${body:0:120}"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# TEST 3 — Keycloak direct HTTP (master realm)
# ---------------------------------------------------------------------------
hr; echo -e "  ${BOLD}TEST 3${RESET}  Keycloak direct HTTP (${KC}:${KC_PORT})"
body=$(http_get "http://${KC}:${KC_PORT}/realms/master/.well-known/openid-configuration")
issuer=$(json_field "${body}" "issuer")
if [[ -n "${issuer}" ]]; then
    result PASS "Keycloak direct HTTP" "issuer=${issuer}"
else
    result FAIL "Keycloak direct HTTP" "no JSON or unreachable — got: ${body:0:80}"
fi

# ---------------------------------------------------------------------------
# TEST 4 — Keycloak stroma-ai realm via nginx TLS
# ---------------------------------------------------------------------------
hr; echo -e "  ${BOLD}TEST 4${RESET}  stroma-ai realm via nginx TLS (${HEAD})"
body=$(http_get "https://${HEAD}/realms/stroma-ai/.well-known/openid-configuration")
issuer=$(json_field "${body}" "issuer")
if [[ -n "${issuer}" ]]; then
    result PASS "Keycloak stroma-ai realm via nginx" "issuer=${issuer}"
else
    result FAIL "Keycloak stroma-ai realm via nginx" \
        "no issuer — KC_INTERNAL_URL may point to wrong host. got: ${body:0:80}"
fi

# ---------------------------------------------------------------------------
# Get KC admin token (needed for tests 5, 6, 7)
# ---------------------------------------------------------------------------
KC_ADMIN_TOKEN=""
if [[ "${SKIP_AUTH}" -eq 0 && -z "${KC_ADMIN_PASS}" ]]; then
    # Try to read from compose .env next to this repo
    _kc_env="${REPO_ROOT}/deploy/keycloak/.env"
    if [[ -f "${_kc_env}" ]]; then
        KC_ADMIN_PASS="$(grep '^KC_ADMIN_PASSWORD=' "${_kc_env}" \
            | head -1 | cut -d= -f2- | tr -d '[:space:]')" || true
    fi
    if [[ -z "${KC_ADMIN_PASS}" ]]; then
        echo -e "  ${YELLOW}NOTE${RESET}: KC admin password not found. Pass --kc-admin-pass=PW or"
        echo -e "        place it in deploy/keycloak/.env. Tests 5–7, 11–12 will be skipped."
        SKIP_AUTH=1
    fi
fi

if [[ "${SKIP_AUTH}" -eq 0 ]]; then
    _token_body=$(http_get \
        "http://${KC}:${KC_PORT}/realms/master/protocol/openid-connect/token" \
        -X POST \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "grant_type=password&client_id=admin-cli&username=admin&password=${KC_ADMIN_PASS}")
    KC_ADMIN_TOKEN=$(json_field "${_token_body}" "access_token")
fi

# ---------------------------------------------------------------------------
# TEST 5 — Keycloak admin credentials
# ---------------------------------------------------------------------------
hr; echo -e "  ${BOLD}TEST 5${RESET}  Keycloak admin credentials"
if [[ "${SKIP_AUTH}" -eq 1 ]]; then
    result SKIP "Keycloak admin login" "--skip-auth or password not available"
elif [[ -n "${KC_ADMIN_TOKEN}" ]]; then
    result PASS "Keycloak admin login" "token obtained"
else
    _err=$(json_field "${_token_body:-}" "error_description")
    result FAIL "Keycloak admin login" "${_err:-wrong password or KC not reachable}"
fi

# ---------------------------------------------------------------------------
# TEST 6 — stroma-ai realm exists
# ---------------------------------------------------------------------------
hr; echo -e "  ${BOLD}TEST 6${RESET}  stroma-ai realm configured"
if [[ "${SKIP_AUTH}" -eq 1 || -z "${KC_ADMIN_TOKEN}" ]]; then
    result SKIP "stroma-ai realm" "no admin token"
else
    body=$(http_get "http://${KC}:${KC_PORT}/admin/realms/stroma-ai" \
        -H "Authorization: Bearer ${KC_ADMIN_TOKEN}")
    realm=$(json_field "${body}" "realm")
    enabled=$(json_field "${body}" "enabled")
    if [[ "${realm}" == "stroma-ai" && "${enabled}" == "True" ]]; then
        result PASS "stroma-ai realm" "realm=stroma-ai enabled=True"
    elif [[ "${realm}" == "stroma-ai" ]]; then
        result FAIL "stroma-ai realm" "realm exists but enabled=${enabled}"
    else
        result FAIL "stroma-ai realm" "not found — run setup-keycloak.sh to completion"
    fi
fi

# ---------------------------------------------------------------------------
# TEST 7 — OIDC clients registered
# ---------------------------------------------------------------------------
hr; echo -e "  ${BOLD}TEST 7${RESET}  OIDC clients registered"
if [[ "${SKIP_AUTH}" -eq 1 || -z "${KC_ADMIN_TOKEN}" ]]; then
    result SKIP "OIDC clients" "no admin token"
else
    _clients_ok=1
    _client_details=""
    for _client in stroma-gateway openwebui; do
        _cbody=$(http_get \
            "http://${KC}:${KC_PORT}/admin/realms/stroma-ai/clients?clientId=${_client}" \
            -H "Authorization: Bearer ${KC_ADMIN_TOKEN}")
        _enabled=$(json_field "${_cbody}" "0.enabled")
        if [[ "${_enabled}" == "True" ]]; then
            _client_details+="${_client}=enabled "
        else
            _clients_ok=0
            _client_details+="${_client}=MISSING "
        fi
    done
    if [[ "${_clients_ok}" -eq 1 ]]; then
        result PASS "OIDC clients" "${_client_details% }"
    else
        result FAIL "OIDC clients" "${_client_details% } — re-run setup-keycloak.sh"
    fi
fi

# ---------------------------------------------------------------------------
# TEST 8 — OpenWebUI direct HTTP
# ---------------------------------------------------------------------------
hr; echo -e "  ${BOLD}TEST 8${RESET}  OpenWebUI direct HTTP (${OWU_HOST}:${OWU_PORT})"
_http_code=$(curl -sk --max-time 10 -o /dev/null -w "%{http_code}" \
    "http://${OWU_HOST}:${OWU_PORT}/" 2>/dev/null || echo "000")
if [[ "${_http_code}" == "200" ]]; then
    result PASS "OpenWebUI direct HTTP" "HTTP ${_http_code}"
elif [[ "${_http_code}" == "000" ]]; then
    result FAIL "OpenWebUI direct HTTP" "connection refused — run setup-openwebui.sh"
else
    result FAIL "OpenWebUI direct HTTP" "HTTP ${_http_code}"
fi

# ---------------------------------------------------------------------------
# TEST 9 — OpenWebUI via nginx TLS
# ---------------------------------------------------------------------------
hr; echo -e "  ${BOLD}TEST 9${RESET}  OpenWebUI via nginx TLS (/)"
_http_code=$(curl -sk --max-time 10 -o /dev/null -w "%{http_code}" \
    "https://${HEAD}/" 2>/dev/null || echo "000")
if [[ "${_http_code}" == "200" || "${_http_code}" == "301" || "${_http_code}" == "302" ]]; then
    result PASS "OpenWebUI via nginx" "HTTP ${_http_code}"
elif [[ "${_http_code}" == "000" ]]; then
    result FAIL "OpenWebUI via nginx" "connection refused or nginx misconfigured"
else
    result FAIL "OpenWebUI via nginx" "HTTP ${_http_code} — check OPENWEBUI_INTERNAL_URL in config.env"
fi

# ---------------------------------------------------------------------------
# TEST 10 — Gateway health (direct)
# ---------------------------------------------------------------------------
hr; echo -e "  ${BOLD}TEST 10${RESET} Gateway health check (${HEAD}:${GW_PORT})"
body=$(http_get "http://${HEAD}:${GW_PORT}/health")
svc=$(json_field "${body}" "service")
if [[ "${svc}" == "stroma-gateway" ]]; then
    result PASS "Gateway health" "service=stroma-gateway"
else
    result FAIL "Gateway health" "got: ${body:0:80} — is stroma-ai-gateway.service running?"
fi

# ---------------------------------------------------------------------------
# TEST 11 — OIDC user token (researcher-demo)
# ---------------------------------------------------------------------------
hr; echo -e "  ${BOLD}TEST 11${RESET} OIDC user token (researcher-demo)"
USER_TOKEN=""
GW_CLIENT_SECRET="${KC_GATEWAY_CLIENT_SECRET:-}"
if [[ "${SKIP_AUTH}" -eq 1 || -z "${KC_ADMIN_TOKEN}" ]]; then
    result SKIP "OIDC user token" "no admin token"
elif [[ -z "${GW_CLIENT_SECRET}" ]]; then
    result SKIP "OIDC user token" "KC_GATEWAY_CLIENT_SECRET not in config.env"
else
    # Fetch token directly from KC (not via nginx) so the issued token's
    # "iss" claim matches the issuer the gateway cached from OIDC_DISCOVERY_URL
    # (http://<host>:8080/...).  Going through nginx would produce an https://
    # issuer that doesn't match, causing 401 on subsequent requests.
    _tbody=$(http_get \
        "http://${KC}:${KC_PORT}/realms/stroma-ai/protocol/openid-connect/token" \
        -X POST \
        -H "Content-Type: application/x-www-form-urlencoded" \
        -d "grant_type=client_credentials&client_id=stroma-gateway&client_secret=${GW_CLIENT_SECRET}")
    USER_TOKEN=$(json_field "${_tbody}" "access_token")
    _terr=$(json_field "${_tbody}" "error_description")
    if [[ -n "${USER_TOKEN}" ]]; then
        result PASS "OIDC client_credentials token" "token obtained"
    else
        result FAIL "OIDC client_credentials token" "${_terr:-check KC_GATEWAY_CLIENT_SECRET matches Keycloak}"
    fi
fi

# ---------------------------------------------------------------------------
# TEST 12 — End-to-end authenticated inference
# ---------------------------------------------------------------------------
hr; echo -e "  ${BOLD}TEST 12${RESET} Authenticated vLLM inference (E2E)"
if [[ -z "${USER_TOKEN}" ]]; then
    result SKIP "E2E inference" "no user token (tests 5–11 must pass first)"
else
    _MODEL="${STROMA_MODEL_NAME:-stroma-ai-coder}"
    _ibody=$(curl -sk --max-time 60 \
        "https://${HEAD}/v1/chat/completions" \
        -H "Authorization: Bearer ${USER_TOKEN}" \
        -H "Content-Type: application/json" \
        -d "{\"model\":\"${_MODEL}\",\"messages\":[{\"role\":\"user\",\"content\":\"Reply with exactly one word: ready\"}],\"max_tokens\":5}" \
        2>/dev/null)
    _reply=$(json_field "${_ibody}" "choices.0.message.content")
    if [[ -n "${_reply}" ]]; then
        result PASS "E2E inference" "model replied: ${_reply}"
    else
        _ierr=$(json_field "${_ibody}" "message")
        result FAIL "E2E inference" "${_ierr:-no completion returned — got: ${_ibody:0:120}}"
    fi
fi

# ---------------------------------------------------------------------------
# TEST 13 — client.env world-readable and populated
# Verifies that unprivileged cluster users can source the connection file.
# ---------------------------------------------------------------------------
hr; echo -e "  ${BOLD}TEST 13${RESET} client.env readable by cluster users"
_install_dir="${STROMA_INSTALL_DIR:-${CONFIG_FILE%/config.env}}"
_client_env="${_install_dir}/client.env"
if [[ ! -f "${_client_env}" ]]; then
    result FAIL "client.env" "not found at ${_client_env} — re-run install.sh to generate it"
else
    # Check world-readable bit (others read = octal mode & 004)
    _perms=$(stat -c '%a' "${_client_env}" 2>/dev/null || stat -f '%Lp' "${_client_env}" 2>/dev/null || echo "000")
    _world_readable=0
    if (( (8#${_perms} & 8#004) != 0 )); then
        _world_readable=1
    fi

    # Check that a non-root user can actually read it
    _readable_test=0
    if [[ "$(id -u)" -ne 0 ]]; then
        # Running as normal user — attempt a direct read
        if [[ -r "${_client_env}" ]]; then _readable_test=1; fi
    else
        # Running as root — use su to test as an unprivileged user
        _test_user=$(getent passwd stromaai &>/dev/null && echo stromaai || \
                     id -un 1000 2>/dev/null || \
                     awk -F: '$3 >= 1000 && $3 < 65534 {print $1; exit}' /etc/passwd 2>/dev/null || \
                     echo "nobody")
        if su -s /bin/sh -c "test -r '${_client_env}'" "${_test_user}" 2>/dev/null; then
            _readable_test=1
        fi
    fi

    # Check that required variables are non-empty
    _missing_vars=()
    for _var in STROMA_API_URL STROMA_MODEL_NAME STROMA_CHAT_URL; do
        if ! grep -qE "^${_var}=.+" "${_client_env}" 2>/dev/null; then
            _missing_vars+=("${_var}")
        fi
    done

    if [[ "${_world_readable}" -eq 0 ]]; then
        result FAIL "client.env" "mode ${_perms} — not world-readable; fix: chmod 644 ${_client_env}"
    elif [[ "${_readable_test}" -eq 0 ]]; then
        result FAIL "client.env" "world-readable bit set but read test failed (ACL or mount restriction?)"
    elif [[ ${#_missing_vars[@]} -gt 0 ]]; then
        result FAIL "client.env" "missing populated vars: ${_missing_vars[*]} — re-run install.sh"
    else
        _api_url=$(grep -m1 '^STROMA_API_URL=' "${_client_env}" | cut -d= -f2-)
        result PASS "client.env" "mode ${_perms}, readable, STROMA_API_URL=${_api_url}"
    fi
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
hr
echo -e "  ${GREEN}${PASS}${RESET} passed  ${RED}${FAIL}${RESET} failed  ${YELLOW}${SKIP}${RESET} skipped  (of ${_total} tests)"
echo
if [[ "${FAIL}" -gt 0 ]]; then
    echo -e "${RED}  PLATFORM NOT HEALTHY — fix failing tests before going live.${RESET}"
    echo
fi

# ---------------------------------------------------------------------------
# Quick Reference — URLs
# ---------------------------------------------------------------------------
hr
echo -e "  ${BOLD}Quick Reference — URLs${RESET}"
echo
echo -e "  ${CYAN}External (TLS, via nginx)${RESET}"
echo -e "    Health         https://${HEAD}/health"
echo -e "    OpenWebUI      https://${HEAD}/"
echo -e "    API (v1)       https://${HEAD}/v1/"
echo -e "    Models         https://${HEAD}/v1/models"
echo -e "    Chat           https://${HEAD}/v1/chat/completions"
echo -e "    OIDC token     https://${HEAD}/realms/stroma-ai/protocol/openid-connect/token  ${YELLOW}(POST only)${RESET}"
echo -e "    KC console     https://${HEAD}/admin/master/console/"
echo
echo -e "  ${CYAN}Internal — Gateway${RESET}"
echo -e "    Health         http://${HEAD}:${GW_PORT}/health"
echo -e "    API (v1)       http://${HEAD}:${GW_PORT}/v1/"
echo
echo -e "  ${CYAN}Internal — Keycloak${RESET}"
echo -e "    Admin REST     http://${KC}:${KC_PORT}/admin/realms/stroma-ai  ${YELLOW}(needs Bearer token)${RESET}"
echo -e "    OIDC discovery http://${KC}:${KC_PORT}/realms/stroma-ai/.well-known/openid-configuration"
echo -e "    JWKS           http://${KC}:${KC_PORT}/realms/stroma-ai/protocol/openid-connect/certs"
echo -e "    Token endpoint http://${KC}:${KC_PORT}/realms/stroma-ai/protocol/openid-connect/token  ${YELLOW}(POST only)${RESET}"
echo -e "    KC console     https://${HEAD}/admin/master/console/  ${YELLOW}(use nginx URL — direct port broken with KC_HOSTNAME)${RESET}"
echo
echo -e "  ${CYAN}Internal — OpenWebUI${RESET}"
echo -e "    Chat UI        http://${OWU_HOST}:${OWU_PORT}/"
echo
hr

if [[ "${FAIL}" -gt 0 ]]; then
    exit 1
else
    echo -e "${GREEN}  Platform is healthy.${RESET}"
    echo
    exit 0
fi
