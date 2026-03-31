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
#   deploy/openwebui/.env  — compose env file (auto-sourced by docker compose)
#   /opt/stroma-ai/config.env — OPENWEBUI_URL added for other tools
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"
CONFIG_ENV="${STROMA_CONFIG_ENV:-/opt/stroma-ai/config.env}"
COMPOSE_ENV="${SCRIPT_DIR}/.env"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
info()    { printf '\033[1;34m[INFO]\033[0m  %s\n' "$*"; }
success() { printf '\033[1;32m[OK]\033[0m    %s\n' "$*"; }
warn()    { printf '\033[1;33m[WARN]\033[0m  %s\n' "$*"; }
err()     { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; }
die()     { err "$*"; exit 1; }

require_cmd() { command -v "$1" &>/dev/null || die "Required command not found: $1"; }

gen_secret() {
  python3 -c "import secrets; print(secrets.token_hex(32))" 2>/dev/null \
    || openssl rand -hex 32
}

read_config_var() {
  # Read a variable from CONFIG_ENV file
  local key="$1"
  grep -E "^${key}=" "${CONFIG_ENV}" 2>/dev/null | cut -d= -f2- || true
}

write_or_update_config() {
  local key="$1" value="$2"
  if [[ ! -f "${CONFIG_ENV}" ]]; then
    mkdir -p "$(dirname "${CONFIG_ENV}")"
    touch "${CONFIG_ENV}"
    chmod 640 "${CONFIG_ENV}"
  fi
  if grep -qE "^${key}=" "${CONFIG_ENV}" 2>/dev/null; then
    sed -i "s|^${key}=.*|${key}=${value}|" "${CONFIG_ENV}"
  else
    echo "${key}=${value}" >> "${CONFIG_ENV}"
  fi
}

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------
echo
echo "┌─────────────────────────────────────────────────────────┐"
echo "│       StromaAI  —  OpenWebUI Setup                       │"
echo "│       deploy/openwebui/setup-openwebui.sh                │"
echo "└─────────────────────────────────────────────────────────┘"
echo

# ---------------------------------------------------------------------------
# Verify OIDC config exists
# ---------------------------------------------------------------------------
OIDC_DISCOVERY_URL="$(read_config_var OIDC_DISCOVERY_URL)"
if [[ -z "${OIDC_DISCOVERY_URL}" ]]; then
  die "OIDC_DISCOVERY_URL not found in ${CONFIG_ENV}. Run deploy/keycloak/setup-keycloak.sh first."
fi
success "Found OIDC_DISCOVERY_URL: ${OIDC_DISCOVERY_URL}"

KC_OPENWEBUI_CLIENT_ID="$(read_config_var KC_OPENWEBUI_CLIENT_ID)"
KC_OPENWEBUI_CLIENT_SECRET="$(read_config_var KC_OPENWEBUI_CLIENT_SECRET)"
if [[ -z "${KC_OPENWEBUI_CLIENT_ID}" || -z "${KC_OPENWEBUI_CLIENT_SECRET}" ]]; then
  die "OpenWebUI OIDC client credentials not found in ${CONFIG_ENV}. Run setup-keycloak.sh first."
fi

# ---------------------------------------------------------------------------
# Mode selection
# ---------------------------------------------------------------------------
echo "Select OpenWebUI deployment mode:"
echo "  1) LOCAL    — Deploy OpenWebUI container on this host"
echo "  2) EXTERNAL — Register an existing OpenWebUI instance"
echo
read -rp "Enter choice [1/2]: " MODE_CHOICE

case "${MODE_CHOICE}" in
  1) MODE="local" ;;
  2) MODE="external" ;;
  *) die "Invalid choice: ${MODE_CHOICE}" ;;
esac

# ===========================================================================
# MODE: LOCAL
# ===========================================================================
if [[ "${MODE}" == "local" ]]; then

  require_cmd docker
  docker compose version &>/dev/null || die "Docker Compose plugin not found"

  # Gather settings
  read -rp "OpenWebUI host port [default: 3000]: " OWU_PORT
  OWU_PORT="${OWU_PORT:-3000}"

  # Gateway URL — what the OpenWebUI container uses to reach the FastAPI gateway
  read -rp "StromaAI Gateway URL (from inside Docker) [default: http://host.docker.internal:9000]: " GATEWAY_URL
  GATEWAY_URL="${GATEWAY_URL:-http://host.docker.internal:9000}"

  read -rp "WebUI display name [default: StromaAI Research Chat]: " WEBUI_NAME
  WEBUI_NAME="${WEBUI_NAME:-StromaAI Research Chat}"

  read -rp "Allow new user self-registration via SSO? [Y/n]: " ALLOW_SIGNUP
  case "${ALLOW_SIGNUP,,}" in
    n|no) ENABLE_OAUTH_SIGNUP="false" ;;
    *)    ENABLE_OAUTH_SIGNUP="true" ;;
  esac

  WEBUI_SECRET_KEY="$(gen_secret)"

  # Write compose .env
  info "Writing ${COMPOSE_ENV} ..."
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

  # Start
  info "Starting OpenWebUI via Docker Compose..."
  docker compose --project-directory "${SCRIPT_DIR}" up -d

  # Wait for health
  MAX_WAIT=90 ; WAITED=0
  info "Waiting for OpenWebUI to become healthy..."
  while ! curl -sf --max-time 3 "http://localhost:${OWU_PORT}/health" &>/dev/null; do
    sleep 5 ; WAITED=$((WAITED + 5))
    (( WAITED >= MAX_WAIT )) && die "OpenWebUI did not become healthy within ${MAX_WAIT}s. Check: docker compose logs openwebui"
    printf '.'
  done
  echo
  success "OpenWebUI is healthy"

  OPENWEBUI_URL="http://localhost:${OWU_PORT}"
  write_or_update_config "OPENWEBUI_URL" "${OPENWEBUI_URL}"

  echo
  success "OpenWebUI deployment complete!"
  echo
  echo "  URL     : ${OPENWEBUI_URL}"
  echo "  Login   : Click 'Continue with StromaAI Identity' on the login page"
  echo "  Backend : ${GATEWAY_URL}/v1"
  echo

# ===========================================================================
# MODE: EXTERNAL
# ===========================================================================
else

  echo
  info "External OpenWebUI registration"
  read -rp "OpenWebUI URL (e.g. https://openwebui.your-cluster.example): " EXT_OWU_URL
  [[ -z "${EXT_OWU_URL}" ]] && die "URL cannot be empty"

  # Validate reachability
  info "Checking connectivity to ${EXT_OWU_URL} ..."
  curl -sf --max-time 10 "${EXT_OWU_URL}/health" &>/dev/null \
    || warn "Could not reach ${EXT_OWU_URL}/health — proceeding anyway (may be internal-only)"

  write_or_update_config "OPENWEBUI_URL" "${EXT_OWU_URL}"

  echo
  success "External OpenWebUI registered."
  echo
  warn "Ensure the external OpenWebUI is configured with:"
  echo "  OPENID_PROVIDER_URL   = ${OIDC_DISCOVERY_URL}"
  echo "  OAUTH_CLIENT_ID       = ${KC_OPENWEBUI_CLIENT_ID}"
  echo "  OPENAI_API_BASE_URL   = <StromaAI Gateway URL>/v1"
  echo
fi

success "OpenWebUI setup complete."
echo "  Next step: run  python3 src/stroma_cli.py --status  to verify all components"
