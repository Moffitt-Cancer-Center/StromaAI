#!/usr/bin/env bash
# =============================================================================
# StromaAI — Dev / POC / Demo Environment Manager
# =============================================================================
# This script manages a full, single-host StromaAI stack for development,
# proof-of-concept demos, and integration testing.
#
# It automatically:
#   - Detects the host's primary network interface IP
#   - Generates all secrets and writes dev/.env
#   - Creates a dev/dev-data/ directory tree (acts as the "network fileshare")
#   - Auto-generates a self-signed TLS certificate for nginx
#   - Installs the CNI dnsname plugin if missing (RHEL 8 Podman requirement)
#   - Starts all containers with a single command
#
# Usage:
#   ./dev.sh up                  # auth/UI/gateway stack (fastest; no inference)
#   ./dev.sh up --inference      # + ray-head and vLLM (needs model weights)
#   ./dev.sh up --watcher        # + Slurm burst scaler (needs sbatch on host)
#   ./dev.sh up --full           # everything
#   ./dev.sh down                # stop and remove containers (volumes kept)
#   ./dev.sh restart [SERVICE]   # restart one service or the whole stack
#   ./dev.sh build               # rebuild gateway and watcher images
#   ./dev.sh logs [SERVICE]      # follow logs (all services or specific one)
#   ./dev.sh ps                  # container status
#   ./dev.sh status              # health summary (ports, URLs, readiness)
#   ./dev.sh clean               # remove containers, volumes, certs, and .env
#   ./dev.sh ip                  # print the detected host IP
#   ./dev.sh commit [VERSION]    # commit running containers to registry-named images
#                                  VERSION defaults to date-based tag (e.g. 2026.04.01)
#   ./dev.sh push [VERSION]      # push committed images to the registry
#   ./dev.sh pull                # pull all images from registry (skips missing ones)
#
# Options (used with 'up'):
#   --inference        Include the ray-head + vLLM inference stack
#   --watcher          Include the Slurm burst scaler (requires sbatch on host)
#   --full             Equivalent to --inference --watcher
#   --model-path=PATH  Override the model weights directory
#   --port=PORT        Override STROMA_HTTPS_PORT (nginx TLS, default 443)
#   --registry=URL     Override the container registry (default: dockerhub.moffitt.org/hpc)
#   --no-registry      Skip registry pull; always use upstream/build images
#   --dry-run          Print commands without executing them
#   --rebuild          Force rebuild of custom images before starting
#   -h, --help         Show this help
#
# Registry:
#   Images are pulled from STROMA_REGISTRY (default: dockerhub.moffitt.org/hpc) first.
#   If an image is not found there, the upstream public image is used / built locally.
#   Set STROMA_REGISTRY in your environment or via --registry= to use your institution's
#   internal registry (e.g. harbor.myorg.edu/stroma or registry.hospital.org/ai).
#
#   Image naming convention:
#     kc-*     images: Keycloak ecosystem (postgres, keycloak)
#     stroma-* images: StromaAI stack (gateway, nginx, openwebui, ray, vllm, watcher)
#
# Files managed:
#   dev/.env           — generated secrets and configuration (git-ignored)
#   dev/dev-data/      — local stand-in for the HPC network fileshare
#     models/          — model weights directory (symlink your weights here)
#     shared/          — STROMA_SHARED_ROOT (logs, slurm scripts, state)
#     certs/           — self-signed TLS certificate for nginx
#
# Requirements:
#   podman, podman-compose OR 'podman compose', openssl, python3
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
DEV_ENV="${SCRIPT_DIR}/.env"
DEV_DATA="${SCRIPT_DIR}/dev-data"
CERT_DIR="${DEV_DATA}/certs"
REALM_DIR="${DEV_DATA}/realm"
MODELS_DIR="${DEV_DATA}/models"
SHARED_DIR="${DEV_DATA}/shared"

# ---------------------------------------------------------------------------
# Colours
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
    RED='\033[0;31m' YELLOW='\033[1;33m' GREEN='\033[0;32m'
    CYAN='\033[0;36m' BOLD='\033[1m' DIM='\033[2m' RESET='\033[0m'
else
    RED='' YELLOW='' GREEN='' CYAN='' BOLD='' DIM='' RESET=''
fi

log_info()  { echo -e "${CYAN}[INFO]${RESET}  $*"; }
log_ok()    { echo -e "${GREEN}[ OK ]${RESET}  $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${RESET}  $*" >&2; }
log_error() { echo -e "${RED}[ERR ]${RESET}  $*" >&2; }
log_step()  { echo -e "\n${BOLD}▸ $*${RESET}"; }
log_dry()   { echo -e "${YELLOW}[DRY ]${RESET}  $*"; }
die()       { log_error "$*"; exit 1; }

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
usage() {
    grep '^#' "${BASH_SOURCE[0]}" | grep -v '^#!/' | sed 's/^# \{0,1\}//' | \
        awk '/^Usage:/,/^Requirements:/' | head -n -1
    exit 0
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
SUBCMD=""
PROFILE_INFERENCE=0
PROFILE_WATCHER=0
_DEV_FRESH_DB_PASS=0   # set to 1 if KC_DB_PASSWORD was freshly generated (not read from .env)
MODEL_PATH_OVERRIDE=""
HTTPS_PORT_OVERRIDE=""
DRY_RUN=0
DO_REBUILD=0
SERVICE_ARG=""
VERSION_ARG=""
SKIP_REGISTRY=0
REGISTRY_OVERRIDE=""

for _arg in "$@"; do
    case "${_arg}" in
        up|down|restart|build|logs|ps|status|clean|ip|commit|push|pull)
            SUBCMD="${_arg}" ;;
        --inference)    PROFILE_INFERENCE=1 ;;
        --watcher)      PROFILE_WATCHER=1 ;;
        --full)         PROFILE_INFERENCE=1; PROFILE_WATCHER=1 ;;
        --model-path=*) MODEL_PATH_OVERRIDE="${_arg#--model-path=}" ;;
        --port=*)       HTTPS_PORT_OVERRIDE="${_arg#--port=}" ;;
        --registry=*)   REGISTRY_OVERRIDE="${_arg#--registry=}" ;;
        --no-registry)  SKIP_REGISTRY=1 ;;
        --dry-run)      DRY_RUN=1 ;;
        --rebuild)      DO_REBUILD=1 ;;
        -h|--help)      usage ;;
        -*)             die "Unknown option: ${_arg}. Use --help for usage." ;;
        *)              # positional: version for commit/push, service name for logs/restart
                        if [[ -z "${VERSION_ARG}" && "${_arg}" =~ ^[0-9a-zA-Z._-]+$ ]]; then
                            VERSION_ARG="${_arg}"
                        fi
                        SERVICE_ARG="${_arg}" ;;
    esac
done
unset _arg

# ---------------------------------------------------------------------------
# Registry configuration
# Institutions should set STROMA_REGISTRY in their environment or via
# --registry= to override.  The value should NOT have a trailing slash.
# ---------------------------------------------------------------------------
STROMA_REGISTRY="${REGISTRY_OVERRIDE:-${STROMA_REGISTRY:-dockerhub.moffitt.org/hpc}}"

# Canonical image names in the registry
# kc- prefix  : Keycloak ecosystem images
# stroma- prefix: StromaAI stack images
declare -A REGISTRY_IMAGE=(
    [postgres]="${STROMA_REGISTRY}/kc-postgres"
    [keycloak]="${STROMA_REGISTRY}/kc-keycloak"
    [gateway]="${STROMA_REGISTRY}/stroma-gateway"
    [nginx]="${STROMA_REGISTRY}/stroma-nginx"
    [openwebui]="${STROMA_REGISTRY}/stroma-openwebui"
    [ray-head]="${STROMA_REGISTRY}/stroma-ray"
    [vllm]="${STROMA_REGISTRY}/stroma-vllm"
    [watcher]="${STROMA_REGISTRY}/stroma-watcher"
)

# Upstream fallback images (used when registry image is not available)
declare -A UPSTREAM_IMAGE=(
    [postgres]="postgres:16-alpine"
    [keycloak]="quay.io/keycloak/keycloak:26.0"
    [nginx]="nginx:1.27-alpine"
    [openwebui]="ghcr.io/open-webui/open-webui:v0.5.20"
    [ray-head]="rayproject/ray:2.40.0-py311"
    [vllm]="vllm/vllm-openai:v0.7.2"
    # gateway and watcher have no upstream — always built locally
)

# Services that must be built locally (no upstream public image)
LOCAL_BUILD_SERVICES=(gateway watcher)

[[ -z "${SUBCMD}" ]] && { usage; }

# ---------------------------------------------------------------------------
# run_cmd — dry-run aware command runner
# ---------------------------------------------------------------------------
run_cmd() {
    if [[ "${DRY_RUN}" -eq 1 ]]; then
        log_dry "$*"
        return 0
    fi
    "$@"
}

# ---------------------------------------------------------------------------
# default_version — date-based version tag  YYYY.MM.DD
# ---------------------------------------------------------------------------
default_version() { date +%Y.%m.%d; }

# ---------------------------------------------------------------------------
# registry_host — extract the hostname[:port] from STROMA_REGISTRY
# ---------------------------------------------------------------------------
registry_host() { echo "${STROMA_REGISTRY%%/*}"; }

# ---------------------------------------------------------------------------
# registry_logged_in — return 0 if already authenticated to the registry
# ---------------------------------------------------------------------------
registry_logged_in() {
    local host; host=$(registry_host)
    # podman stores auth in ${XDG_RUNTIME_DIR}/containers/auth.json or
    # ~/.config/containers/auth.json — check both locations.
    local auth_files=(
        "${XDG_RUNTIME_DIR:-/run/user/$(id -u)}/containers/auth.json"
        "${HOME}/.config/containers/auth.json"
        "${HOME}/.docker/config.json"
    )
    for f in "${auth_files[@]}"; do
        if [[ -f "${f}" ]] && python3 -c "
import sys, json
try:
    data = json.load(open('${f}'))
    auths = data.get('auths', {})
    sys.exit(0 if any('${host}' in k for k in auths) else 1)
except Exception:
    sys.exit(1)
" 2>/dev/null; then
            return 0
        fi
    done
    return 1
}

# ---------------------------------------------------------------------------
# ensure_registry_login — check auth; prompt user to login if needed
# ---------------------------------------------------------------------------
ensure_registry_login() {
    local host; host=$(registry_host)
    if registry_logged_in; then
        log_ok "Registry auth: ${host}"
        return 0
    fi
    log_warn "Not logged in to ${host}"
    log_info "Run:  podman login ${host}"
    if [[ -t 0 ]]; then
        # Interactive — attempt login now
        read -r -p "$(echo -e "${CYAN}Username for ${host}: ${RESET}")" _reg_user
        run_cmd podman login --username "${_reg_user}" "${host}" || \
            die "Login to ${host} failed. Re-run after logging in manually."
        unset _reg_user
    else
        die "Not logged in to ${host}. Run: podman login ${host}"
    fi
}

# ---------------------------------------------------------------------------
# registry_image_exists FULL_IMAGE_REF — return 0 if the image exists in the
# registry (does NOT pull it; uses skopeo or a manifest inspect).
# ---------------------------------------------------------------------------
registry_image_exists() {
    local ref="$1"
    # skopeo is ideal; fall back to podman manifest inspect
    if command -v skopeo &>/dev/null; then
        skopeo inspect --no-creds "docker://${ref}" &>/dev/null
        return $?
    fi
    podman manifest inspect "${ref}" &>/dev/null
    return $?
}

# ---------------------------------------------------------------------------
# resolve_service_image SERVICE — print the image ref to use for SERVICE.
# Priority:
#   1. SKIP_REGISTRY=1 → upstream/build
#   2. Registry image exists → registry ref (with :latest tag)
#   3. Service is in LOCAL_BUILD_SERVICES → no image ref (will be built)
#   4. UPSTREAM_IMAGE entry → upstream public image
# Sets the global RESOLVED_IMAGE[SERVICE] associative array.
# ---------------------------------------------------------------------------
declare -A RESOLVED_IMAGE=()

resolve_all_images() {
    log_step "Resolving container images"
    if [[ "${SKIP_REGISTRY}" -eq 1 ]]; then
        log_info "Registry disabled (--no-registry) — using upstream/build images"
    else
        log_info "Registry: ${STROMA_REGISTRY}"
    fi

    local svc reg_ref upstream_ref
    for svc in "${!REGISTRY_IMAGE[@]}"; do
        reg_ref="${REGISTRY_IMAGE[${svc}]}:latest"
        upstream_ref="${UPSTREAM_IMAGE[${svc}]:-}"

        if [[ "${SKIP_REGISTRY}" -eq 0 ]] && registry_image_exists "${reg_ref}"; then
            RESOLVED_IMAGE[${svc}]="${reg_ref}"
            log_ok "  ${svc}: ${reg_ref}"
        elif [[ -n "${upstream_ref}" ]]; then
            RESOLVED_IMAGE[${svc}]="${upstream_ref}"
            log_info "  ${svc}: ${upstream_ref} (registry miss — using upstream)"
        else
            # Local build service — no pre-pulled image
            RESOLVED_IMAGE[${svc}]=""
            log_info "  ${svc}: (local build)"
        fi
    done
}

# ---------------------------------------------------------------------------
# write_image_overrides — write IMAGE_* vars to .env so docker-compose.yml
# can reference them via ${IMAGE_POSTGRES}, ${IMAGE_KEYCLOAK}, etc.
# ---------------------------------------------------------------------------
write_image_overrides() {
    local svc image_var
    declare -A svc_to_var=(
        [postgres]="IMAGE_POSTGRES"
        [keycloak]="IMAGE_KEYCLOAK"
        [gateway]="IMAGE_GATEWAY"
        [nginx]="IMAGE_NGINX"
        [openwebui]="IMAGE_OPENWEBUI"
        [ray-head]="IMAGE_RAY"
        [vllm]="IMAGE_VLLM"
        [watcher]="IMAGE_WATCHER"
    )
    for svc in "${!svc_to_var[@]}"; do
        image_var="${svc_to_var[${svc}]}"
        local val="${RESOLVED_IMAGE[${svc}]:-}"
        # Only write if we resolved a real image (build services without a
        # registry image leave the compose `build:` block in charge)
        if [[ -n "${val}" ]]; then
            write_env_var "${image_var}" "${val}" "${DEV_ENV}"
        fi
    done
}

# ---------------------------------------------------------------------------
# Detect primary network interface IP
# ---------------------------------------------------------------------------
detect_host_ip() {
    local ip=""
    # Method 1: ip route (most reliable on RHEL/Linux — finds interface used
    # for the default route, i.e. the "most used" interface)
    ip=$(ip route get 1.1.1.1 2>/dev/null | \
         awk '/src/{for(i=1;i<=NF;i++){if($i=="src"){print $(i+1); exit}}}')
    # Method 2: hostname -I (first non-loopback)
    if [[ -z "${ip}" ]]; then
        ip=$(hostname -I 2>/dev/null | awk '{print $1}')
    fi
    echo "${ip:-127.0.0.1}"
}

# ---------------------------------------------------------------------------
# Detect compose command (podman compose or podman-compose)
# ---------------------------------------------------------------------------
detect_compose() {
    if podman compose version &>/dev/null 2>&1; then
        COMPOSE_CMD="podman compose"
    elif command -v podman-compose &>/dev/null; then
        COMPOSE_CMD="podman-compose"
    else
        die "No Podman Compose found.\n  Install: dnf install podman-compose  OR  pip3 install podman-compose"
    fi
}

# ---------------------------------------------------------------------------
# write_env_var KEY VALUE FILE — idempotent .env writer (python3-based)
# ---------------------------------------------------------------------------
write_env_var() {
    local key="$1" value="$2" file="$3"
    python3 - "${key}" "${value}" "${file}" <<'PYEOF'
import sys, re, os
key, value, path = sys.argv[1], sys.argv[2], sys.argv[3]
entry = key + "=" + value + "\n"
if os.path.exists(path):
    with open(path) as fh:
        lines = fh.readlines()
    updated = False
    for i, line in enumerate(lines):
        if re.match(r"^" + re.escape(key) + r"=", line):
            lines[i] = entry; updated = True; break
    if not updated:
        lines.append(entry)
    with open(path, "w") as fh:
        fh.writelines(lines)
else:
    with open(path, "w") as fh:
        fh.write(entry)
PYEOF
}

# ---------------------------------------------------------------------------
# read_env_var KEY FILE — read existing value from .env file
# ---------------------------------------------------------------------------
read_env_var() {
    local key="$1" file="$2"
    if [[ -f "${file}" ]]; then
        grep -E "^${key}=" "${file}" | head -1 | cut -d= -f2- || true
    fi
}

# ---------------------------------------------------------------------------
# gen_secret [length_bytes] — generate a random hex secret
# ---------------------------------------------------------------------------
gen_secret() { openssl rand -hex "${1:-32}"; }

# ---------------------------------------------------------------------------
# port_in_use PORT — return 0 if something is already bound to PORT on any
# interface, 1 if the port is free.
# Uses ss (iproute2, preferred) then nc as fallback.
# ---------------------------------------------------------------------------
port_in_use() {
    local port="$1"
    # ss is reliable and fast; -tnlp would need root but -tnl is sufficient.
    if command -v ss &>/dev/null; then
        ss -tnl 2>/dev/null | awk '{print $4}' | grep -qE ":${port}$"
        return $?
    fi
    # nc fallback: attempt a TCP connection with a 1s timeout
    if command -v nc &>/dev/null; then
        nc -z -w1 127.0.0.1 "${port}" &>/dev/null
        return $?
    fi
    # Last resort: /dev/tcp (requires bash and something listening)
    (bash -c "</dev/tcp/127.0.0.1/${port}" 2>/dev/null) && return 0 || return 1
}

# ---------------------------------------------------------------------------
# find_free_port DEFAULT [MAX_TRIES] — return DEFAULT if free, otherwise
# increment by 1 until a free port is found (up to MAX_TRIES steps).
# Prints the chosen port.
# ---------------------------------------------------------------------------
find_free_port() {
    local port="$1"
    local max_tries="${2:-100}"
    local tried=0
    while port_in_use "${port}"; do
        tried=$(( tried + 1 ))
        if (( tried >= max_tries )); then
            die "Could not find a free port starting from $1 after ${max_tries} attempts."
        fi
        port=$(( port + 1 ))
    done
    if (( tried > 0 )); then
        log_warn "Port $1 is in use — using ${port} instead"
    fi
    echo "${port}"
}

# ---------------------------------------------------------------------------
# resolve_port VAR_NAME DEFAULT — use the saved .env value if present,
# otherwise find_free_port from DEFAULT. Prints the resolved port.
# ---------------------------------------------------------------------------
resolve_port() {
    local var="$1" default="$2"
    local saved; saved=$(read_env_var "${var}" "${DEV_ENV}")
    if [[ -n "${saved}" ]]; then
        # Verify the saved port is still free (could have been taken since last run)
        if port_in_use "${saved}"; then
            log_warn "Saved ${var}=${saved} is now in use — finding a new port"
            find_free_port "${default}"
        else
            echo "${saved}"
        fi
    else
        find_free_port "${default}"
    fi
}

# ---------------------------------------------------------------------------
# ensure_directory — create directory with a .gitkeep if needed
# ---------------------------------------------------------------------------
ensure_directory() {
    local d="$1"
    if [[ ! -d "${d}" ]]; then
        run_cmd mkdir -p "${d}"
        run_cmd touch "${d}/.gitkeep"
        log_ok "Created ${d}"
    fi
}

# ---------------------------------------------------------------------------
# ensure_cni_dns_plugin — install podman-plugins if missing (RHEL 8 CNI)
# ---------------------------------------------------------------------------
ensure_cni_dns_plugin() {
    if ! command -v podman &>/dev/null; then return; fi
    # Check if this is a CNI-based Podman (RHEL 8 / older systems)
    if podman info --format '{{.Host.NetworkBackend}}' 2>/dev/null | grep -qi 'cni'; then
        if ! rpm -q podman-plugins &>/dev/null 2>&1; then
            log_warn "CNI dnsname plugin missing — installing podman-plugins"
            run_cmd dnf install -y podman-plugins
            log_ok "podman-plugins installed (CNI dnsname enabled)"
            # If stroma-dev network already exists without DNS, remove it so
            # compose recreates it with the plugin active.
            if podman network ls --format '{{.Name}}' 2>/dev/null | grep -q '^stroma-dev$'; then
                log_info "Removing old stroma-dev network (will be recreated with DNS)"
                run_cmd podman network rm stroma-dev || true
            fi
        fi
    fi
}

# ---------------------------------------------------------------------------
# generate_tls_cert — self-signed cert for nginx dev
# ---------------------------------------------------------------------------
generate_tls_cert() {
    local cert="${CERT_DIR}/server.crt"
    local key="${CERT_DIR}/server.key"
    if [[ -f "${cert}" && -f "${key}" ]]; then
        log_ok "TLS cert exists: ${cert}"
        return
    fi
    log_info "Generating self-signed TLS certificate (10-year, dev use only)..."
    run_cmd mkdir -p "${CERT_DIR}"
    local cn
    cn=$(read_env_var DEV_HOST_IP "${DEV_ENV}")
    cn="${cn:-localhost}"
    run_cmd openssl req -x509 -nodes -days 3650 -newkey rsa:4096 \
        -keyout "${key}" \
        -out    "${cert}" \
        -subj   "/CN=${cn}/O=StromaAI-Dev" \
        -addext "subjectAltName=DNS:${cn},DNS:localhost,IP:${cn},IP:127.0.0.1" \
        2>/dev/null
    run_cmd chmod 600 "${key}"
    log_ok "TLS cert generated: ${cert}"
    log_warn "Self-signed cert — browser will show a security warning. Click 'Advanced → Accept' to proceed."
}

# ---------------------------------------------------------------------------
# generate_realm_json — stamp realm-export.json template with real secrets.
# Writes a reference copy to dev-data/realm/ (not mounted into KC).
# Realm configuration is performed at runtime via configure_keycloak_realm().
# ---------------------------------------------------------------------------
generate_realm_json() {
    local out="${REALM_DIR}/stroma-ai-realm.json"
    local template="${REPO_ROOT}/deploy/keycloak/realm-export.json"

    [[ ! -f "${template}" ]] && die "Realm template not found: ${template}"

    if [[ "${DRY_RUN}" -eq 1 ]]; then
        log_dry "generate_realm_json → ${out}"
        return
    fi

    mkdir -p "${REALM_DIR}"

    local gw_secret owu_secret demo_pass host_ip https_port owu_port
    gw_secret=$(read_env_var KC_GATEWAY_CLIENT_SECRET "${DEV_ENV}")
    owu_secret=$(read_env_var KC_OPENWEBUI_CLIENT_SECRET "${DEV_ENV}")
    demo_pass=$(read_env_var KC_DEMO_USER_PASSWORD "${DEV_ENV}")
    host_ip=$(read_env_var DEV_HOST_IP "${DEV_ENV}")
    https_port=$(read_env_var STROMA_HTTPS_PORT "${DEV_ENV}"); https_port="${https_port:-443}"
    owu_port=$(read_env_var OPENWEBUI_PORT "${DEV_ENV}"); owu_port="${owu_port:-3000}"

    python3 - "${template}" "${out}" \
        "${gw_secret}" "${owu_secret}" "${demo_pass}" \
        "${host_ip}" "${https_port}" "${owu_port}" <<'PYEOF'
import sys, json
template, out = sys.argv[1], sys.argv[2]
gw_secret, owu_secret, demo_pass = sys.argv[3], sys.argv[4], sys.argv[5]
host_ip, https_port, owu_port = sys.argv[6], sys.argv[7], sys.argv[8]

with open(template) as f:
    content = f.read()

content = content.replace("REPLACE_WITH_GATEWAY_CLIENT_SECRET", gw_secret)
content = content.replace("REPLACE_WITH_OPENWEBUI_CLIENT_SECRET", owu_secret)
content = content.replace("REPLACE_WITH_DEMO_USER_PASSWORD", demo_pass)
content = content.replace("${KC_HOSTNAME}", host_ip)

data = json.loads(content)

# Ensure all dev access URIs are present for the openwebui client
extra_uris = [
    f"https://{host_ip}:{https_port}/*",
    f"http://{host_ip}:{owu_port}/*",
    "http://localhost:3000/*",
    "http://localhost/*",
]
for client in data.get("clients", []):
    if client.get("clientId") == "openwebui":
        uris = set(client.get("redirectUris", []))
        uris.update(extra_uris)
        client["redirectUris"] = sorted(uris)

with open(out, "w") as f:
    json.dump(data, f, indent=2)
PYEOF

    chmod 644 "${out}"
    log_ok "Realm JSON (reference) → ${out}"
}

# ---------------------------------------------------------------------------
# configure_keycloak_realm — idempotent KC26 realm setup via admin REST API.
# Called after Keycloak accepts TCP connections.  Uses python3 (stdlib only)
# to poll the token endpoint then create realm / roles / clients / demo user.
# Skips all configuration if the stroma-ai realm already exists.
# ---------------------------------------------------------------------------
configure_keycloak_realm() {
    [[ "${DRY_RUN}" -eq 1 ]] && { log_dry "configure_keycloak_realm (REST API)"; return; }

    local kc_port kc_admin_user kc_admin_pass gw_secret owu_secret demo_pass \
          host_ip https_port owu_port
    kc_port=$(read_env_var KC_PORT "${DEV_ENV}"); kc_port="${kc_port:-8080}"
    kc_admin_user=$(read_env_var KC_ADMIN_USER "${DEV_ENV}"); kc_admin_user="${kc_admin_user:-admin}"
    kc_admin_pass=$(read_env_var KC_ADMIN_PASSWORD "${DEV_ENV}")
    gw_secret=$(read_env_var KC_GATEWAY_CLIENT_SECRET "${DEV_ENV}")
    owu_secret=$(read_env_var KC_OPENWEBUI_CLIENT_SECRET "${DEV_ENV}")
    demo_pass=$(read_env_var KC_DEMO_USER_PASSWORD "${DEV_ENV}")
    host_ip=$(read_env_var DEV_HOST_IP "${DEV_ENV}")
    https_port=$(read_env_var STROMA_HTTPS_PORT "${DEV_ENV}"); https_port="${https_port:-443}"
    owu_port=$(read_env_var OPENWEBUI_PORT "${DEV_ENV}"); owu_port="${owu_port:-3000}"

    log_step "Configuring Keycloak realm (stroma-ai) via admin REST API"

    python3 - \
        "http://127.0.0.1:${kc_port}" \
        "${kc_admin_user}" "${kc_admin_pass}" \
        "stroma-ai" \
        "${gw_secret}" "${owu_secret}" "${demo_pass}" \
        "${host_ip}" "${https_port}" "${owu_port}" <<'PYEOF'
import sys, json, time
import urllib.request as urlreq
import urllib.parse  as urlparse
import urllib.error  as urlerr

kc_url  = sys.argv[1]   # http://127.0.0.1:8080
admin_u = sys.argv[2]
admin_p = sys.argv[3]
realm   = sys.argv[4]   # stroma-ai
gw_sec  = sys.argv[5]
owu_sec = sys.argv[6]
demo_pw = sys.argv[7]
host_ip = sys.argv[8]
https_p = sys.argv[9]
owu_p   = sys.argv[10]

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
    """Poll token endpoint until master realm is fully initialised (~2 min max)."""
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

# --- Check if realm exists (idempotent) -------------------------------------
st, realms = _http('GET', '/admin/realms', token=token)
if st == 200 and any(r.get('realm') == realm for r in (realms or [])):
    print(f'[KC]  Realm {realm!r} already configured — skipping')
    sys.exit(0)

# --- Create realm -----------------------------------------------------------
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

# --- Realm roles ------------------------------------------------------------
for rname, rdesc in [
    ('stroma_researcher', 'Grants access to StromaAI inference endpoints.'),
    ('stroma_admin',      'Administrative access to StromaAI management.'),
]:
    _http('POST', f'/admin/realms/{realm}/roles',
          {'name': rname, 'description': rdesc, 'clientRole': False},
          token=token)
print('[KC]  Roles created')

# Fetch role representation needed for user assignment
_, rr = _http('GET', f'/admin/realms/{realm}/roles/stroma_researcher', token=token)
researcher_role = {'id': rr['id'], 'name': rr['name']}

# --- Clients ----------------------------------------------------------------
# stroma-gateway: M2M / service account client
_http('POST', f'/admin/realms/{realm}/clients', {
    'clientId': 'stroma-gateway', 'name': 'StromaAI Gateway',
    'enabled': True, 'protocol': 'openid-connect',
    'publicClient': False, 'serviceAccountsEnabled': True,
    'standardFlowEnabled': False, 'implicitFlowEnabled': False,
    'directAccessGrantsEnabled': False,
    'clientAuthenticatorType': 'client-secret',
    'secret': gw_sec,
}, token=token)

# openwebui: PKCE Authorization Code flow
_http('POST', f'/admin/realms/{realm}/clients', {
    'clientId': 'openwebui', 'name': 'Open WebUI',
    'enabled': True, 'protocol': 'openid-connect',
    'publicClient': False, 'standardFlowEnabled': True,
    'implicitFlowEnabled': False, 'directAccessGrantsEnabled': False,
    'clientAuthenticatorType': 'client-secret',
    'secret': owu_sec,
    'redirectUris': [
        f'https://{host_ip}:{https_p}/*',
        f'http://{host_ip}:{owu_p}/*',
        'http://localhost:3000/*',
        '*',
    ],
    'webOrigins': ['+'],
    'attributes': {'pkce.code.challenge.method': 'S256'},
}, token=token)
print('[KC]  Clients created')

# --- Demo user --------------------------------------------------------------
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
# Set temporary password (user must change on first login)
_http('PUT', f'/admin/realms/{realm}/users/{uid}/reset-password',
      {'type': 'password', 'value': demo_pw, 'temporary': True}, token=token)
# Assign stroma_researcher role
_http('POST', f'/admin/realms/{realm}/users/{uid}/role-mappings/realm',
      [researcher_role], token=token)
print('[KC]  Demo user created (temporary password set)')

print('[KC]  Realm configuration complete ✓')
PYEOF
}

# ---------------------------------------------------------------------------
# ensure_dot_env — write/update dev/.env with all required vars
# ---------------------------------------------------------------------------
ensure_dot_env() {
    log_step "Environment configuration"

    local host_ip
    host_ip=$(detect_host_ip)

    # Allow override from existing .env (preserves secrets across re-runs)
    local existing_ip
    existing_ip=$(read_env_var DEV_HOST_IP "${DEV_ENV}")
    if [[ -n "${existing_ip}" && "${existing_ip}" != "${host_ip}" ]]; then
        log_info "DEV_HOST_IP in .env (${existing_ip}) differs from detected (${host_ip})"
        log_info "Using existing value. Delete dev/.env to reset."
        host_ip="${existing_ip}"
    fi

    [[ -n "${HTTPS_PORT_OVERRIDE}" ]] && write_env_var STROMA_HTTPS_PORT "${HTTPS_PORT_OVERRIDE}" "${DEV_ENV}"
    [[ -n "${MODEL_PATH_OVERRIDE}" ]] && write_env_var DEV_MODEL_PATH "${MODEL_PATH_OVERRIDE}" "${DEV_ENV}"

    # Write detected host IP
    write_env_var DEV_HOST_IP "${host_ip}" "${DEV_ENV}"

    # Preserve or generate secrets
    local db_pass; db_pass=$(read_env_var KC_DB_PASSWORD "${DEV_ENV}")
    local admin_pass; admin_pass=$(read_env_var KC_ADMIN_PASSWORD "${DEV_ENV}")
    local api_key; api_key=$(read_env_var STROMA_API_KEY "${DEV_ENV}")
    local webui_secret; webui_secret=$(read_env_var WEBUI_SECRET_KEY "${DEV_ENV}")
    local gw_client_secret; gw_client_secret=$(read_env_var KC_GATEWAY_CLIENT_SECRET "${DEV_ENV}")
    local owu_client_secret; owu_client_secret=$(read_env_var KC_OPENWEBUI_CLIENT_SECRET "${DEV_ENV}")
    local demo_pass; demo_pass=$(read_env_var KC_DEMO_USER_PASSWORD "${DEV_ENV}")

    [[ -z "${db_pass}" ]]          && { db_pass=$(gen_secret 16); _DEV_FRESH_DB_PASS=1; }
    [[ -z "${admin_pass}" ]]       && admin_pass=$(gen_secret 12)
    [[ -z "${api_key}" ]]          && api_key=$(gen_secret 32)
    [[ -z "${webui_secret}" ]]     && webui_secret=$(gen_secret 32)
    [[ -z "${gw_client_secret}" ]] && gw_client_secret=$(gen_secret 16)
    [[ -z "${owu_client_secret}" ]] && owu_client_secret=$(gen_secret 16)
    [[ -z "${demo_pass}" ]]        && demo_pass=$(gen_secret 12)

    write_env_var KC_DB_PASSWORD            "${db_pass}"         "${DEV_ENV}"
    write_env_var KC_ADMIN_USER             "admin"              "${DEV_ENV}"
    write_env_var KC_ADMIN_PASSWORD         "${admin_pass}"      "${DEV_ENV}"
    write_env_var STROMA_API_KEY            "${api_key}"         "${DEV_ENV}"
    write_env_var WEBUI_SECRET_KEY          "${webui_secret}"    "${DEV_ENV}"
    write_env_var KC_GATEWAY_CLIENT_SECRET  "${gw_client_secret}" "${DEV_ENV}"
    write_env_var KC_OPENWEBUI_CLIENT_SECRET "${owu_client_secret}" "${DEV_ENV}"
    write_env_var KC_DEMO_USER_PASSWORD     "${demo_pass}"       "${DEV_ENV}"

    # -------------------------------------------------------------------------
    # Ports — auto-discover free ports on first run; reuse on subsequent runs.
    # Host-published ports are checked for conflicts; internal-only ports
    # (GATEWAY_PORT is on the bridge network, not published) are also checked
    # in case they collide via host-network services (ray/vllm/watcher).
    # -------------------------------------------------------------------------
    _model_path=$(read_env_var DEV_MODEL_PATH "${DEV_ENV}")
    
    # Auto-detect model directory if not set
    if [[ -z "${_model_path}" ]]; then
        _model_path="${MODELS_DIR}"
        
        # If MODELS_DIR exists and contains exactly one subdirectory, use that
        if [[ -d "${MODELS_DIR}" ]]; then
            _model_dirs=("${MODELS_DIR}"/*)
            _valid_models=()
            
            # Filter out .gitkeep and other non-directories
            for d in "${_model_dirs[@]}"; do
                if [[ -d "${d}" && ! "${d}" =~ /\.gitkeep$ ]]; then
                    _valid_models+=("${d}")
                fi
            done
            
            if [[ ${#_valid_models[@]} -eq 1 ]]; then
                _model_path="${_valid_models[0]}"
                log_ok "Auto-detected model: ${_model_path}"
            elif [[ ${#_valid_models[@]} -gt 1 ]]; then
                log_warn "Multiple models found in ${MODELS_DIR}:"
                for m in "${_valid_models[@]}"; do
                    log_warn "  - $(basename "${m}")"
                done
                log_warn "Set DEV_MODEL_PATH to the specific model directory, e.g.:"
                log_warn "  DEV_MODEL_PATH=${MODELS_DIR}/$(basename "${_valid_models[0]}")"
            fi
        fi
    fi
    
    write_env_var DEV_MODEL_PATH     "${_model_path}"      "${DEV_ENV}"
    write_env_var DEV_SHARED_ROOT    "${SHARED_DIR}"      "${DEV_ENV}"

    # HTTPS port (nginx TLS) — CLI override takes absolute precedence
    _https_port=""
    if [[ -n "${HTTPS_PORT_OVERRIDE}" ]]; then
        _https_port="${HTTPS_PORT_OVERRIDE}"
        port_in_use "${_https_port}" && log_warn "--port=${_https_port} is already in use on this host"
    else
        _https_port=$(resolve_port STROMA_HTTPS_PORT 443)
    fi

    # HTTP port (nginx plain, always HTTPS_PORT-1 twin but fixed at 80 by nginx config)
    # nginx listens on 80 inside the container; only the container runtime matters
    # for host binding — we don't publish 80 independently, it's always the nginx
    # container's port 80. We do need to verify 80 is free (nginx publishes 80:80).
    if port_in_use 80 && [[ "${_https_port}" != "80" ]]; then
        log_warn "Port 80 is in use — HTTP-to-HTTPS redirect will not work (HTTPS still works on :${_https_port})"
        log_warn "To fix: free port 80 on the host or update nginx-dev.conf to listen on an alternate port."
    fi

    _kc_port=$(resolve_port   KC_PORT                 8080)
    _owu_port=$(resolve_port  OPENWEBUI_PORT          3000)
    _gw_port=$(resolve_port   GATEWAY_PORT            9000)
    _vllm_port=$(resolve_port STROMA_VLLM_PORT        8000)
    _ray_port=$(resolve_port  STROMA_RAY_PORT         6380)
    _ray_dash_port=$(resolve_port STROMA_RAY_DASHBOARD_PORT 8265)

    write_env_var STROMA_HTTPS_PORT           "${_https_port}"   "${DEV_ENV}"
    write_env_var KC_PORT                     "${_kc_port}"      "${DEV_ENV}"
    write_env_var OPENWEBUI_PORT              "${_owu_port}"     "${DEV_ENV}"
    write_env_var GATEWAY_PORT                "${_gw_port}"      "${DEV_ENV}"
    write_env_var STROMA_VLLM_PORT            "${_vllm_port}"    "${DEV_ENV}"
    write_env_var STROMA_RAY_PORT             "${_ray_port}"     "${DEV_ENV}"
    write_env_var STROMA_RAY_DASHBOARD_PORT   "${_ray_dash_port}" "${DEV_ENV}"
    write_env_var WEBUI_NAME                  "StromaAI Dev"    "${DEV_ENV}"

    chmod 600 "${DEV_ENV}"
    log_ok ".env written → ${DEV_ENV}"
    log_info "Host IP: ${host_ip}"
}

# ---------------------------------------------------------------------------
# build_profiles_args — compose --profile flags based on CLI options
# ---------------------------------------------------------------------------
build_profile_args() {
    local args=()
    [[ "${PROFILE_INFERENCE}" -eq 1 ]] && args+=("--profile" "inference")
    [[ "${PROFILE_WATCHER}" -eq 1 ]]   && args+=("--profile" "watcher")
    echo "${args[@]:-}"
}

# ---------------------------------------------------------------------------
# compose_cmd — wrapper that always passes --env-file and -f
# ---------------------------------------------------------------------------
compose() {
    local profile_args=()
    [[ "${PROFILE_INFERENCE}" -eq 1 ]] && profile_args+=(--profile inference)
    [[ "${PROFILE_WATCHER}" -eq 1 ]]   && profile_args+=(--profile watcher)
    run_cmd ${COMPOSE_CMD} \
        --env-file "${DEV_ENV}" \
        -f "${SCRIPT_DIR}/docker-compose.yml" \
        "${profile_args[@]}" \
        "$@"
}

# ---------------------------------------------------------------------------
# print_summary — show URLs and credentials after startup
# ---------------------------------------------------------------------------
print_summary() {
    local host_ip https_port kc_port owu_port gw_port admin_pass api_key

    host_ip=$(read_env_var DEV_HOST_IP "${DEV_ENV}")
    https_port=$(read_env_var STROMA_HTTPS_PORT "${DEV_ENV}"); https_port="${https_port:-443}"
    kc_port=$(read_env_var KC_PORT "${DEV_ENV}"); kc_port="${kc_port:-8080}"
    owu_port=$(read_env_var OPENWEBUI_PORT "${DEV_ENV}"); owu_port="${owu_port:-3000}"
    gw_port=$(read_env_var GATEWAY_PORT "${DEV_ENV}"); gw_port="${gw_port:-9000}"
    admin_pass=$(read_env_var KC_ADMIN_PASSWORD "${DEV_ENV}")
    api_key=$(read_env_var STROMA_API_KEY "${DEV_ENV}")

    local model_path; model_path=$(read_env_var DEV_MODEL_PATH "${DEV_ENV}"); model_path="${model_path:-${MODELS_DIR}}"

    echo ""
    echo -e "${BOLD}╔══════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${BOLD}║   StromaAI Dev Environment — Ready                       ║${RESET}"
    echo -e "${BOLD}╚══════════════════════════════════════════════════════════╝${RESET}"
    echo ""
    echo -e "  ${BOLD}Web UI (chat)${RESET}"
    echo -e "    ${GREEN}https://${host_ip}:${https_port}${RESET}        (via nginx — self-signed cert)"
    echo -e "    ${GREEN}http://${host_ip}:${owu_port}${RESET}         (OpenWebUI direct)"
    echo ""
    echo -e "  ${BOLD}API${RESET}"
    echo -e "    ${GREEN}https://${host_ip}:${https_port}/v1${RESET}     (OIDC-gated, via nginx)"
    echo -e "    ${GREEN}http://${host_ip}:${gw_port}/v1${RESET}       (gateway direct)"
    echo ""
    echo -e "  ${BOLD}Keycloak Admin${RESET}"
    echo -e "    ${GREEN}http://${host_ip}:${kc_port}/admin${RESET}"
    echo -e "    ${DIM}Username: admin${RESET}"
    echo -e "    ${DIM}Password: ${admin_pass}${RESET}"
    echo ""
    echo -e "  ${BOLD}API Key${RESET} (for direct vLLM / gateway calls)"
    echo -e "    ${DIM}${api_key}${RESET}"
    echo ""
    echo -e "  ${BOLD}Model weights${RESET}"
    echo -e "    ${DIM}${model_path}/${RESET}"
    echo -e "    ${YELLOW}↑ Symlink or copy model weights here for inference${RESET}"

    if [[ "${PROFILE_INFERENCE}" -eq 1 ]]; then
        echo ""
        echo -e "  ${BOLD}Inference health${RESET}"
        echo -e "    ${GREEN}http://${host_ip}/health${RESET}            (via nginx, polls vLLM)"
        local ray_dashboard_port; ray_dashboard_port=$(read_env_var STROMA_RAY_DASHBOARD_PORT "${DEV_ENV}"); ray_dashboard_port="${ray_dashboard_port:-8265}"
        echo -e "    ${GREEN}http://${host_ip}:${ray_dashboard_port}${RESET}           (Ray dashboard)"
    fi

    echo ""
    echo -e "  ${BOLD}Useful commands${RESET}"
    echo -e "    ${CYAN}./dev.sh logs${RESET}              follow all logs"
    echo -e "    ${CYAN}./dev.sh logs keycloak${RESET}     follow one service"
    echo -e "    ${CYAN}./dev.sh ps${RESET}                container status"
    echo -e "    ${CYAN}./dev.sh restart openwebui${RESET} restart a service"
    echo -e "    ${CYAN}./dev.sh down${RESET}              stop everything"
    echo ""
}

# ---------------------------------------------------------------------------
# check_slurm_binaries — detect and configure Slurm binary paths (watcher profile)
# ---------------------------------------------------------------------------
check_slurm_binaries() {
    log_info "Detecting Slurm binaries..."
    
    local missing=0
    local search_paths=(
        "/usr/bin"
        "/usr/local/bin"
        "/opt/slurm/bin"
        "/cm/shared/apps/slurm/current/bin"
    )
    
    # Try to load Slurm via modules if available
    if command -v modulecmd &>/dev/null || command -v module &>/dev/null; then
        # Try common Slurm module names
        for mod in slurm Slurm slurm/current; do
            if module load "${mod}" 2>/dev/null; then
                log_ok "Loaded Slurm via module: ${mod}"
                break
            fi
        done
    fi
    
    # Detect each Slurm binary
    for binary in sbatch squeue scancel sinfo; do
        local found_path=""
        
        # First check if it's in PATH
        if command -v "${binary}" &>/dev/null; then
            found_path=$(command -v "${binary}")
        else
            # Search common locations
            for dir in "${search_paths[@]}"; do
                if [[ -x "${dir}/${binary}" ]]; then
                    found_path="${dir}/${binary}"
                    break
                fi
            done
        fi
        
        if [[ -n "${found_path}" ]]; then
            local var_name="SLURM_${binary^^}_BIN"  # Convert to uppercase
            write_env_var "${var_name}" "${found_path}" "${DEV_ENV}"
            log_ok "  ${binary}: ${found_path}"
        else
            # Use /bin/true as a stub so the mount doesn't fail
            # The watcher will fail at runtime if it tries to use these
            local var_name="SLURM_${binary^^}_BIN"
            write_env_var "${var_name}" "/bin/true" "${DEV_ENV}"
            log_warn "  ${binary}: not found (using stub)"
            missing=1
        fi
    done
    
    # Detect Slurm config and munge directories
    if [[ -d "/etc/slurm" ]]; then
        write_env_var "SLURM_CONF_PATH" "/etc/slurm" "${DEV_ENV}"
    elif [[ -d "/etc/slurm-llnl" ]]; then
        write_env_var "SLURM_CONF_PATH" "/etc/slurm-llnl" "${DEV_ENV}"
    else
        # Create stub directory so mount doesn't fail
        local stub_dir="${SCRIPT_DIR}/dev-data/slurm-stub"
        mkdir -p "${stub_dir}"
        write_env_var "SLURM_CONF_PATH" "${stub_dir}" "${DEV_ENV}"
        log_warn "  slurm config: not found (using stub)"
    fi
    
    if [[ -d "/var/run/munge" ]]; then
        write_env_var "SLURM_MUNGE_SOCKET_DIR" "/var/run/munge" "${DEV_ENV}"
    elif [[ -d "/run/munge" ]]; then
        write_env_var "SLURM_MUNGE_SOCKET_DIR" "/run/munge" "${DEV_ENV}"
    else
        # Create stub directory so mount doesn't fail
        local stub_dir="${SCRIPT_DIR}/dev-data/munge-stub"
        mkdir -p "${stub_dir}"
        write_env_var "SLURM_MUNGE_SOCKET_DIR" "${stub_dir}" "${DEV_ENV}"
        log_warn "  munge socket: not found (using stub)"
    fi
    
    if [[ "${missing}" -eq 1 ]]; then
        echo ""
        log_warn "═══════════════════════════════════════════════════════════"
        log_warn "  Slurm binaries not found — watcher WILL NOT WORK"
        log_warn "═══════════════════════════════════════════════════════════"
        log_warn "The watcher container will start but will fail when trying"
        log_warn "to submit jobs. This is OK for testing other components."
        log_warn ""
        log_warn "To fix:"
        log_warn "  • Load Slurm: module load slurm (then re-run dev.sh)"
        log_warn "  • Or skip watcher: ./dev.sh up --inference"
        log_warn "═══════════════════════════════════════════════════════════"
        echo ""
        if [[ -t 0 && "${STROMA_YES:-0}" -ne 1 ]]; then
            read -r -p "$(echo -e "${YELLOW}Continue anyway? [y/N]${RESET} ")" response
            if [[ ! "${response}" =~ ^[Yy]$ ]]; then
                die "Aborted. Load Slurm or use --inference without --watcher."
            fi
        fi
    fi
}

# =============================================================================
# SUBCOMMANDS
# =============================================================================

detect_compose

case "${SUBCMD}" in

    # -------------------------------------------------------------------------
    up)
        echo ""
        echo -e "${BOLD}╔══════════════════════════════════════════════════════════╗${RESET}"
        echo -e "${BOLD}║   StromaAI — Starting Dev Environment                    ║${RESET}"
        echo -e "${BOLD}╚══════════════════════════════════════════════════════════╝${RESET}"
        echo ""
        [[ "${DRY_RUN}" -eq 1 ]] && log_warn "DRY-RUN mode — no changes will be made."

        log_step "Checking prerequisites"
        command -v podman  &>/dev/null || die "podman not found"
        command -v openssl &>/dev/null || die "openssl not found (needed for TLS cert generation)"
        command -v python3 &>/dev/null || die "python3 not found"
        ensure_cni_dns_plugin

        log_step "Creating dev data directories"
        ensure_directory "${MODELS_DIR}"
        ensure_directory "${SHARED_DIR}/logs"
        ensure_directory "${SHARED_DIR}/slurm"
        ensure_directory "${CERT_DIR}"
        ensure_directory "${REALM_DIR}"

        ensure_dot_env
        generate_tls_cert
        generate_realm_json

        resolve_all_images
        write_image_overrides

        if [[ "${PROFILE_WATCHER}" -eq 1 ]]; then
            log_step "Checking Slurm binaries (watcher profile)"
            check_slurm_binaries
        fi

        if [[ "${DO_REBUILD}" -eq 1 ]]; then
            log_step "Building custom images"
            compose build gateway watcher
        fi

        # Pre-flight: validate model path when inference profile is active.
        # vllm exits immediately without valid model weights; the container will not
        # restart (restart: "no") so this is the best time to catch it.
        if [[ "${PROFILE_INFERENCE}" -eq 1 && "${DRY_RUN}" -eq 0 ]]; then
            _preflight_model_path=$(read_env_var DEV_MODEL_PATH "${DEV_ENV}"); _preflight_model_path="${_preflight_model_path:-${MODELS_DIR}}"
            
            # Check if path exists and looks like a model directory
            _model_valid=0
            if [[ -d "${_preflight_model_path}" ]]; then
                # Check for common model files (any one indicates a valid model)
                if   [[ -f "${_preflight_model_path}/config.json" ]] \
                  || [[ -f "${_preflight_model_path}/model.safetensors" ]] \
                  || [[ -f "${_preflight_model_path}/model.safetensors.index.json" ]] \
                  || [[ -f "${_preflight_model_path}/pytorch_model.bin" ]] \
                  || ls "${_preflight_model_path}"/model-*.safetensors &>/dev/null \
                  || ls "${_preflight_model_path}"/*.gguf &>/dev/null; then
                    _model_valid=1
                fi
            fi
            
            if [[ "${_model_valid}" -eq 0 ]]; then
                echo ""
                log_warn "═══════════════════════════════════════════════════════════"
                log_warn "  Model path does not contain a valid model"
                log_warn "═══════════════════════════════════════════════════════════"
                log_warn "Path: ${_preflight_model_path}"
                if [[ ! -d "${_preflight_model_path}" ]]; then
                    log_warn "  → Directory does not exist"
                elif [[ -z "$(ls -A "${_preflight_model_path}" 2>/dev/null)" ]]; then
                    log_warn "  → Directory is empty"
                else
                    log_warn "  → No model files found (config.json, *.safetensors, etc.)"
                    log_warn "  → Contents: $(ls -1 "${_preflight_model_path}" 2>/dev/null | head -5 | tr '\n' ' ')"
                fi
                log_warn ""
                log_warn "vLLM requires a valid model with at least:"
                log_warn "  • config.json"
                log_warn "  • tokenizer files"
                log_warn "  • model weights (*.safetensors or *.bin)"
                log_warn ""
                log_warn "To fix:"
                log_warn "  1. Download a model: hfw download meta-llama/Llama-3-8B"
                log_warn "  2. Or symlink weights: ln -s /path/to/model ${MODELS_DIR}/mymodel"
                log_warn "  3. Then set: DEV_MODEL_PATH=${MODELS_DIR}/mymodel"
                log_warn "  4. Re-run: ./dev.sh up --inference"
                log_warn "═══════════════════════════════════════════════════════════"
                echo ""
                
                if [[ -t 0 && "${STROMA_YES:-0}" -ne 1 ]]; then
                    read -r -p "$(echo -e "${YELLOW}Continue without inference? [Y/n]${RESET} ")" response
                    if [[ "${response}" =~ ^[Nn]$ ]]; then
                        die "Aborted. Set up model weights and try again."
                    fi
                fi
                
                log_warn "Continuing without inference profile (auth + UI only)."
                PROFILE_INFERENCE=0
                PROFILE_WATCHER=0
            else
                log_ok "Model validated: ${_preflight_model_path}"
                
                # Check if quantization is configured but model isn't actually quantized
                _quant_setting=$(read_env_var STROMA_VLLM_QUANTIZATION "${DEV_ENV}")
                if [[ -n "${_quant_setting}" && -f "${_preflight_model_path}/config.json" ]]; then
                    if ! grep -q "quantization_config" "${_preflight_model_path}/config.json" 2>/dev/null; then
                        log_warn "═══════════════════════════════════════════════════════════"
                        log_warn "  Quantization flag set but model may not be quantized"
                        log_warn "═══════════════════════════════════════════════════════════"
                        log_warn "STROMA_VLLM_QUANTIZATION = ${_quant_setting}"
                        log_warn "Model config.json does not contain quantization_config"
                        log_warn ""
                        log_warn "This may cause vLLM to fail or fall back to fp16, which"
                        log_warn "uses significantly more GPU memory (~18GB vs ~5GB for 7B)."
                        log_warn ""
                        log_warn "If you see GPU OOM errors, either:"
                        log_warn "  1. Use an actually quantized model (AWQ/GPTQ)"
                        log_warn "  2. Unset quantization: STROMA_VLLM_QUANTIZATION="
                        log_warn "  3. Reduce memory usage:"
                        log_warn "      STROMA_VLLM_GPU_MEMORY=0.70"
                        log_warn "      STROMA_VLLM_MAX_MODEL_LEN=2048"
                        log_warn "═══════════════════════════════════════════════════════════"
                        echo ""
                    fi
                fi
            fi
        fi

        log_step "Starting containers"
        if [[ "${PROFILE_INFERENCE}" -eq 1 ]]; then
            log_info "Profiles: inference${PROFILE_WATCHER:+ watcher}"
        fi
        if [[ "${PROFILE_WATCHER}" -eq 1 && "${PROFILE_INFERENCE}" -eq 0 ]]; then
            log_info "Profiles: watcher"
        fi
        [[ "${PROFILE_INFERENCE}" -eq 0 && "${PROFILE_WATCHER}" -eq 0 ]] && \
            log_info "Starting auth + UI stack (use --inference to add vLLM)"

        # Detect stale postgres volume: when .env was absent and a new
        # KC_DB_PASSWORD was generated, but the postgres_data volume already
        # exists from a prior run — Keycloak will fail with "password auth
        # failed".  Catch this before starting rather than after 120s of wait.
        if [[ "${_DEV_FRESH_DB_PASS}" -eq 1 && "${DRY_RUN}" -eq 0 ]]; then
            _stale_vol=$(podman volume ls --format '{{.Name}}' 2>/dev/null \
                        | grep 'postgres_data$' | head -1 || true)
            if [[ -n "${_stale_vol}" ]]; then
                echo
                log_warn "dev/.env was missing — new secrets were generated."
                log_warn "But postgres volume '${_stale_vol}' already exists with a different password."
                log_warn "Keycloak would fail with 'password authentication failed'."
                echo
                die "Stale database detected. Run:  ./dev.sh clean && ./dev.sh up"
            fi
        fi

        # Stop existing containers first — ensures changed compose config
        # (volume mounts, env vars) takes effect without leftover containers.
        # Named volumes are preserved; only containers are removed.
        compose down --remove-orphans 2>/dev/null || true

        compose up -d --remove-orphans

        # Wait for Keycloak to accept connections (TCP check on published port).
        # Timeout after 120s with a hint to check logs — avoids infinite hang
        # when KC is in a restart loop (e.g. KC_DB_PASSWORD mismatch).
        if [[ "${DRY_RUN}" -eq 0 ]]; then
            _kc_port=$(read_env_var KC_PORT "${DEV_ENV}"); _kc_port="${_kc_port:-8080}"
            log_info "Waiting for Keycloak on :${_kc_port} (up to 120s)..."
            _kc_waited=0
            until bash -c "</dev/tcp/127.0.0.1/${_kc_port}" 2>/dev/null; do
                sleep 5; _kc_waited=$((_kc_waited + 5))
                printf '.'
                if (( _kc_waited >= 120 )); then
                    echo
                    log_warn "Keycloak didn't respond in 120s — it may be stuck."
                    log_warn "Check logs:  ./dev.sh logs keycloak"
                    log_warn "If you see 'password auth failed': run  ./dev.sh clean && ./dev.sh up"
                    break
                fi
            done
            echo
            (( _kc_waited < 120 )) && log_ok "Keycloak is accepting connections"

            # Configure Keycloak realm via admin REST API.
            # This is idempotent: skips if stroma-ai realm already exists
            # (safe for ./dev.sh restart or re-run without clean).
            if (( _kc_waited < 120 )); then
                configure_keycloak_realm
            fi
        fi

        print_summary
        ;;

    # -------------------------------------------------------------------------
    down)
        log_step "Stopping dev environment"
        compose down --remove-orphans
        log_ok "All containers stopped (volumes preserved — use 'clean' to remove them)"
        ;;

    # -------------------------------------------------------------------------
    restart)
        if [[ -n "${SERVICE_ARG}" ]]; then
            log_step "Restarting ${SERVICE_ARG}"
            compose restart "${SERVICE_ARG}"
        else
            log_step "Restarting all containers"
            compose restart
        fi
        log_ok "Done"
        ;;

    # -------------------------------------------------------------------------
    build)
        log_step "Building custom images (gateway, watcher)"
        resolve_all_images
        write_image_overrides
        compose build gateway watcher
        log_ok "Build complete"
        ;;

    # -------------------------------------------------------------------------
    logs)
        if [[ -n "${SERVICE_ARG}" ]]; then
            compose logs --follow --tail=100 "${SERVICE_ARG}"
        else
            compose logs --follow --tail=50
        fi
        ;;

    # -------------------------------------------------------------------------
    ps)
        compose ps
        ;;

    # -------------------------------------------------------------------------
    status)
        log_step "Dev environment status"
        echo ""
        compose ps --format "table {{.Name}}\t{{.Status}}\t{{.Ports}}" 2>/dev/null || compose ps
        echo ""

        # Quick connectivity checks
        if [[ "${DRY_RUN}" -eq 0 ]]; then
            local host_ip; host_ip=$(read_env_var DEV_HOST_IP "${DEV_ENV}"); host_ip="${host_ip:-$(detect_host_ip)}"
            local kc_port; kc_port=$(read_env_var KC_PORT "${DEV_ENV}"); kc_port="${kc_port:-8080}"
            local gw_port; gw_port=$(read_env_var GATEWAY_PORT "${DEV_ENV}"); gw_port="${gw_port:-9000}"
            local owu_port; owu_port=$(read_env_var OPENWEBUI_PORT "${DEV_ENV}"); owu_port="${owu_port:-3000}"
            local vllm_port; vllm_port=$(read_env_var STROMA_VLLM_PORT "${DEV_ENV}"); vllm_port="${vllm_port:-8000}"

            check_port() {
                local name="$1" host="$2" port="$3"
                if bash -c "</dev/tcp/${host}/${port}" 2>/dev/null; then
                    echo -e "  ${GREEN}✓${RESET} ${name} (${host}:${port})"
                else
                    echo -e "  ${RED}✗${RESET} ${name} (${host}:${port})"
                fi
            }

            echo "Connectivity:"
            check_port "Keycloak"  "127.0.0.1" "${kc_port}"
            check_port "Gateway"   "127.0.0.1" "${gw_port}"
            check_port "OpenWebUI" "127.0.0.1" "${owu_port}"
            check_port "vLLM"      "127.0.0.1" "${vllm_port}"
            echo ""
        fi
        ;;

    # -------------------------------------------------------------------------
    clean)
        log_step "Cleaning dev environment"
        log_warn "This will remove all containers, named volumes, dev certs, and dev/.env."
        read -r -p "$(echo -e "${YELLOW}Type 'yes' to confirm: ${RESET}")" _confirm
        [[ "${_confirm}" != "yes" ]] && { log_info "Aborted."; exit 0; }

        compose down --volumes --remove-orphans 2>/dev/null || true
        podman network rm stroma-dev 2>/dev/null || true
        run_cmd rm -f "${DEV_ENV}"
        run_cmd rm -rf "${CERT_DIR}" "${REALM_DIR}"
        log_ok "Cleaned. dev-data/models/ and dev-data/shared/ are preserved."
        ;;

    # -------------------------------------------------------------------------
    ip)
        detect_host_ip
        ;;

    # -------------------------------------------------------------------------
    # commit — snapshot running containers into registry-named images.
    # Usage:  ./dev.sh commit [VERSION]
    # VERSION defaults to YYYY.MM.DD.  Images are tagged both :VERSION and
    # :latest so they can be used immediately without a version argument.
    # Does NOT push — use './dev.sh push' for that.
    # -------------------------------------------------------------------------
    commit)
        local ver="${VERSION_ARG:-$(default_version)}"
        log_step "Committing running containers → registry images (version: ${ver})"
        log_info "Registry: ${STROMA_REGISTRY}"
        log_info "This snapshots the current container state, not just the base image."
        echo ""

        # Map: container_name → (registry_image_name  upstream_base)
        # We commit the running container and tag it as both :VERSION and :latest
        declare -A COMMIT_MAP=(
            [dev-stroma-postgres]="${STROMA_REGISTRY}/kc-postgres"
            [dev-stroma-keycloak]="${STROMA_REGISTRY}/kc-keycloak"
            [dev-stroma-gateway]="${STROMA_REGISTRY}/stroma-gateway"
            [dev-stroma-nginx]="${STROMA_REGISTRY}/stroma-nginx"
            [dev-stroma-openwebui]="${STROMA_REGISTRY}/stroma-openwebui"
            [dev-stroma-ray-head]="${STROMA_REGISTRY}/stroma-ray"
            [dev-stroma-vllm]="${STROMA_REGISTRY}/stroma-vllm"
            [dev-stroma-watcher]="${STROMA_REGISTRY}/stroma-watcher"
        )

        local committed=0 skipped=0
        for container in "${!COMMIT_MAP[@]}"; do
            local image_base="${COMMIT_MAP[${container}]}"
            # Check the container is actually running
            if ! podman ps --format '{{.Names}}' 2>/dev/null | grep -qx "${container}"; then
                log_warn "  ${container}: not running — skipped"
                skipped=$(( skipped + 1 ))
                continue
            fi
            log_info "  Committing ${container} → ${image_base}:${ver}"
            run_cmd podman commit \
                --pause=true \
                --message "StromaAI dev commit ${ver}" \
                "${container}" "${image_base}:${ver}"
            # Also tag as :latest for easy use without a version
            run_cmd podman tag "${image_base}:${ver}" "${image_base}:latest"
            log_ok "  ${image_base}:${ver}  (+ :latest)"
            committed=$(( committed + 1 ))
        done

        echo ""
        log_ok "Committed ${committed} image(s), skipped ${skipped} (not running)."
        log_info "Push to registry with:  ./dev.sh push ${ver}"
        ;;

    # -------------------------------------------------------------------------
    # push — push committed images to the registry.
    # Usage:  ./dev.sh push [VERSION]
    # VERSION defaults to YYYY.MM.DD (same default as 'commit').
    # Checks registry auth first; prompts for login if needed.
    # Both :VERSION and :latest tags are pushed.
    # -------------------------------------------------------------------------
    push)
        local ver="${VERSION_ARG:-$(default_version)}"
        log_step "Pushing images to registry (version: ${ver})"
        log_info "Registry: ${STROMA_REGISTRY}"
        ensure_registry_login

        local all_images=(
            "${STROMA_REGISTRY}/kc-postgres"
            "${STROMA_REGISTRY}/kc-keycloak"
            "${STROMA_REGISTRY}/stroma-gateway"
            "${STROMA_REGISTRY}/stroma-nginx"
            "${STROMA_REGISTRY}/stroma-openwebui"
            "${STROMA_REGISTRY}/stroma-ray"
            "${STROMA_REGISTRY}/stroma-vllm"
            "${STROMA_REGISTRY}/stroma-watcher"
        )

        local pushed=0 skipped=0
        for image_base in "${all_images[@]}"; do
            local versioned="${image_base}:${ver}"
            local latest="${image_base}:latest"

            # Only push if the versioned tag exists locally
            if ! podman image exists "${versioned}" 2>/dev/null; then
                log_warn "  ${versioned}: not found locally — skipped (run 'commit' first)"
                skipped=$(( skipped + 1 ))
                continue
            fi

            log_info "  Pushing ${versioned}"
            run_cmd podman push "${versioned}"
            log_info "  Pushing ${latest}"
            run_cmd podman push "${latest}"
            log_ok "  ${image_base} pushed (${ver} + latest)"
            pushed=$(( pushed + 1 ))
        done

        echo ""
        log_ok "Pushed ${pushed} image(s), skipped ${skipped}."
        if (( pushed > 0 )); then
            log_info "Team members can now use these images by running:"
            log_info "  STROMA_REGISTRY=${STROMA_REGISTRY} ./dev.sh up"
        fi
        ;;

    # -------------------------------------------------------------------------
    # pull — pull all images from the registry (skips any that are missing).
    # Useful to warm the local image cache before running in an air-gapped env.
    # -------------------------------------------------------------------------
    pull)
        log_step "Pulling images from registry"
        log_info "Registry: ${STROMA_REGISTRY}"
        ensure_registry_login

        local all_images=(
            "${STROMA_REGISTRY}/kc-postgres:latest"
            "${STROMA_REGISTRY}/kc-keycloak:latest"
            "${STROMA_REGISTRY}/stroma-gateway:latest"
            "${STROMA_REGISTRY}/stroma-nginx:latest"
            "${STROMA_REGISTRY}/stroma-openwebui:latest"
            "${STROMA_REGISTRY}/stroma-ray:latest"
            "${STROMA_REGISTRY}/stroma-vllm:latest"
            "${STROMA_REGISTRY}/stroma-watcher:latest"
        )

        local pulled=0 skipped=0
        for ref in "${all_images[@]}"; do
            log_info "  Pulling ${ref}"
            if run_cmd podman pull "${ref}" 2>/dev/null; then
                log_ok "  ${ref}"
                pulled=$(( pulled + 1 ))
            else
                log_warn "  ${ref}: not found in registry — skipped"
                skipped=$(( skipped + 1 ))
            fi
        done

        echo ""
        log_ok "Pulled ${pulled} image(s), skipped ${skipped} (not yet in registry)."
        ;;

    *)
        usage
        ;;
esac
