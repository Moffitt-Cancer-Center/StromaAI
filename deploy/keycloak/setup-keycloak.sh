#!/usr/bin/env bash
# =============================================================================
# StromaAI — Keycloak Identity Provider Setup
# =============================================================================
# Configures the identity layer for StromaAI. Supports two modes:
#
#   1. LOCAL   — Starts a Keycloak 26.x container with the pre-configured
#                stroma-ai realm, PostgreSQL backend, and generated secrets.
#
#   2. EXTERNAL — Registers an existing institutional IdP (Okta, Azure AD,
#                 Shibboleth, etc.) by accepting an OIDC_DISCOVERY_URL and
#                 writing the correct variables to the platform config.
#
# Output:
#   /opt/stroma-ai/config.env  — updated with OIDC_* variables (merged, not
#                                overwritten) so other components auto-pick-up.
#
# Usage:
#   ./setup-keycloak.sh                          # interactive wizard
#   ./setup-keycloak.sh --mode=local             # non-interactive local deploy
#   ./setup-keycloak.sh --mode=external          # non-interactive external IdP
#   ./setup-keycloak.sh --config=/path/to/.env   # explicit config path
#   ./setup-keycloak.sh --dry-run --yes          # print without executing
#   ./setup-keycloak.sh -h | --help
#
# Options:
#   --mode=local      Deploy Keycloak 26.x container non-interactively
#   --mode=external   Configure an existing institutional IdP non-interactively
#   --config=FILE     Path to platform config.env (default: /opt/stroma-ai/config.env)
#   --dry-run         Print commands without executing them
#   --yes             Non-interactive: auto-confirm all prompts
#   -h, --help        Show this help message
#
# Requirements (LOCAL mode): podman + either 'podman compose' (Podman 4.x) or
#                             standalone podman-compose
# Requirements (EXTERNAL mode): curl, python3
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# ---------------------------------------------------------------------------
# Source shared library (provides log_ok/warn/error/step/dry, run_cmd,
# confirm, backup_file, require_cmd, detect_os)
# ---------------------------------------------------------------------------
# shellcheck source=install/lib/common.sh
source "${REPO_ROOT}/install/lib/common.sh"
# shellcheck source=install/lib/detect.sh
source "${REPO_ROOT}/install/lib/detect.sh"

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
CONFIG_ENV="${STROMA_CONFIG_ENV:-/opt/stroma-ai/config.env}"
COMPOSE_ENV="${SCRIPT_DIR}/.env"

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
    cat <<EOF
Usage: $(basename "${BASH_SOURCE[0]}") [OPTIONS]

Options:
  --mode=local      Deploy Keycloak 26.x container non-interactively
  --mode=external   Configure an existing institutional IdP non-interactively
  --config=FILE     Path to platform config.env
                    (default: /opt/stroma-ai/config.env)
  --dry-run         Print commands without executing them
  --yes             Non-interactive (auto-confirm all prompts)
  -h, --help        Show this help message

Examples:
  ./setup-keycloak.sh                     # interactive wizard
  ./setup-keycloak.sh --mode=local --yes  # fully non-interactive
  STROMA_CONFIG_ENV=/my/config.env ./setup-keycloak.sh --mode=local
EOF
    exit 0
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
MODE=""
for _arg in "$@"; do
    case "${_arg}" in
        --mode=local)    MODE="local" ;;
        --mode=external) MODE="external" ;;
        --config=*)      CONFIG_ENV="${_arg#--config=}" ;;
        --dry-run)       export STROMA_DRY_RUN=1 ;;
        --yes)           export STROMA_YES=1 ;;
        -h|--help)       usage ;;
        *) die "Unknown argument: ${_arg}. Use --help for usage." ;;
    esac
done
unset _arg

# ---------------------------------------------------------------------------
# Detect Podman Compose implementation — sets COMPOSE_CMD
# ---------------------------------------------------------------------------
detect_compose() {
    require_cmd podman
    if podman compose version &>/dev/null 2>&1; then
        COMPOSE_CMD="podman compose"
        log_ok "Compose: using 'podman compose' (Podman 4.x built-in)"
    elif command -v podman-compose &>/dev/null; then
        COMPOSE_CMD="podman-compose"
        log_ok "Compose: using 'podman-compose' (standalone)"
    else
        die "No Podman Compose found. Install with:
  dnf install podman-compose        # RHEL/Rocky (requires EPEL)
  pip3 install podman-compose       # pip fallback"
    fi
}

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
gen_secret() {
    python3 -c "import secrets; print(secrets.token_hex(32))" 2>/dev/null \
        || openssl rand -hex 32
}

read_config_var() {
    local key="$1"
    grep -E "^${key}=" "${CONFIG_ENV}" 2>/dev/null | cut -d= -f2- || true
}

write_or_update_config() {
    # Writes KEY=VALUE to CONFIG_ENV, replacing the line if the key already
    # exists. Creates the file (mode 640) if it does not exist.
    local key="$1" value="$2"
    if [[ "${STROMA_DRY_RUN:-0}" == "1" ]]; then
        log_dry "write_config ${key}=<value> → ${CONFIG_ENV}"
        return 0
    fi
    if [[ ! -f "${CONFIG_ENV}" ]]; then
        mkdir -p "$(dirname "${CONFIG_ENV}")"
        touch "${CONFIG_ENV}"
        chmod 640 "${CONFIG_ENV}"
    fi
    write_env_var "${key}" "${value}" "${CONFIG_ENV}"
}

wait_for_keycloak() {
    local url="$1" max_wait=120 waited=0
    # Poll /realms/master (always present as soon as KC is up).
    # stroma-ai realm does not exist yet at this point — it is created via
    # the admin REST API by configure_keycloak_realm_rest after this returns.
    local master_url="${url%/realms/stroma-ai}/realms/master"
    log_info "Waiting for Keycloak at ${master_url} ..."
    while ! curl -sf --max-time 3 "${master_url}" &>/dev/null; do
        sleep 5
        waited=$((waited + 5))
        if (( waited >= max_wait )); then
            die "Keycloak did not become healthy within ${max_wait}s.\n  Check: ${COMPOSE_CMD} logs keycloak"
        fi
        printf '.'
    done
    echo
    log_ok "Keycloak is healthy"
}

# ---------------------------------------------------------------------------
# configure_keycloak_realm_rest — idempotent KC26 realm setup via admin API.
# Uses python3 stdlib (urllib) — no extra dependencies.
# Skips all configuration if the stroma-ai realm already exists.
# ---------------------------------------------------------------------------
configure_keycloak_realm_rest() {
    local kc_base_url="$1"   # http://hostname:port
    local admin_user="$2"
    local admin_pass="$3"
    local realm="stroma-ai"
    # These are set in the outer LOCAL mode block before this is called
    # (GW_CLIENT_SECRET, OWU_CLIENT_SECRET, DEMO_USER_PASSWORD, KC_HOSTNAME,
    #  KC_PORT — all already in scope as shell variables).

    log_step "Configuring Keycloak realm (stroma-ai) via admin REST API"

    python3 - \
        "${kc_base_url}" "${admin_user}" "${admin_pass}" "${realm}" \
        "${GW_CLIENT_SECRET}" "${OWU_CLIENT_SECRET}" "${DEMO_USER_PASSWORD}" \
        "${KC_HOSTNAME}" "${KC_PORT:-8080}" "${STROMA_HEAD_HOST}" "${OPENWEBUI_URL}" <<'PYEOF'
import sys, json, time
import urllib.request as urlreq
import urllib.parse as urlparse
import urllib.error as urlerr

kc_url     = sys.argv[1]
admin_u    = sys.argv[2]
admin_p    = sys.argv[3]
realm      = sys.argv[4]
gw_sec     = sys.argv[5]
owu_sec    = sys.argv[6]
demo_pw    = sys.argv[7]
host       = sys.argv[8]
port       = sys.argv[9]
head_host  = sys.argv[10]
owu_url    = sys.argv[11]

def _http(method, path, data=None, token=None, form=False):
    url  = kc_url + path
    body = ctype = None
    if form and data:
        body  = urlparse.urlencode(data).encode()
        ctype = 'application/x-www-form-urlencoded'
    elif data is not None:
        body  = json.dumps(data).encode()
        ctype = 'application/json'
    hdrs = {}
    if ctype:  hdrs['Content-Type']  = ctype
    if token:  hdrs['Authorization'] = 'Bearer ' + token
    req = urlreq.Request(url, data=body, headers=hdrs, method=method)
    try:
        with urlreq.urlopen(req) as r:
            raw = r.read()
            return r.status, (json.loads(raw) if raw else None)
    except urlerr.HTTPError as e:
        raw = e.read()
        return e.code, (json.loads(raw) if raw else None)

def get_token(retries=24, interval=5):
    for attempt in range(retries):
        try:
            st, resp = _http('POST',
                '/realms/master/protocol/openid-connect/token',
                {'grant_type': 'password', 'client_id': 'admin-cli',
                 'username': admin_u, 'password': admin_p},
                form=True)
            if st == 200 and resp and 'access_token' in resp:
                return resp['access_token']
        except Exception:
            pass
        if attempt < retries - 1:
            sys.stdout.write('.')
            sys.stdout.flush()
            time.sleep(interval)
    raise SystemExit('\nERROR: KC admin API not ready after 2 minutes')

sys.stdout.write('[KC]  Waiting for admin API ready')
sys.stdout.flush()
token = get_token()
print(' OK')

st, realms = _http('GET', '/admin/realms', token=token)
if st == 200 and any(r.get('realm') == realm for r in (realms or [])):
    print(f'[KC]  Realm {realm!r} already configured — skipping')
    sys.exit(0)

print('[KC]  Creating realm: ' + realm)
st, _ = _http('POST', '/admin/realms', {
    'id': realm, 'realm': realm, 'enabled': True,
    'displayName': 'StromaAI Research Platform',
    'sslRequired': 'external',
    'registrationAllowed': False,
    'loginWithEmailAllowed': True,
    'resetPasswordAllowed': True,
    'bruteForceProtected': True,
    'accessTokenLifespan': 900,
}, token=token)
if st not in (201, 409):
    raise SystemExit(f'ERROR: create realm: HTTP {st}')

for rname, rdesc in [
    ('stroma_researcher', 'Grants access to StromaAI inference endpoints.'),
    ('stroma_admin',      'Administrative access to StromaAI management.'),
]:
    _http('POST', f'/admin/realms/{realm}/roles',
          {'name': rname, 'description': rdesc, 'clientRole': False},
          token=token)
print('[KC]  Roles created')

_, rr = _http('GET', f'/admin/realms/{realm}/roles/stroma_researcher', token=token)
researcher_role = {'id': rr['id'], 'name': rr['name']}

_http('POST', f'/admin/realms/{realm}/clients', {
    'clientId': 'stroma-gateway', 'name': 'StromaAI Gateway',
    'enabled': True, 'protocol': 'openid-connect',
    'publicClient': False, 'serviceAccountsEnabled': True,
    'standardFlowEnabled': False, 'implicitFlowEnabled': False,
    'directAccessGrantsEnabled': False,
    'clientAuthenticatorType': 'client-secret',
    'secret': gw_sec,
}, token=token)

_http('POST', f'/admin/realms/{realm}/clients', {
    'clientId': 'openwebui', 'name': 'Open WebUI',
    'enabled': True, 'protocol': 'openid-connect',
    'publicClient': False, 'standardFlowEnabled': True,
    'implicitFlowEnabled': False, 'directAccessGrantsEnabled': False,
    'clientAuthenticatorType': 'client-secret',
    'secret': owu_sec,
    'redirectUris': [
        f'https://{head_host}/*',          # Prod: nginx-proxied Keycloak
        f'{owu_url}/*',                    # OpenWebUI callback
        'http://localhost:3000/*',         # Dev: direct to OpenWebUI
    ],
    'webOrigins': ['+'],
    'attributes': {'pkce.code.challenge.method': 'S256'},
}, token=token)
print('[KC]  Clients created')

_http('POST', f'/admin/realms/{realm}/users', {
    'username': 'researcher-demo', 'email': 'researcher@example.com',
    'firstName': 'Demo', 'lastName': 'Researcher',
    'enabled': True, 'emailVerified': True,
}, token=token)
_, users = _http('GET',
    f'/admin/realms/{realm}/users?username=researcher-demo', token=token)
if not users:
    raise SystemExit('ERROR: demo user not found after creation')
uid = users[0]['id']
_http('PUT', f'/admin/realms/{realm}/users/{uid}/reset-password',
      {'type': 'password', 'value': demo_pw, 'temporary': True}, token=token)
_http('POST', f'/admin/realms/{realm}/users/{uid}/role-mappings/realm',
      [researcher_role], token=token)
print('[KC]  Demo user created (temporary password set)')
print('[KC]  Realm configuration complete')
PYEOF
}
# ---------------------------------------------------------------------------
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║   StromaAI — Identity Provider Setup                  ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════╝${RESET}"
echo ""

if [[ "${STROMA_DRY_RUN:-0}" == "1" ]]; then
    log_warn "DRY-RUN mode — no changes will be made."
    echo ""
fi

detect_os
log_info "OS: ${OS_PRETTY:-unknown}"

# ---------------------------------------------------------------------------
# Ensure python3 and curl are available (used by both modes)
# ---------------------------------------------------------------------------
require_cmd python3
require_cmd curl

# ---------------------------------------------------------------------------
# Mode selection (interactive if not set by flag)
# ---------------------------------------------------------------------------
if [[ -z "${MODE}" ]]; then
    echo "Select identity provider mode:"
    echo "  1) LOCAL    — Deploy Keycloak 26.x container (recommended for standalone)"
    echo "  2) EXTERNAL — Use an existing institutional IdP (Okta, Azure AD, etc.)"
    echo ""
    read -rp "Enter choice [1/2]: " MODE_CHOICE
    case "${MODE_CHOICE}" in
        1) MODE="local" ;;
        2) MODE="external" ;;
        *) die "Invalid choice: ${MODE_CHOICE}. Run again and enter 1 or 2." ;;
    esac
fi

# ===========================================================================
# MODE: LOCAL
# ===========================================================================
if [[ "${MODE}" == "local" ]]; then

    detect_compose

    # -------------------------------------------------------------------------
    # Ensure the CNI dnsname plugin is installed (RHEL 8 Podman uses CNI, not
    # Netavark).  Without it, containers on user-defined networks cannot resolve
    # each other by hostname → "UnknownHostException: postgres".
    # -------------------------------------------------------------------------
    # CNI dnsname (podman-plugins) is no longer required: Keycloak connects to
    # postgres via host.containers.internal:5432 (loopback-published port).
    # Log a note if the plugin is absent but do not attempt an install that
    # would fail for non-root users.
    log_step "Checking CNI DNS plugin (informational)"
    if rpm -q podman-plugins &>/dev/null 2>&1; then
        log_ok "podman-plugins present"
    else
        log_info "podman-plugins not installed — not required (using host.containers.internal)"
    fi

    log_step "Generating cryptographic secrets"
    # Reuse an existing KC_DB_PASSWORD if the compose .env already exists.
    # PostgreSQL ignores POSTGRES_PASSWORD after the data directory is
    # initialised, so regenerating the password on re-runs causes auth
    # failures against an existing postgres_data volume.
    _fresh_db_pass=0
    KC_DB_PASSWORD=""
    if [[ -f "${COMPOSE_ENV}" ]]; then
        KC_DB_PASSWORD="$(grep '^KC_DB_PASSWORD=' "${COMPOSE_ENV}" \
            | head -1 | cut -d= -f2- | tr -d '[:space:]')" || true
    fi
    if [[ -z "${KC_DB_PASSWORD}" ]]; then
        KC_DB_PASSWORD="$(gen_secret)"
        _fresh_db_pass=1
        log_info "Generated new KC_DB_PASSWORD (first run or .env absent)"
    else
        log_info "Reusing existing KC_DB_PASSWORD from ${COMPOSE_ENV}"
    fi
    KC_ADMIN_PASSWORD="$(gen_secret)"
    GW_CLIENT_SECRET="$(gen_secret)"
    OWU_CLIENT_SECRET="$(gen_secret)"
    DEMO_USER_PASSWORD="$(gen_secret)"

    # Prompt for optional hostname/port overrides
    if [[ "${STROMA_YES:-0}" == "1" ]]; then
        KC_HOSTNAME="${KC_HOSTNAME:-localhost}"
        KC_PORT="${KC_PORT:-8080}"
    else
        read -rp "Keycloak hostname [default: localhost]: " _inp
        KC_HOSTNAME="${_inp:-localhost}"
        read -rp "Keycloak HTTP port [default: 8080]: " _inp
        KC_PORT="${_inp:-8080}"
        unset _inp
    fi

    # -------------------------------------------------------------------------
    # Write compose .env (secrets for podman compose only — never committed)
    # -------------------------------------------------------------------------
    log_step "Writing ${COMPOSE_ENV}"
    backup_file "${COMPOSE_ENV}"
    if [[ "${STROMA_DRY_RUN:-0}" != "1" ]]; then
        cat > "${COMPOSE_ENV}" <<EOF
# Auto-generated by setup-keycloak.sh — do NOT commit this file
KC_DB_PASSWORD=${KC_DB_PASSWORD}
KC_ADMIN_USER=admin
KC_ADMIN_PASSWORD=${KC_ADMIN_PASSWORD}
KC_HOSTNAME=${KC_HOSTNAME}
KC_PORT=${KC_PORT}
EOF
        chmod 600 "${COMPOSE_ENV}"
    else
        log_dry "Would write ${COMPOSE_ENV} with KC_HOSTNAME=${KC_HOSTNAME} KC_PORT=${KC_PORT}"
    fi

    # -------------------------------------------------------------------------
    # Start services
    # -------------------------------------------------------------------------
    log_step "Starting Keycloak + PostgreSQL via Podman Compose"

    # Stale volume detection: if we just generated a fresh KC_DB_PASSWORD
    # (no existing .env) but a postgres_data volume already exists, Keycloak
    # will immediately fail with 'password authentication failed'.  Catch this
    # before starting and give the user the exact command to fix it.
    if [[ "${_fresh_db_pass}" -eq 1 && "${STROMA_DRY_RUN:-0}" != "1" ]]; then
        _stale_vol=$(podman volume ls --format '{{.Name}}' 2>/dev/null \
            | grep 'postgres_data$' | head -1 || true)
        if [[ -n "${_stale_vol}" ]]; then
            echo
            log_warn "A new KC_DB_PASSWORD was generated (${COMPOSE_ENV} was absent)."
            log_warn "PostgreSQL volume '${_stale_vol}' already exists with a different password."
            log_warn "Keycloak will fail immediately with 'password authentication failed'."
            echo
            die "Stale database detected. Remove it first, then re-run:\n  podman volume rm ${_stale_vol}\n  ./setup-keycloak.sh"
        fi
    fi

    # Always stop existing containers before starting so compose config
    # changes (env vars, ports) take effect without leftover containers.
    run_cmd ${COMPOSE_CMD} -f "${SCRIPT_DIR}/docker-compose.yml" down 2>/dev/null || true
    run_cmd ${COMPOSE_CMD} -f "${SCRIPT_DIR}/docker-compose.yml" up -d

    log_step "Configuring Firewall"
    open_firewall_port "${KC_PORT:-8080}/tcp"

    log_step "Installing Systemd Service"
    install_systemd_service "${SCRIPT_DIR}/stroma-ai-keycloak.service" "stroma-ai-keycloak"

    # Read head hostname and OpenWebUI URL from config for redirect URIs
    STROMA_HEAD_HOST="$(read_config_var STROMA_HEAD_HOST)"
    STROMA_HEAD_HOST="${STROMA_HEAD_HOST:-localhost}"
    OPENWEBUI_URL="$(read_config_var OPENWEBUI_URL)"
    # Default to /webui path on the main HTTPS endpoint if OPENWEBUI_URL not set
    OPENWEBUI_URL="${OPENWEBUI_URL:-https://${STROMA_HEAD_HOST}/webui}"

    KEYCLOAK_BASE_URL="http://${KC_HOSTNAME}:${KC_PORT}"
    KEYCLOAK_URL="${KEYCLOAK_BASE_URL}/realms/stroma-ai"

    if [[ "${STROMA_DRY_RUN:-0}" != "1" ]]; then
        wait_for_keycloak "${KEYCLOAK_URL}"
        configure_keycloak_realm_rest "${KEYCLOAK_BASE_URL}" "admin" "${KC_ADMIN_PASSWORD}"
    else
        log_dry "Would wait for Keycloak and configure stroma-ai realm via REST API"
    fi

    # Use HTTPS URL through nginx for OIDC discovery (production access pattern)
    # Internal admin API uses http://localhost:8080, but clients use nginx-proxied HTTPS
    OIDC_DISCOVERY_URL="https://${STROMA_HEAD_HOST}/realms/stroma-ai/.well-known/openid-configuration"
    OIDC_ISSUER="https://${STROMA_HEAD_HOST}/realms/stroma-ai"

    # -------------------------------------------------------------------------
    # Write OIDC variables to platform config
    # -------------------------------------------------------------------------
    log_step "Writing OIDC configuration to ${CONFIG_ENV}"
    write_or_update_config "OIDC_DISCOVERY_URL"         "${OIDC_DISCOVERY_URL}"
    write_or_update_config "OIDC_ISSUER"                "${OIDC_ISSUER}"
    write_or_update_config "KC_GATEWAY_CLIENT_ID"       "stroma-gateway"
    write_or_update_config "KC_GATEWAY_CLIENT_SECRET"   "${GW_CLIENT_SECRET}"
    write_or_update_config "KC_OPENWEBUI_CLIENT_ID"     "openwebui"
    write_or_update_config "KC_OPENWEBUI_CLIENT_SECRET" "${OWU_CLIENT_SECRET}"
    write_or_update_config "KC_ADMIN_URL"               "https://${STROMA_HEAD_HOST}/admin"

    echo ""
    echo -e "${BOLD}╔══════════════════════════════════════════════════════╗${RESET}"
    echo -e "${BOLD}║   Keycloak Local Deployment — Summary                 ║${RESET}"
    echo -e "${BOLD}╚══════════════════════════════════════════════════════╝${RESET}"
    echo ""
    echo "  Admin console : http://${KC_HOSTNAME}:${KC_PORT}/admin"
    echo "  Admin user    : admin"
    echo -e "  Admin password: ${YELLOW}${KC_ADMIN_PASSWORD}${RESET}"
    echo "  Demo user     : researcher-demo"
    echo -e "  Demo password : ${YELLOW}${DEMO_USER_PASSWORD}${RESET}"
    echo ""
    log_warn "Save these credentials — they will not be displayed again."
    log_warn "Demo user password is TEMPORARY — user must change on first login."
    echo ""
    echo "  Next: ./deploy/openwebui/setup-openwebui.sh"
    echo ""

# ===========================================================================
# MODE: EXTERNAL
# ===========================================================================
else

    echo ""
    log_step "External IdP configuration"
    echo "You will need the following from your institutional IdP administrator:"
    echo "  • OIDC Discovery URL  (ends in /.well-known/openid-configuration)"
    echo "  • Client ID and secret for the StromaAI gateway"
    echo "  • Client ID and secret for OpenWebUI"
    echo ""

    read -rp "OIDC Discovery URL: " EXT_DISCOVERY_URL
    [[ -z "${EXT_DISCOVERY_URL}" ]] && die "Discovery URL cannot be empty"

    log_info "Validating discovery URL..."
    DISCOVERY_JSON=$(curl -sf --max-time 10 "${EXT_DISCOVERY_URL}") \
        || die "Cannot reach discovery URL: ${EXT_DISCOVERY_URL}"

    EXT_ISSUER=$(echo "${DISCOVERY_JSON}" | python3 -c "import json,sys; print(json.load(sys.stdin)['issuer'])" 2>/dev/null) \
        || die "Discovery document does not contain 'issuer' field"
    log_ok "Issuer: ${EXT_ISSUER}"

    read -rp "Gateway Client ID [default: stroma-gateway]: " _inp
    EXT_GW_CLIENT_ID="${_inp:-stroma-gateway}"

    read -rsp "Gateway Client Secret: " EXT_GW_SECRET
    echo
    [[ -z "${EXT_GW_SECRET}" ]] && die "Gateway client secret cannot be empty"

    read -rp "OpenWebUI Client ID [default: openwebui]: " _inp
    EXT_OWU_CLIENT_ID="${_inp:-openwebui}"

    read -rsp "OpenWebUI Client Secret: " EXT_OWU_SECRET
    echo
    [[ -z "${EXT_OWU_SECRET}" ]] && die "OpenWebUI client secret cannot be empty"
    unset _inp

    log_step "Writing OIDC configuration to ${CONFIG_ENV}"
    write_or_update_config "OIDC_DISCOVERY_URL"         "${EXT_DISCOVERY_URL}"
    write_or_update_config "OIDC_ISSUER"                "${EXT_ISSUER}"
    write_or_update_config "KC_GATEWAY_CLIENT_ID"       "${EXT_GW_CLIENT_ID}"
    write_or_update_config "KC_GATEWAY_CLIENT_SECRET"   "${EXT_GW_SECRET}"
    write_or_update_config "KC_OPENWEBUI_CLIENT_ID"     "${EXT_OWU_CLIENT_ID}"
    write_or_update_config "KC_OPENWEBUI_CLIENT_SECRET" "${EXT_OWU_SECRET}"
    write_or_update_config "KC_ADMIN_URL"               ""

    echo ""
    echo -e "${BOLD}╔══════════════════════════════════════════════════════╗${RESET}"
    echo -e "${BOLD}║   External IdP — Configuration Written                ║${RESET}"
    echo -e "${BOLD}╚══════════════════════════════════════════════════════╝${RESET}"
    echo ""
    echo "  Discovery URL : ${EXT_DISCOVERY_URL}"
    echo "  Issuer        : ${EXT_ISSUER}"
    echo "  Config file   : ${CONFIG_ENV}"
    echo ""
    log_warn "Ensure roles are mapped to the 'realm_access.roles' JWT claim."
    log_warn "Users must have the 'stroma_researcher' role for API access."
    echo ""
    echo "  Next: ./deploy/openwebui/setup-openwebui.sh"
    echo ""
fi

# ---------------------------------------------------------------------------
# Common tail: verify discovery URL is in config
# ---------------------------------------------------------------------------
if [[ "${STROMA_DRY_RUN:-0}" != "1" ]]; then
    log_step "Verifying ${CONFIG_ENV}"
    grep -q "OIDC_DISCOVERY_URL" "${CONFIG_ENV}" \
        || die "OIDC_DISCOVERY_URL not found in ${CONFIG_ENV} — something went wrong"
    log_ok "Identity provider setup complete."
else
    log_dry "Would verify OIDC_DISCOVERY_URL in ${CONFIG_ENV}"
    log_ok "Dry-run complete — no changes made."
fi
