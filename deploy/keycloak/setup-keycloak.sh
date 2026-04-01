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
    log_info "Waiting for Keycloak at ${url} ..."
    # Probe the OIDC discovery document on the main port (8080).
    # The /health/ready endpoint is on the management port (9000) which is
    # not published to the host — so we use the realm endpoint instead.
    while ! curl -sf --max-time 3 "${url}/.well-known/openid-configuration" &>/dev/null; do
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
# Banner
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
    log_step "Verifying CNI DNS plugin (podman-plugins)"
    if rpm -q podman-plugins &>/dev/null 2>&1; then
        log_ok "podman-plugins present (CNI dnsname enabled)"
    else
        log_warn "podman-plugins not found — installing (required for inter-container DNS on RHEL 8)"
        run_cmd dnf install -y podman-plugins
        log_ok "podman-plugins installed"
        # Any network created before the plugin was present lacks DNS support.
        # Take the stack down so compose recreates the network cleanly on up -d.
        if ${COMPOSE_CMD} -f "${SCRIPT_DIR}/docker-compose.yml" ps -q 2>/dev/null | grep -q .; then
            log_info "Cycling stack to recreate CNI network with DNS support..."
            run_cmd ${COMPOSE_CMD} -f "${SCRIPT_DIR}/docker-compose.yml" down
        fi
    fi

    log_step "Generating cryptographic secrets"
    # Reuse an existing KC_DB_PASSWORD if the compose .env already exists.
    # PostgreSQL ignores POSTGRES_PASSWORD after the data directory is
    # initialised, so regenerating the password on re-runs causes auth
    # failures against an existing postgres_data volume.
    KC_DB_PASSWORD=""
    if [[ -f "${COMPOSE_ENV}" ]]; then
        KC_DB_PASSWORD="$(grep '^KC_DB_PASSWORD=' "${COMPOSE_ENV}" \
            | head -1 | cut -d= -f2- | tr -d '[:space:]')" || true
    fi
    if [[ -z "${KC_DB_PASSWORD}" ]]; then
        KC_DB_PASSWORD="$(gen_secret)"
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
    # Generate realm-import.json with substituted secrets
    # realm-export.json is the committed template — never modified.
    # realm-import.json is the runtime file mounted into Keycloak.
    # -------------------------------------------------------------------------
    log_step "Generating realm-import.json with substituted secrets"
    REALM_TEMPLATE="${SCRIPT_DIR}/realm-export.json"
    REALM_IMPORT="${SCRIPT_DIR}/realm-import.json"

    if [[ "${STROMA_DRY_RUN:-0}" != "1" ]]; then
        python3 - <<PYEOF
import json, sys

with open("${REALM_TEMPLATE}") as f:
    realm = json.load(f)

for client in realm.get("clients", []):
    if client["clientId"] == "stroma-gateway":
        client["secret"] = "${GW_CLIENT_SECRET}"
    elif client["clientId"] == "openwebui":
        client["secret"] = "${OWU_CLIENT_SECRET}"
        client["redirectUris"] = [
            "http://${KC_HOSTNAME}:3000/*",
            "http://localhost:3000/*",
        ]

for user in realm.get("users", []):
    for cred in user.get("credentials", []):
        if cred["type"] == "password":
            cred["value"] = "${DEMO_USER_PASSWORD}"

with open("${REALM_IMPORT}", "w") as f:
    json.dump(realm, f, indent=2)
PYEOF
        chmod 600 "${REALM_IMPORT}"
        log_ok "realm-import.json generated"
    else
        log_dry "Would generate ${REALM_IMPORT} with substituted client secrets"
    fi

    # -------------------------------------------------------------------------
    # Start services
    # -------------------------------------------------------------------------
    log_step "Starting Keycloak + PostgreSQL via Podman Compose"
    # Verify the processed realm JSON exists before starting — if it's missing,
    # Keycloak will get the raw template with REPLACE_WITH_* placeholders and
    # fail silently in a restart loop. This should never happen when running
    # via setup-keycloak.sh, but guard against direct podman-compose invocations.
    if [[ "${STROMA_DRY_RUN:-0}" != "1" && ! -f "${SCRIPT_DIR}/realm-import.json" ]]; then
        die "realm-import.json not found. Run ./setup-keycloak.sh to generate it before starting."
    fi
    run_cmd ${COMPOSE_CMD} -f "${SCRIPT_DIR}/docker-compose.yml" up -d

    log_step "Configuring Firewall"
    open_firewall_port "${KC_PORT:-8080}/tcp"

    log_step "Installing Systemd Service"
    install_systemd_service "${SCRIPT_DIR}/stroma-ai-keycloak.service" "stroma-ai-keycloak"

    KEYCLOAK_URL="http://${KC_HOSTNAME}:${KC_PORT}/realms/stroma-ai"

    if [[ "${STROMA_DRY_RUN:-0}" != "1" ]]; then
        wait_for_keycloak "${KEYCLOAK_URL}"
    else
        log_dry "Would wait for Keycloak at ${KEYCLOAK_URL}/.well-known/openid-configuration"
    fi

    OIDC_DISCOVERY_URL="${KEYCLOAK_URL}/.well-known/openid-configuration"

    # -------------------------------------------------------------------------
    # Write OIDC variables to platform config
    # -------------------------------------------------------------------------
    log_step "Writing OIDC configuration to ${CONFIG_ENV}"
    write_or_update_config "OIDC_DISCOVERY_URL"         "${OIDC_DISCOVERY_URL}"
    write_or_update_config "OIDC_ISSUER"                "${KEYCLOAK_URL}"
    write_or_update_config "KC_GATEWAY_CLIENT_ID"       "stroma-gateway"
    write_or_update_config "KC_GATEWAY_CLIENT_SECRET"   "${GW_CLIENT_SECRET}"
    write_or_update_config "KC_OPENWEBUI_CLIENT_ID"     "openwebui"
    write_or_update_config "KC_OPENWEBUI_CLIENT_SECRET" "${OWU_CLIENT_SECRET}"
    write_or_update_config "KC_ADMIN_URL"               "http://${KC_HOSTNAME}:${KC_PORT}"

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
