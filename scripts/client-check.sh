#!/usr/bin/env bash
# =============================================================================
# StromaAI — Client Connectivity Check
# =============================================================================
#
# FOR ADMINS DISTRIBUTING THIS SCRIPT:
#   Fill in the CONFIGURATION block below, then send the file to your users.
#   Users need no flags, no config files — they just run it.
#
# FOR USERS:
#   Run:  bash client-check.sh
#   You will be asked for your username and password. The script checks
#   whether your workstation can reach the AI service and that your account
#   is working correctly.
#
#   Requirements: curl, python3  (pre-installed on macOS and most Linux)
#   No install needed. Works on macOS, Linux, and Windows WSL.
#
# =============================================================================
# ┌─────────────────────────────────────────────────────────────────────────┐
# │  ADMIN — fill in these values before distributing this script           │
# └─────────────────────────────────────────────────────────────────────────┘

STROMA_HOST="ood-red.moffitt.org"              # StromaAI access point (FQDN or FQDN:port)
STROMA_REALM="stroma-ai"                       # Keycloak realm name
STROMA_CLIENT="stroma-cli"                     # Public OIDC client (no secret)
STROMA_CONTACT="stromaai-support@moffitt.org"  # Support email shown to users

# ─── end of admin configuration ───────────────────────────────────────────
# Do not edit below this line unless you know what you're doing.
# =============================================================================

set -uo pipefail

# ---------------------------------------------------------------------------
# Power-user / CI flags  (users don't need these)
#   --skip-auth      skip username/password prompt (connectivity only)
#   --insecure       skip TLS cert verification
#   --user=X         pre-fill username (avoids prompt in automated tests)
#   --password=X     pre-fill password (avoids prompt in automated tests)
#   --no-color       disable ANSI colours
# ---------------------------------------------------------------------------
_OPT_SKIP_AUTH=0
_OPT_USER=""
_OPT_PASS=""
CURL_INSECURE=0

for _arg in "$@"; do
    case "${_arg}" in
        --skip-auth)  _OPT_SKIP_AUTH=1 ;;
        --insecure)   CURL_INSECURE=1 ;;
        --user=*)     _OPT_USER="${_arg#--user=}" ;;
        --password=*) _OPT_PASS="${_arg#--password=}" ;;
        --no-color)   : ;;  # handled below
        *)            echo "Unknown option: ${_arg}" >&2; exit 1 ;;
    esac
done
unset _arg

# ---------------------------------------------------------------------------
# Colours — disabled automatically if not a TTY or if --no-color
# ---------------------------------------------------------------------------
if [[ -t 1 ]] && ! printf '%s\0' "$@" | grep -qz -- '--no-color' 2>/dev/null; then
    C_OK='\033[0;32m'
    C_FAIL='\033[0;31m'
    C_WARN='\033[1;33m'
    C_HEAD='\033[1m'
    C_DIM='\033[2m'
    C_INFO='\033[0;36m'
    C_RST='\033[0m'
else
    C_OK='' C_FAIL='' C_WARN='' C_HEAD='' C_DIM='' C_INFO='' C_RST=''
fi

# ---------------------------------------------------------------------------
# Check required tools
# ---------------------------------------------------------------------------
for _cmd in curl python3; do
    if ! command -v "${_cmd}" &>/dev/null; then
        echo "ERROR: '${_cmd}' not found. Please install it and re-run." >&2
        exit 1
    fi
done

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
_CURL_FLAGS=(-s --max-time 20)
[[ "${CURL_INSECURE}" -eq 1 ]] && _CURL_FLAGS+=(-k)

_curl_get()    { curl "${_CURL_FLAGS[@]}" "$@" 2>/dev/null || true; }
_curl_status() {
    # Capture the http_code write-out separately from curl's exit code.
    # Using || echo "000" would double-print "000" when curl exits non-zero
    # but %{http_code} already emitted "000" (e.g. empty reply from server).
    local url="$1"; shift
    local _code
    _code=$(curl "${_CURL_FLAGS[@]}" -o /dev/null -w "%{http_code}" "$@" "${url}" 2>/dev/null) || true
    printf '%s' "${_code:-000}"
}

_json() {
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

_decode_jwt_roles() {
    python3 -c "
import sys, json, base64
tok = sys.argv[1].split('.')
pad = lambda s: s + '=' * (-len(s) % 4)
try:
    payload = json.loads(base64.urlsafe_b64decode(pad(tok[1])))
    roles = payload.get('realm_access', {}).get('roles', [])
    print(' '.join(roles))
except Exception:
    pass
" "$1" 2>/dev/null || true
}

_decode_jwt_field() {
    python3 -c "
import sys, json, base64
tok = sys.argv[1].split('.')
pad = lambda s: s + '=' * (-len(s) % 4)
try:
    payload = json.loads(base64.urlsafe_b64decode(pad(tok[1])))
    print(payload.get(sys.argv[2], ''))
except Exception:
    pass
" "$1" "$2" 2>/dev/null || true
}

_hr() { printf "${C_DIM}%.0s─${C_RST}" {1..64}; echo; }

_PROBLEMS=()

_ok()   { echo -e "  ${C_OK}✓${C_RST}  $*"; }
_fail() { echo -e "  ${C_FAIL}✗${C_RST}  $*"; _PROBLEMS+=("$1"); }
_warn() { echo -e "  ${C_WARN}!${C_RST}  $*"; }
_note() { echo -e "  ${C_DIM}·${C_RST}  $*"; }
_section() { echo; _hr; echo -e "  ${C_HEAD}$*${C_RST}"; _hr; }

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------
echo
echo -e "${C_HEAD}╔══════════════════════════════════════════════════════════════╗${C_RST}"
echo -e "${C_HEAD}║           StromaAI — Connection Check                        ║${C_RST}"
echo -e "${C_HEAD}╚══════════════════════════════════════════════════════════════╝${C_RST}"
echo
echo -e "  Checking your connection to ${C_INFO}${STROMA_HOST}${C_RST}"
echo -e "  ${C_DIM}$(date '+%A, %B %-d %Y  %H:%M %Z')${C_RST}"

# ---------------------------------------------------------------------------
# SECTION 1 — Connectivity
# ---------------------------------------------------------------------------
_section "1 / 4  Connectivity"

# Try strict TLS first, then insecure, to distinguish cert vs network issues
# Use || true (not || echo "000") to avoid double-printing "000" when curl
# itself returns http_code=000 on network failure, which would yield "000000"
# and cause the == "000" guard below to silently pass.
_STRICT_CODE=$(curl -s --max-time 20 -o /dev/null -w "%{http_code}" \
    "https://${STROMA_HOST}/health" 2>/dev/null) || true
_STRICT_CODE="${_STRICT_CODE:-000}"
_INSECURE_CODE=$(curl -sk --max-time 20 -o /dev/null -w "%{http_code}" \
    "https://${STROMA_HOST}/health" 2>/dev/null) || true
_INSECURE_CODE="${_INSECURE_CODE:-000}"

if [[ "${_INSECURE_CODE}" == "000" ]]; then
    _fail "Cannot reach https://${STROMA_HOST}/health"
    echo -e "     ${C_DIM}This usually means:${C_RST}"
    echo -e "     ${C_DIM}• You are not on the campus network or VPN${C_RST}"
    echo -e "     ${C_DIM}• A firewall is blocking outbound HTTPS${C_RST}"
    echo -e "     ${C_DIM}• The hostname resolves to a different IP outside the campus network${C_RST}"
    echo -e "     ${C_DIM}  (verify: dig +short ${STROMA_HOST} — should return a campus IP)${C_RST}"
    echo -e "     ${C_DIM}• The hostname may have changed — contact ${STROMA_CONTACT}${C_RST}"
    echo
    echo -e "  ${C_FAIL}Cannot continue — no network path to the server.${C_RST}"
    echo -e "  Contact ${C_INFO}${STROMA_CONTACT}${C_RST} for help."
    echo
    exit 1
fi

_ok "Server is reachable at ${STROMA_HOST}"

# TLS trust check
if [[ "${_STRICT_CODE}" != "000" && -n "${_STRICT_CODE}" ]]; then
    _ok "TLS certificate is valid and trusted"
else
    CURL_INSECURE=1
    _CURL_FLAGS+=(-k)
    _warn "TLS certificate is not trusted by your system"
    echo -e "     ${C_DIM}Your connection is still encrypted, but your computer doesn't${C_RST}"
    echo -e "     ${C_DIM}recognise the certificate authority. This is common on corporate${C_RST}"
    echo -e "     ${C_DIM}networks with internal CAs. Contact ${STROMA_CONTACT} for the CA bundle.${C_RST}"
fi

# ---------------------------------------------------------------------------
# SECTION 2 — Authentication
# ---------------------------------------------------------------------------
_section "2 / 4  Authentication"

_KC_BASE="https://${STROMA_HOST}/realms/${STROMA_REALM}"
_KC_DISCOVERY="${_KC_BASE}/.well-known/openid-configuration"
_KC_TOKEN="${_KC_BASE}/protocol/openid-connect/token"

_disc=$(_curl_get "${_KC_DISCOVERY}")
_disc_code=$(_curl_status "${_KC_DISCOVERY}")
_issuer=$(_json "${_disc}" "issuer")

if [[ -n "${_issuer}" ]]; then
    _ok "Authentication service is reachable"
else
    _fail "Cannot reach the authentication service (Keycloak)  (HTTP ${_disc_code})"
    if [[ "${_disc_code}" == "000" ]]; then
        echo -e "     ${C_DIM}Connection timed out — nginx is not forwarding /realms/ to Keycloak.${C_RST}"
        echo -e "     ${C_DIM}Most likely cause on RHEL/Rocky: SELinux blocking nginx → Keycloak.${C_RST}"
        echo -e "     ${C_DIM}Admin fix: sudo setsebool -P httpd_can_network_connect 1 httpd_can_network_relay 1${C_RST}"
        echo -e "     ${C_DIM}Also check: Keycloak is running and nginx upstream URL is correct.${C_RST}"
    elif [[ "${_disc_code}" == "502" || "${_disc_code}" == "503" ]]; then
        echo -e "     ${C_DIM}nginx returned HTTP ${_disc_code} — it cannot reach the Keycloak upstream.${C_RST}"
        echo -e "     ${C_DIM}Admin: verify Keycloak is running and KC_INTERNAL_URL in config.env is correct.${C_RST}"
        echo -e "     ${C_DIM}Then re-run: sudo scripts/deploy-nginx.sh${C_RST}"
    else
        echo -e "     ${C_DIM}The login service returned an unexpected response — contact ${STROMA_CONTACT}.${C_RST}"
    fi
fi

_ACCESS_TOKEN=""
_SKIP_AUTH="${_OPT_SKIP_AUTH}"
[[ -z "${_issuer}" ]] && _SKIP_AUTH=1

if [[ "${_SKIP_AUTH}" -eq 0 ]]; then
    echo
    if [[ -n "${_OPT_USER}" ]]; then
        _auth_user="${_OPT_USER}"
        echo -e "  ${C_DIM}Username: ${_auth_user}${C_RST}"
    else
        printf "  Enter your username: "
        read -r _auth_user
    fi

    if [[ -n "${_OPT_PASS}" ]]; then
        _auth_pass="${_OPT_PASS}"
    else
        printf "  Password: "
        read -rs _auth_pass
        echo
    fi

    echo
    _tok_resp=$(curl "${_CURL_FLAGS[@]}" \
        -X POST "${_KC_TOKEN}" \
        -H "Content-Type: application/x-www-form-urlencoded" \
        --data-urlencode "client_id=${STROMA_CLIENT}" \
        --data-urlencode "grant_type=password" \
        --data-urlencode "username=${_auth_user}" \
        --data-urlencode "password=${_auth_pass}" \
        2>/dev/null || true)

    _ACCESS_TOKEN=$(_json "${_tok_resp}" "access_token")
    _tok_error=$(_json "${_tok_resp}" "error_description")

    if [[ -n "${_ACCESS_TOKEN}" ]]; then
        _ok "Login successful  (${_auth_user})"
    else
        case "${_tok_error}" in
            *"Invalid user credentials"*|*"credentials"*|*"password"*)
                _fail "Login failed — username or password is incorrect"
                echo -e "     ${C_DIM}Double-check your username (usually your network login) and password.${C_RST}"
                ;;
            *"Account is not fully set up"*)
                _fail "Login failed — account not fully configured"
                echo -e "     ${C_DIM}Contact ${STROMA_CONTACT} to have your account set up.${C_RST}"
                ;;
            *"Account disabled"*|*"disabled"*|*"locked"*)
                _fail "Login failed — your account is disabled or locked"
                echo -e "     ${C_DIM}Contact ${STROMA_CONTACT} to have your account re-enabled.${C_RST}"
                ;;
            *)
                _fail "Login failed"
                [[ -n "${_tok_error}" ]] && echo -e "     ${C_DIM}Details: ${_tok_error}${C_RST}"
                echo -e "     ${C_DIM}Contact ${STROMA_CONTACT} if your credentials look correct.${C_RST}"
                ;;
        esac
    fi

    if [[ -n "${_ACCESS_TOKEN}" ]]; then
        _roles=$(_decode_jwt_roles "${_ACCESS_TOKEN}")
        if echo "${_roles}" | grep -qw "stroma_researcher"; then
            _ok "Your account has AI access  (stroma_researcher)"
        else
            _fail "Your account does not have permission to use the AI service"
            echo -e "     ${C_DIM}Your login worked but your account hasn't been granted AI access yet.${C_RST}"
            echo -e "     ${C_DIM}Contact ${STROMA_CONTACT} and ask to be added to the AI access list.${C_RST}"
            _ACCESS_TOKEN=""  # don't use a token that will be rejected
        fi
    fi
else
    _note "Skipping login  (authentication service unavailable)"
fi

# ---------------------------------------------------------------------------
# SECTION 3 — AI Service
# ---------------------------------------------------------------------------
_section "3 / 4  AI Service"

if [[ -z "${_ACCESS_TOKEN}" ]]; then
    _note "Skipping  (requires successful login)"
else
    _models_body=$(_curl_get \
        -H "Authorization: Bearer ${_ACCESS_TOKEN}" \
        "https://${STROMA_HOST}/v1/models")
    _models_code=$(_curl_status "https://${STROMA_HOST}/v1/models" \
        -H "Authorization: Bearer ${_ACCESS_TOKEN}")
    _model_id=$(_json "${_models_body}" "data.0.id")

    if [[ -n "${_model_id}" ]]; then
        _num_models=$(echo "${_models_body}" | python3 -c "import json,sys; print(len(json.load(sys.stdin).get('data',[])))" 2>/dev/null || echo "1")
        if [[ "${_num_models}" -gt 1 ]]; then
            _ok "AI models loaded  (${_num_models} models available, primary: ${_model_id})"
        else
            _ok "AI model is loaded and ready  (${_model_id})"
        fi
    elif [[ "${_models_code}" == "401" || "${_models_code}" == "403" ]]; then
        _fail "The server rejected your access token"
        echo -e "     ${C_DIM}Your login succeeded but the API gateway rejected the token.${C_RST}"
        echo -e "     ${C_DIM}Contact ${STROMA_CONTACT} — this is a server configuration issue.${C_RST}"
    elif [[ "${_models_code}" == "502" || "${_models_code}" == "503" ]]; then
        _warn "No AI worker is running right now"
        echo -e "     ${C_DIM}This is normal — GPU workers start automatically on your first request.${C_RST}"
        echo -e "     ${C_DIM}Your first chat message may take 1–3 minutes to respond.${C_RST}"
    else
        _warn "AI service returned an unexpected response  (HTTP ${_models_code})"
        echo -e "     ${C_DIM}Contact ${STROMA_CONTACT} if this persists.${C_RST}"
    fi
fi

# ---------------------------------------------------------------------------
# SECTION 4 — Web Interface
# ---------------------------------------------------------------------------
_section "4 / 4  Web Interface"

_owui_body=$(_curl_get "https://${STROMA_HOST}/")
_owui_code=$(_curl_status "https://${STROMA_HOST}/")

if echo "${_owui_body}" | python3 -c \
    "import sys; d=sys.stdin.read(); exit(0 if ('<html' in d.lower() or '<!doctype' in d.lower()) else 1)" 2>/dev/null; then
    _ok "Web chat interface is accessible"
elif [[ "${_owui_code}" =~ ^(301|302|303)$ ]]; then
    _ok "Web chat interface is accessible  (HTTP ${_owui_code} redirect)"
elif [[ "${_owui_code}" == "401" || "${_owui_code}" == "403" ]]; then
    # Gateway is intercepting / instead of OpenWebUI — nginx routing not yet updated
    _fail "Web chat interface is not reachable (HTTP ${_owui_code})"
    echo -e "     ${C_DIM}The server is responding but routing / to the API gateway instead of OpenWebUI.${C_RST}"
    echo -e "     ${C_DIM}This is a server-side configuration issue — contact ${STROMA_CONTACT}.${C_RST}"
elif [[ "${_owui_code}" == "000" ]]; then
    _fail "Web chat interface is not reachable  (HTTP 000 — connection timed out)"
    echo -e "     ${C_DIM}nginx is not forwarding / to OpenWebUI. Most likely causes:${C_RST}"
    echo -e "     ${C_DIM}• SELinux blocking nginx → OpenWebUI (RHEL/Rocky head nodes)${C_RST}"
    echo -e "     ${C_DIM}  Admin fix: sudo setsebool -P httpd_can_network_connect 1 httpd_can_network_relay 1${C_RST}"
    echo -e "     ${C_DIM}• OpenWebUI container not running on the backend host${C_RST}"
    echo -e "     ${C_DIM}Contact ${STROMA_CONTACT} for assistance.${C_RST}"
else
    _warn "Web chat interface returned HTTP ${_owui_code}"
    echo -e "     ${C_DIM}Contact ${STROMA_CONTACT} if you cannot open it in your browser.${C_RST}"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo; _hr; echo

if [[ ${#_PROBLEMS[@]} -eq 0 ]]; then
    echo -e "  ${C_OK}${C_HEAD}Everything looks good!${C_RST}"
    echo
    echo -e "  ${C_HEAD}Open the web chat in your browser:${C_RST}"
    echo -e "    ${C_INFO}https://${STROMA_HOST}/${C_RST}"
    echo
    if [[ -n "${_ACCESS_TOKEN}" ]]; then
        echo -e "  ${C_HEAD}VS Code / Kilo Code / API access:${C_RST}"
        echo -e "    ${C_DIM}Base URL  ${C_RST}  https://${STROMA_HOST}/v1"
        echo -e "    ${C_DIM}API Key   ${C_RST}  your Keycloak password"
        echo
    fi
    echo -e "  ${C_DIM}Questions? Contact ${STROMA_CONTACT}${C_RST}"
else
    echo -e "  ${C_FAIL}${C_HEAD}${#_PROBLEMS[@]} problem(s) found:${C_RST}"
    for _p in "${_PROBLEMS[@]}"; do
        echo -e "  ${C_FAIL}  •  ${C_RST}${_p}"
    done
    echo
    echo -e "  ${C_DIM}See the details above for how to resolve each issue.${C_RST}"
    echo -e "  ${C_DIM}For help, contact ${STROMA_CONTACT}${C_RST}"
fi

echo; _hr; echo

[[ ${#_PROBLEMS[@]} -eq 0 ]]; exit $?
