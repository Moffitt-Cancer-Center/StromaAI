#!/usr/bin/env bash
# =============================================================================
# StromaAI — OpenWebUI Setup
# =============================================================================
# Configures and optionally starts the OpenWebUI front-end. Supports:
#
#   1. LOCAL   — Deploys an OpenWebUI container on this host, wired to the
#                OIDC provider and gateway already configured in config.env.
#
#   2. EXTERNAL — Records connectivity details for an existing OpenWebUI
#                instance so stroma-cli.py can reference it.
#
# Prerequisite: setup-keycloak.sh must have been run first (or OIDC_DISCOVERY_URL
# must already be set in STROMA_CONFIG_ENV) so that OIDC variables are present.
#
# Output:
#   deploy/openwebui/.env      — compose env file (auto-sourced by podman compose)
#   /opt/stroma-ai/config.env  — OPENWEBUI_URL added for other tools
#
# Usage:
#   ./setup-openwebui.sh                           # interactive wizard
#   ./setup-openwebui.sh --mode=local              # non-interactive local deploy
#   ./setup-openwebui.sh --mode=external           # non-interactive external
#   ./setup-openwebui.sh --config=/path/to/.env    # explicit config path
#   ./setup-openwebui.sh --dry-run --yes           # print without executing
#   ./setup-openwebui.sh -h | --help
#
# Options:
#   --mode=local      Deploy OpenWebUI container on this host non-interactively
#   --mode=external   Register an existing OpenWebUI instance non-interactively
#   --config=FILE     Path to platform config.env (default: /opt/stroma-ai/config.env)
#   --dry-run         Print commands without executing them
#   --yes             Non-interactive: auto-confirm all prompts
#   -h, --help        Show this help message
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# ---------------------------------------------------------------------------
# Source shared library
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
  --mode=local      Deploy OpenWebUI container on this host non-interactively
  --mode=external   Register an existing OpenWebUI instance non-interactively
  --config=FILE     Path to platform config.env
                    (default: /opt/stroma-ai/config.env)
  --dry-run         Print commands without executing them
  --yes             Non-interactive (auto-confirm all prompts)
  -h, --help        Show this help message

Prerequisite: setup-keycloak.sh must be run first (sets OIDC_DISCOVERY_URL).
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
# Detect Podman Compose
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

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║   StromaAI — OpenWebUI Setup                          ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════╝${RESET}"
echo ""

if [[ "${STROMA_DRY_RUN:-0}" == "1" ]]; then
    log_warn "DRY-RUN mode — no changes will be made."
    echo ""
fi

detect_os
log_info "OS: ${OS_PRETTY:-unknown}"

require_cmd python3
require_cmd curl

# ---------------------------------------------------------------------------
# Verify OIDC config exists (set by setup-keycloak.sh)
# ---------------------------------------------------------------------------
log_step "Verifying prerequisite OIDC configuration"

if [[ "${STROMA_DRY_RUN:-0}" != "1" ]]; then
    OIDC_DISCOVERY_URL="$(read_config_var OIDC_DISCOVERY_URL)"
    if [[ -z "${OIDC_DISCOVERY_URL}" ]]; then
        die "OIDC_DISCOVERY_URL not found in ${CONFIG_ENV}.\n  Run deploy/keycloak/setup-keycloak.sh first."
    fi
    log_ok "OIDC_DISCOVERY_URL: ${OIDC_DISCOVERY_URL}"

    KC_OPENWEBUI_CLIENT_ID="$(read_config_var KC_OPENWEBUI_CLIENT_ID)"
    KC_OPENWEBUI_CLIENT_SECRET="$(read_config_var KC_OPENWEBUI_CLIENT_SECRET)"
    if [[ -z "${KC_OPENWEBUI_CLIENT_ID}" || -z "${KC_OPENWEBUI_CLIENT_SECRET}" ]]; then
        die "OpenWebUI OIDC client credentials not found in ${CONFIG_ENV}.\n  Run setup-keycloak.sh first."
    fi
else
    OIDC_DISCOVERY_URL="${OIDC_DISCOVERY_URL:-<from config.env>}"
    KC_OPENWEBUI_CLIENT_ID="${KC_OPENWEBUI_CLIENT_ID:-openwebui}"
    KC_OPENWEBUI_CLIENT_SECRET="${KC_OPENWEBUI_CLIENT_SECRET:-<from config.env>}"
    log_dry "Would read OIDC_DISCOVERY_URL and client credentials from ${CONFIG_ENV}"
fi

# ---------------------------------------------------------------------------
# Mode selection
# ---------------------------------------------------------------------------
if [[ -z "${MODE}" ]]; then
    echo "Select OpenWebUI deployment mode:"
    echo "  1) LOCAL    — Deploy OpenWebUI container on this host"
    echo "  2) EXTERNAL — Register an existing OpenWebUI instance"
    echo ""
    read -rp "Enter choice [1/2]: " MODE_CHOICE
    case "${MODE_CHOICE}" in
        1) MODE="local" ;;
        2) MODE="external" ;;
        *) die "Invalid choice: ${MODE_CHOICE}" ;;
    esac
fi

# ===========================================================================
# MODE: LOCAL
# ===========================================================================
if [[ "${MODE}" == "local" ]]; then

    detect_compose

    log_step "Gathering deployment settings"

    if [[ "${STROMA_YES:-0}" == "1" ]]; then
        OWU_PORT="${OWU_PORT:-3000}"
        GATEWAY_URL="${GATEWAY_URL:-http://host.containers.internal:9000}"
        WEBUI_NAME="${WEBUI_NAME:-StromaAI Research Chat}"
        ENABLE_OAUTH_SIGNUP="true"
    else
        read -rp "OpenWebUI host port [default: 3000]: " _inp
        OWU_PORT="${_inp:-3000}"

        read -rp "StromaAI Gateway URL (from inside Podman) [default: http://host.containers.internal:9000]: " _inp
        GATEWAY_URL="${_inp:-http://host.containers.internal:9000}"

        read -rp "WebUI display name [default: StromaAI Research Chat]: " _inp
        WEBUI_NAME="${_inp:-StromaAI Research Chat}"

        read -rp "Allow new user self-registration via SSO? [Y/n]: " _inp
        case "${_inp,,}" in
            n|no) ENABLE_OAUTH_SIGNUP="false" ;;
            *)    ENABLE_OAUTH_SIGNUP="true" ;;
        esac
        unset _inp
    fi

    WEBUI_SECRET_KEY="$(gen_secret)"

    # -------------------------------------------------------------------------
    # Write compose .env
    # -------------------------------------------------------------------------
    log_step "Writing ${COMPOSE_ENV}"
    backup_file "${COMPOSE_ENV}"
    if [[ "${STROMA_DRY_RUN:-0}" != "1" ]]; then
        cat > "${COMPOSE_ENV}" <<EOF
# Auto-generated by setup-openwebui.sh — do NOT commit this file
OPENWEBUI_PORT=${OWU_PORT}
WEBUI_NAME=${WEBUI_NAME}
STROMA_GATEWAY_URL=${GATEWAY_URL}
STROMA_GATEWAY_API_KEY=not-used-gateway-validates-oidc
OIDC_DISCOVERY_URL=${OIDC_DISCOVERY_URL}
KC_OPENWEBUI_CLIENT_ID=${KC_OPENWEBUI_CLIENT_ID}
KC_OPENWEBUI_CLIENT_SECRET=${KC_OPENWEBUI_CLIENT_SECRET}
ENABLE_OAUTH_SIGNUP=${ENABLE_OAUTH_SIGNUP}
WEBUI_SECRET_KEY=${WEBUI_SECRET_KEY}
OAUTH_PROVIDER_NAME=StromaAI Identity
EOF
        chmod 600 "${COMPOSE_ENV}"
    else
        log_dry "Would write ${COMPOSE_ENV} with OPENWEBUI_PORT=${OWU_PORT} GATEWAY=${GATEWAY_URL}"
    fi

    # -------------------------------------------------------------------------
    # Start services
    # -------------------------------------------------------------------------
    log_step "Starting OpenWebUI via Podman Compose"
    run_cmd ${COMPOSE_CMD} -f "${SCRIPT_DIR}/docker-compose.yml" up -d

    # -------------------------------------------------------------------------
    # Wait for health
    # -------------------------------------------------------------------------
    if [[ "${STROMA_DRY_RUN:-0}" != "1" ]]; then
        MAX_WAIT=90; WAITED=0
        log_info "Waiting for OpenWebUI to become healthy..."
        while ! curl -sf --max-time 3 "http://localhost:${OWU_PORT}/health" &>/dev/null; do
            sleep 5; WAITED=$((WAITED + 5))
            (( WAITED >= MAX_WAIT )) && die "OpenWebUI did not become healthy within ${MAX_WAIT}s.\n  Check: ${COMPOSE_CMD} logs openwebui"
            printf '.'
        done
        echo
        log_ok "OpenWebUI is healthy"
    else
        log_dry "Would wait for OpenWebUI health at http://localhost:${OWU_PORT}/health"
    fi

    OPENWEBUI_URL="http://localhost:${OWU_PORT}"
    write_or_update_config "OPENWEBUI_URL" "${OPENWEBUI_URL}"

    echo ""
    echo -e "${BOLD}╔══════════════════════════════════════════════════════╗${RESET}"
    echo -e "${BOLD}║   OpenWebUI Local Deployment — Summary                ║${RESET}"
    echo -e "${BOLD}╚══════════════════════════════════════════════════════╝${RESET}"
    echo ""
    echo "  URL     : ${OPENWEBUI_URL}"
    echo "  Login   : Click 'Continue with StromaAI Identity' on the login page"
    echo "  Backend : ${GATEWAY_URL}/v1"
    echo ""
    echo "  Next: ./deploy/head/setup-head.sh"
    echo ""

# ===========================================================================
# MODE: EXTERNAL
# ===========================================================================
else

    echo ""
    log_step "External OpenWebUI registration"

    read -rp "OpenWebUI URL (e.g. https://openwebui.your-cluster.example): " EXT_OWU_URL
    [[ -z "${EXT_OWU_URL}" ]] && die "URL cannot be empty"

    if [[ "${STROMA_DRY_RUN:-0}" != "1" ]]; then
        log_info "Checking connectivity to ${EXT_OWU_URL} ..."
        curl -sf --max-time 10 "${EXT_OWU_URL}/health" &>/dev/null \
            || log_warn "Could not reach ${EXT_OWU_URL}/health — proceeding (may be internal-only)"
    else
        log_dry "Would check connectivity to ${EXT_OWU_URL}/health"
    fi

    write_or_update_config "OPENWEBUI_URL" "${EXT_OWU_URL}"

    echo ""
    echo -e "${BOLD}╔══════════════════════════════════════════════════════╗${RESET}"
    echo -e "${BOLD}║   External OpenWebUI — Configuration Written          ║${RESET}"
    echo -e "${BOLD}╚══════════════════════════════════════════════════════╝${RESET}"
    echo ""
    echo "  OpenWebUI URL : ${EXT_OWU_URL}"
    echo "  Config file   : ${CONFIG_ENV}"
    echo ""
    log_warn "Ensure the external OpenWebUI is configured with:"
    echo "  OPENID_PROVIDER_URL   = ${OIDC_DISCOVERY_URL}"
    echo "  OAUTH_CLIENT_ID       = ${KC_OPENWEBUI_CLIENT_ID}"
    echo "  OPENAI_API_BASE_URL   = <StromaAI Gateway URL>/v1"
    echo ""
    echo "  Next: ./deploy/head/setup-head.sh"
    echo ""
fi

if [[ "${STROMA_DRY_RUN:-0}" != "1" ]]; then
    log_ok "OpenWebUI setup complete."
else
    log_ok "Dry-run complete — no changes made."
fi
