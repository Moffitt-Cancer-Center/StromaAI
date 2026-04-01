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
# Requirements (LOCAL mode): podman, podman-compose
# Requirements (EXTERNAL mode): none
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

require_cmd() {
  command -v "$1" &>/dev/null || die "Required command not found: $1"
}

gen_secret() {
  # 32 random bytes → hex (64 chars), no openssl dependency branch
  python3 -c "import secrets; print(secrets.token_hex(32))" 2>/dev/null \
    || openssl rand -hex 32
}

write_or_update_config() {
  # Writes KEY=VALUE to CONFIG_ENV, replacing the line if the key already exists.
  local key="$1" value="$2"
  if [[ ! -f "${CONFIG_ENV}" ]]; then
    mkdir -p "$(dirname "${CONFIG_ENV}")"
    touch "${CONFIG_ENV}"
    chmod 640 "${CONFIG_ENV}"
  fi
  if grep -qE "^${key}=" "${CONFIG_ENV}" 2>/dev/null; then
    # Replace existing
    sed -i "s|^${key}=.*|${key}=${value}|" "${CONFIG_ENV}"
  else
    echo "${key}=${value}" >> "${CONFIG_ENV}"
  fi
}

wait_for_keycloak() {
  local url="$1" max_wait=120 waited=0
  info "Waiting for Keycloak to become healthy at ${url} ..."
  while ! curl -sf --max-time 3 "${url}/health/ready" &>/dev/null; do
    sleep 5
    waited=$((waited + 5))
    if (( waited >= max_wait )); then
      die "Keycloak did not become healthy within ${max_wait}s. Check: podman compose logs keycloak"
    fi
    printf '.'
  done
  echo
  success "Keycloak is healthy"
}

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------
echo
echo "┌─────────────────────────────────────────────────────────┐"
echo "│       StromaAI  —  Identity Provider Setup               │"
echo "│       deploy/keycloak/setup-keycloak.sh                  │"
echo "└─────────────────────────────────────────────────────────┘"
echo

# ---------------------------------------------------------------------------
# Mode selection
# ---------------------------------------------------------------------------
echo "Select identity provider mode:"
echo "  1) LOCAL    — Deploy Keycloak 26.x container (recommended for standalone)"
echo "  2) EXTERNAL — Use an existing institutional IdP (Okta, Azure AD, etc.)"
echo
read -rp "Enter choice [1/2]: " MODE_CHOICE

case "${MODE_CHOICE}" in
  1) MODE="local" ;;
  2) MODE="external" ;;
  *) die "Invalid choice: ${MODE_CHOICE}. Run the script again and enter 1 or 2." ;;
esac

# ===========================================================================
# MODE: LOCAL
# ===========================================================================
if [[ "${MODE}" == "local" ]]; then

  require_cmd podman
  podman compose version &>/dev/null || die "podman-compose not found. Install: dnf install podman-compose  or  pip install podman-compose"

  info "Generating cryptographic secrets..."
  KC_DB_PASSWORD="$(gen_secret)"
  KC_ADMIN_PASSWORD="$(gen_secret)"
  GW_CLIENT_SECRET="$(gen_secret)"
  OWU_CLIENT_SECRET="$(gen_secret)"
  DEMO_USER_PASSWORD="$(gen_secret)"

  # Prompt for optional hostname override
  read -rp "Keycloak hostname [default: localhost]: " KC_HOSTNAME
  KC_HOSTNAME="${KC_HOSTNAME:-localhost}"

  read -rp "Keycloak HTTP port [default: 8080]: " KC_PORT
  KC_PORT="${KC_PORT:-8080}"

  # ---------------------------------------------------------------------------
  # Write compose .env (secrets for podman compose only — never committed)
  # ---------------------------------------------------------------------------
  info "Writing ${COMPOSE_ENV} ..."
  cat > "${COMPOSE_ENV}" <<EOF
# Auto-generated by setup-keycloak.sh — do NOT commit this file
KC_DB_PASSWORD=${KC_DB_PASSWORD}
KC_ADMIN_USER=admin
KC_ADMIN_PASSWORD=${KC_ADMIN_PASSWORD}
KC_HOSTNAME=${KC_HOSTNAME}
KC_PORT=${KC_PORT}
EOF
  chmod 600 "${COMPOSE_ENV}"

  # ---------------------------------------------------------------------------
  # Patch realm-export.json with generated secrets
  # ---------------------------------------------------------------------------
  info "Patching realm-export.json with generated client secrets..."
  REALM_FILE="${SCRIPT_DIR}/realm-export.json"
  REALM_TMP="${REALM_FILE}.tmp"

  python3 - <<PYEOF
import json, sys

with open("${REALM_FILE}") as f:
    realm = json.load(f)

for client in realm.get("clients", []):
    if client["clientId"] == "stroma-gateway":
        client["secret"] = "${GW_CLIENT_SECRET}"
    elif client["clientId"] == "openwebui":
        client["secret"] = "${OWU_CLIENT_SECRET}"
        # Patch redirect URIs for local deployment
        client["redirectUris"] = [
            "http://${KC_HOSTNAME}:3000/*",
            "http://localhost:3000/*",
        ]

for user in realm.get("users", []):
    for cred in user.get("credentials", []):
        if cred["type"] == "password":
            cred["value"] = "${DEMO_USER_PASSWORD}"

with open("${REALM_TMP}", "w") as f:
    json.dump(realm, f, indent=2)
PYEOF

  mv "${REALM_TMP}" "${REALM_FILE}"
  success "realm-export.json patched"

  # ---------------------------------------------------------------------------
  # Start services
  # ---------------------------------------------------------------------------
  info "Starting Keycloak + PostgreSQL via Podman Compose..."
  podman compose --project-directory "${SCRIPT_DIR}" up -d

  KEYCLOAK_URL="http://${KC_HOSTNAME}:${KC_PORT}/realms/stroma-ai"
  wait_for_keycloak "http://${KC_HOSTNAME}:${KC_PORT}"

  OIDC_DISCOVERY_URL="${KEYCLOAK_URL}/.well-known/openid-configuration"

  # ---------------------------------------------------------------------------
  # Write OIDC variables to platform config
  # ---------------------------------------------------------------------------
  info "Writing OIDC configuration to ${CONFIG_ENV} ..."
  write_or_update_config "OIDC_DISCOVERY_URL"       "${OIDC_DISCOVERY_URL}"
  write_or_update_config "OIDC_ISSUER"              "${KEYCLOAK_URL}"
  write_or_update_config "KC_GATEWAY_CLIENT_ID"     "stroma-gateway"
  write_or_update_config "KC_GATEWAY_CLIENT_SECRET" "${GW_CLIENT_SECRET}"
  write_or_update_config "KC_OPENWEBUI_CLIENT_ID"   "openwebui"
  write_or_update_config "KC_OPENWEBUI_CLIENT_SECRET" "${OWU_CLIENT_SECRET}"
  write_or_update_config "KC_ADMIN_URL"             "http://${KC_HOSTNAME}:${KC_PORT}"

  echo
  success "Local Keycloak deployment complete!"
  echo
  echo "  Admin console : http://${KC_HOSTNAME}:${KC_PORT}/admin"
  echo "  Admin user    : admin"
  echo "  Admin password: ${KC_ADMIN_PASSWORD}"
  echo "  Demo user     : researcher-demo  (password: ${DEMO_USER_PASSWORD})"
  echo
  warn "Save these credentials — they will not be displayed again."
  warn "Demo user password is set as TEMPORARY — user must change on first login."
  echo

# ===========================================================================
# MODE: EXTERNAL
# ===========================================================================
else

  echo
  info "External IdP configuration"
  echo "You will need the following from your institutional IdP administrator:"
  echo "  • OIDC Discovery URL  (ends in /.well-known/openid-configuration)"
  echo "  • Client ID for the StromaAI gateway"
  echo "  • Client Secret for the StromaAI gateway"
  echo "  • Client ID for OpenWebUI"
  echo "  • Client Secret for OpenWebUI"
  echo

  read -rp "OIDC Discovery URL: " EXT_DISCOVERY_URL
  [[ -z "${EXT_DISCOVERY_URL}" ]] && die "Discovery URL cannot be empty"

  # Validate the URL is reachable and returns JSON
  info "Validating discovery URL..."
  DISCOVERY_JSON=$(curl -sf --max-time 10 "${EXT_DISCOVERY_URL}") \
    || die "Cannot reach discovery URL: ${EXT_DISCOVERY_URL}"

  EXT_ISSUER=$(echo "${DISCOVERY_JSON}" | python3 -c "import json,sys; print(json.load(sys.stdin)['issuer'])" 2>/dev/null) \
    || die "Discovery document does not contain 'issuer' field"
  success "Issuer: ${EXT_ISSUER}"

  read -rp "Gateway Client ID [default: stroma-gateway]: " EXT_GW_CLIENT_ID
  EXT_GW_CLIENT_ID="${EXT_GW_CLIENT_ID:-stroma-gateway}"

  read -rsp "Gateway Client Secret: " EXT_GW_SECRET
  echo
  [[ -z "${EXT_GW_SECRET}" ]] && die "Gateway client secret cannot be empty"

  read -rp "OpenWebUI Client ID [default: openwebui]: " EXT_OWU_CLIENT_ID
  EXT_OWU_CLIENT_ID="${EXT_OWU_CLIENT_ID:-openwebui}"

  read -rsp "OpenWebUI Client Secret: " EXT_OWU_SECRET
  echo
  [[ -z "${EXT_OWU_SECRET}" ]] && die "OpenWebUI client secret cannot be empty"

  # Write to config
  info "Writing OIDC configuration to ${CONFIG_ENV} ..."
  write_or_update_config "OIDC_DISCOVERY_URL"         "${EXT_DISCOVERY_URL}"
  write_or_update_config "OIDC_ISSUER"                "${EXT_ISSUER}"
  write_or_update_config "KC_GATEWAY_CLIENT_ID"       "${EXT_GW_CLIENT_ID}"
  write_or_update_config "KC_GATEWAY_CLIENT_SECRET"   "${EXT_GW_SECRET}"
  write_or_update_config "KC_OPENWEBUI_CLIENT_ID"     "${EXT_OWU_CLIENT_ID}"
  write_or_update_config "KC_OPENWEBUI_CLIENT_SECRET" "${EXT_OWU_SECRET}"
  write_or_update_config "KC_ADMIN_URL"               ""

  echo
  success "External IdP configuration written to ${CONFIG_ENV}"
  echo
  warn "Ensure roles are mapped to the 'realm_access.roles' JWT claim."
  warn "Users must have the 'stroma_researcher' role assigned for API access."
  echo
fi

# ---------------------------------------------------------------------------
# Common tail: verify discovery URL is in config
# ---------------------------------------------------------------------------
info "Verifying ${CONFIG_ENV} ..."
grep -q "OIDC_DISCOVERY_URL" "${CONFIG_ENV}" \
  || die "OIDC_DISCOVERY_URL not found in ${CONFIG_ENV} — something went wrong"

success "Identity provider setup complete."
echo "  Next step: run  deploy/keycloak/../gateway/setup-gateway.sh"
echo "             or:  python3 src/stroma_cli.py --setup"
