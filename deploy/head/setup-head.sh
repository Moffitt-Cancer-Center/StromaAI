#!/usr/bin/env bash
# =============================================================================
# StromaAI — Head Node Container Stack Setup
# =============================================================================
# Prepares the environment for running the StromaAI head node as a Podman
# Compose stack (deploy/head/docker-compose.yml).
#
# Prerequisite
# ------------
#   Run deploy/keycloak/setup-keycloak.sh first to configure OIDC identity
#   provider. This script reads OIDC_DISCOVERY_URL and KC_GATEWAY_CLIENT_SECRET
#   from /opt/stroma-ai/config.env (set by setup-keycloak.sh).
#
# Responsibilities
# ----------------
#   1. Verify or detect the Compose command (podman compose / podman-compose).
#   2. Read OIDC configuration from global config (or prompt if missing).
#   3. Locate or create the .env configuration file from config.example.env.
#   4. Optionally generate a self-signed TLS certificate pair for nginx.
#   5. Verify Slurm CLI binaries are accessible at bind-mount paths.
#   6. Build the gateway and watcher container images.
#   7. Pull pre-built images (nginx:1.27-alpine, rayproject/ray:2.40.0-py311,
#      vllm/vllm-openai:v0.7.2).
#   8. Start the stack with `compose up -d`.
#
# Usage
# -----
#   ./setup-head.sh                          # interactive
#   ./setup-head.sh --config=/path/.env      # explicit config file
#   ./setup-head.sh --gen-certs              # generate self-signed TLS
#   ./setup-head.sh --build-only             # build images but don't start
#   ./setup-head.sh --start-only             # start without rebuilding
#   ./setup-head.sh --dry-run --yes          # non-interactive dry-run
#   ./setup-head.sh -h | --help
#
# Run this script as the user who will operate the Compose stack.
# For TLS cert generation (--gen-certs), root is required unless the cert
# directory is writable by the current user.
# =============================================================================

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

# Global config file path (shared by all StromaAI components)
GLOBAL_CONFIG_ENV="${STROMA_CONFIG_ENV:-/opt/stroma-ai/config.env}"

# ---------------------------------------------------------------------------
# Colour helpers (inline — no lib dependency for a standalone setup script)
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
    RED='\033[0;31m' YELLOW='\033[1;33m' GREEN='\033[0;32m'
    CYAN='\033[0;36m' BOLD='\033[1m' RESET='\033[0m'
else
    RED='' YELLOW='' GREEN='' CYAN='' BOLD='' RESET=''
fi

log_info()  { echo -e "${CYAN}[INFO]${RESET}  $*"; }
log_ok()    { echo -e "${GREEN}[OK]${RESET}    $*"; }
log_warn()  { echo -e "${YELLOW}[WARN]${RESET}  $*"; }
log_error() { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
log_step()  { echo -e "\n${BOLD}▸ $*${RESET}"; }
die()       { log_error "$*"; exit 1; }

confirm() {
    local msg="${1:-Continue?}"
    if [[ "${STROMA_YES:-0}" == "1" ]]; then return 0; fi
    read -r -p "$(echo -e "${YELLOW}${msg} [y/N]${RESET} ")" _ans
    [[ "${_ans:-n}" =~ ^[Yy] ]]
}

run_cmd() {
    if [[ "${STROMA_DRY_RUN:-0}" == "1" ]]; then
        echo -e "${YELLOW}[DRY-RUN]${RESET} $*"
        return 0
    fi
    "$@"
}

backup_file() {
    local f="$1"
    [[ -f "${f}" ]] || return 0
    local bak="${f}.bak.$(date +%Y%m%d%H%M%S)"
    cp "${f}" "${bak}"
    log_info "Backed up ${f} → ${bak}"
}

require_cmd() {
    command -v "$1" &>/dev/null || die "Required command not found: $1"
}

# ---------------------------------------------------------------------------
# open_firewall_port PORT/PROTO [ZONE]
# ---------------------------------------------------------------------------
open_firewall_port() {
    local port_proto="$1"
    local zone="${2:-}"
    local zone_arg=""
    [[ -n "${zone}" ]] && zone_arg="--zone=${zone}"

    if [[ "${STROMA_DRY_RUN:-0}" == "1" ]]; then
        echo -e "${YELLOW}[DRY-RUN]${RESET} firewall-cmd --permanent ${zone_arg:+${zone_arg} }--add-port=${port_proto} && firewall-cmd --reload"
        return 0
    fi
    if ! command -v firewall-cmd &>/dev/null; then
        log_warn "firewall-cmd not found — skipping firewall rule for ${port_proto}"
        return 0
    fi
    if ! systemctl is-active --quiet firewalld 2>/dev/null; then
        log_warn "firewalld is not running — skipping firewall rule for ${port_proto}"
        return 0
    fi

    # Determine how to run firewall-cmd: root runs directly; non-root tries sudo.
    local fw_cmd="firewall-cmd"
    if [[ "$(id -u)" -ne 0 ]]; then
        if command -v sudo &>/dev/null && sudo -n firewall-cmd --version &>/dev/null 2>&1; then
            fw_cmd="sudo firewall-cmd"
        else
            log_warn "Firewall: cannot open ${port_proto} (not root and sudo not available/passwordless)"
            log_warn "Run manually: sudo firewall-cmd --permanent ${zone_arg} --add-port=${port_proto} && sudo firewall-cmd --reload"
            return 0
        fi
    fi

    if ${fw_cmd} --permanent ${zone_arg} --query-port="${port_proto}" &>/dev/null; then
        log_info "Firewall: port ${port_proto} already open${zone:+ in zone ${zone}}"
        return 0
    fi
    log_info "Firewall: opening ${port_proto}${zone:+ in zone ${zone}} ..."
    ${fw_cmd} --permanent ${zone_arg} --add-port="${port_proto}"
    ${fw_cmd} --reload
    log_ok "Firewall: ${port_proto} is open"
}

# ---------------------------------------------------------------------------
# install_systemd_service SRC_FILE SERVICE_NAME
# ---------------------------------------------------------------------------
install_systemd_service() {
    local src="$1"
    local name="$2"
    local dest="/etc/systemd/system/${name}.service"

    if [[ "${STROMA_DRY_RUN:-0}" == "1" ]]; then
        echo -e "${YELLOW}[DRY-RUN]${RESET} install systemd unit: ${src} → ${dest}"
        echo -e "${YELLOW}[DRY-RUN]${RESET} systemctl daemon-reload && systemctl enable --now ${name}"
        return 0
    fi
    if [[ ! -f "${src}" ]]; then
        die "Systemd unit file not found: ${src}"
    fi
    log_info "Installing systemd unit: ${dest}"
    cp -p "${src}" "${dest}"
    chmod 644 "${dest}"
    systemctl daemon-reload
    systemctl enable --now "${name}"
    log_ok "Service ${name} enabled and started"
}

# ---------------------------------------------------------------------------
# read_config_var — read KEY from global config file
# ---------------------------------------------------------------------------
read_config_var() {
    local key="$1"
    grep -E "^${key}=" "${GLOBAL_CONFIG_ENV}" 2>/dev/null | cut -d= -f2- || true
}

# ---------------------------------------------------------------------------
# write_env_var — safely write KEY=VALUE to a .env file
# ---------------------------------------------------------------------------
# Uses Python to avoid sed breakage with special chars in values
# (|, &, \, newlines). Python 3 is a hard prerequisite for StromaAI.
# ---------------------------------------------------------------------------
write_env_var() {
    local key="$1" value="$2" file="$3"
    python3 - "${key}" "${value}" "${file}" <<'PYEOF'
import sys, re, os

key, value, path = sys.argv[1], sys.argv[2], sys.argv[3]
entry = key + "=" + value + "\n"

if os.path.exists(path):
    with open(path, "r") as fh:
        lines = fh.readlines()
    updated = False
    for i, line in enumerate(lines):
        if re.match(r"^" + re.escape(key) + r"=", line):
            lines[i] = entry
            updated = True
            break
    if not updated:
        lines.append(entry)
    with open(path, "w") as fh:
        fh.writelines(lines)
else:
    with open(path, "w") as fh:
        fh.write(entry)
PYEOF
}

# Source detect.sh for detect_os() — log_warn/die must be defined first (above)
# shellcheck source=install/lib/detect.sh
source "${REPO_ROOT}/install/lib/detect.sh"

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
_show_usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Options:
  --config=FILE     Path to .env config file (default: deploy/head/.env)
  --gen-certs       Generate self-signed TLS certs in TLS_CERT_PATH
  --build-only      Build images but don't start the stack
  --no-start        Alias for --build-only
  --start-only      Start stack without rebuilding images
  --dry-run         Print commands without executing them
  --yes             Non-interactive: auto-confirm all prompts
  -h, --help        Show this help and exit

Environment variables honoured:
  STROMA_DRY_RUN=1  Same as --dry-run
  STROMA_YES=1      Same as --yes
EOF
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
CONFIG_FILE="${SCRIPT_DIR}/.env"
GEN_CERTS=0
BUILD_ONLY=0
START_ONLY=0

for _arg in "$@"; do
    case "${_arg}" in
        --config=*)    CONFIG_FILE="${_arg#--config=}" ;;
        --gen-certs)   GEN_CERTS=1 ;;
        --build-only|--no-start) BUILD_ONLY=1 ;;
        --start-only)  START_ONLY=1 ;;
        --dry-run)     export STROMA_DRY_RUN=1 ;;
        --yes)         export STROMA_YES=1 ;;
        -h|--help)     _show_usage; exit 0 ;;
        *) die "Unknown argument: ${_arg}. Use --help for usage." ;;
    esac
done
unset _arg

# ---------------------------------------------------------------------------
# Detect Compose command
# ---------------------------------------------------------------------------
detect_compose() {
    if podman compose version &>/dev/null 2>&1; then
        COMPOSE_CMD="podman compose"
        log_ok "Compose: using 'podman compose' (Podman 4.x built-in)"
    elif command -v podman-compose &>/dev/null; then
        COMPOSE_CMD="podman-compose"
        log_ok "Compose: using 'podman-compose' (standalone)"
    else
        die "No Podman Compose implementation found.\n  Install with: dnf install podman-compose  OR  pip3 install podman-compose"
    fi
}

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║   StromaAI — Head Node Container Stack Setup         ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════╝${RESET}"
echo ""

if [[ "${STROMA_DRY_RUN:-0}" == "1" ]]; then
    log_warn "DRY-RUN mode — no changes will be made."
    echo ""
fi

detect_os
log_info "OS: ${OS_PRETTY:-unknown}"

detect_compose

# ---------------------------------------------------------------------------
# Step 0: Verify OIDC configuration from setup-keycloak.sh
# ---------------------------------------------------------------------------
log_step "Verifying Keycloak/OIDC prerequisites"

# Try to read OIDC variables from global config (set by setup-keycloak.sh)
if [[ -f "${GLOBAL_CONFIG_ENV}" ]]; then
    _oidc_discovery="$(read_config_var OIDC_DISCOVERY_URL)"
    _kc_gw_secret="$(read_config_var KC_GATEWAY_CLIENT_SECRET)"
    _kc_gw_client="$(read_config_var KC_GATEWAY_CLIENT_ID)"
    
    if [[ -n "${_oidc_discovery}" && -n "${_kc_gw_secret}" ]]; then
        log_ok "OIDC configuration found in ${GLOBAL_CONFIG_ENV}"
        log_ok "  OIDC_DISCOVERY_URL: ${_oidc_discovery}"
        log_ok "  KC_GATEWAY_CLIENT_ID: ${_kc_gw_client:-stroma-gateway}"
        
        # Export for use later
        export OIDC_DISCOVERY_URL="${_oidc_discovery}"
        export KC_GATEWAY_CLIENT_SECRET="${_kc_gw_secret}"
        export KC_GATEWAY_CLIENT_ID="${_kc_gw_client:-stroma-gateway}"
        _has_oidc_from_global=1
    else
        log_warn "Global config exists but OIDC variables incomplete."
        log_warn "Run deploy/keycloak/setup-keycloak.sh first to configure identity provider."
        _has_oidc_from_global=0
    fi
else
    log_warn "Global config not found: ${GLOBAL_CONFIG_ENV}"
    log_warn "Run deploy/keycloak/setup-keycloak.sh first to configure identity provider."
    log_warn "You will be prompted for OIDC values during configuration."
    _has_oidc_from_global=0
fi

# ---------------------------------------------------------------------------
# Step 1: Configuration file
# ---------------------------------------------------------------------------
log_step "Configuration"

if [[ ! -f "${CONFIG_FILE}" ]]; then
    log_warn ".env not found at: ${CONFIG_FILE}"
    EXAMPLE="${REPO_ROOT}/config/config.example.env"
    if confirm "Copy config.example.env to ${CONFIG_FILE} as a starting point?"; then
        backup_file "${CONFIG_FILE}"
        run_cmd cp "${EXAMPLE}" "${CONFIG_FILE}"
        log_ok "Copied to ${CONFIG_FILE}"
        log_warn "IMPORTANT: Edit ${CONFIG_FILE} and fill in all required values before continuing."
        log_warn "  Especially: STROMA_API_KEY, STROMA_MODEL_PATH, STROMA_HEAD_HOST,"
        log_warn \"              STROMA_SLURM_PARTITION\"
        log_warn \"  Note: OIDC_DISCOVERY_URL should be set by deploy/keycloak/setup-keycloak.sh\"
        if [[ "${STROMA_YES:-0}" != "1" ]]; then
            confirm "Press Y when you have finished editing ${CONFIG_FILE}" || die "Aborted."
        fi
    else
        die "No .env file available. Create ${CONFIG_FILE} from config/config.example.env."
    fi
else
    log_ok "Config file: ${CONFIG_FILE}"
fi

# Source .env to read TLS_CERT_PATH and validate critical variables
set -a
# shellcheck disable=SC1090
source "${CONFIG_FILE}" 2>/dev/null || true
set +a

# Auto-generate STROMA_API_KEY if missing or still placeholder
if [[ -z "${STROMA_API_KEY:-}" || "${STROMA_API_KEY}" == *"CHANGEME"* ]]; then
    if [[ "${STROMA_YES:-0}" == "1" ]]; then
        STROMA_API_KEY=$(openssl rand -hex 32)
        log_info "Generated API key: ${STROMA_API_KEY}"
    else
        echo -en "${BOLD}Enter STROMA_API_KEY (or press Enter to generate one): ${RESET}"
        read -r input_key
        if [[ -z "${input_key}" ]]; then
            STROMA_API_KEY=$(openssl rand -hex 32)
            log_info "Generated API key: ${STROMA_API_KEY}"
        else
            STROMA_API_KEY="${input_key}"
        fi
        unset input_key
    fi
    # Write back into config file
    backup_file "${CONFIG_FILE}"
    write_env_var "STROMA_API_KEY" "${STROMA_API_KEY}" "${CONFIG_FILE}"
    log_ok "STROMA_API_KEY written to ${CONFIG_FILE}"
fi
export STROMA_API_KEY

# Prompt for a required variable if it is missing or still a placeholder,
# then write the value back into the config file.
_backed_up_config=0
_prompt_var() {
    local var="$1" prompt="$2" val="${!1:-}"
    if [[ -z "${val}" || "${val}" == *"CHANGEME"* ]]; then
        if [[ "${STROMA_YES:-0}" == "1" ]]; then
            die "${var} is required but not set in ${CONFIG_FILE}. Re-run without --yes and enter the value interactively."
        fi
        if [[ "${_backed_up_config}" -eq 0 ]]; then
            backup_file "${CONFIG_FILE}"
            _backed_up_config=1
        fi
        echo -en "${BOLD}${prompt}: ${RESET}"
        read -r val
        [[ -z "${val}" ]] && die "${var} cannot be empty."
        write_env_var "${var}" "${val}" "${CONFIG_FILE}"
        log_ok "${var} written to ${CONFIG_FILE}"
        export "${var}=${val}"
    fi
}

_prompt_var STROMA_HEAD_HOST      "Head node hostname or IP (e.g. hpctpa3pl0003.foobar.org)"
_prompt_var STROMA_SLURM_PARTITION "Slurm partition name for GPU workers (e.g. gpu)"
_prompt_var STROMA_MODEL_PATH     "Absolute path to model weights on shared storage (e.g. /share/models/Qwen2.5-Coder-32B-Instruct-AWQ)"

# Only prompt for OIDC_DISCOVERY_URL if not already loaded from global config
if [[ "${_has_oidc_from_global:-0}" -eq 0 ]]; then
    _prompt_var OIDC_DISCOVERY_URL "OIDC discovery URL from Keycloak (e.g. http://localhost:8080/realms/stroma-ai/.well-known/openid-configuration)"
fi

log_ok "Config validation passed"

# ---------------------------------------------------------------------------
# Step 2: TLS certificates
# ---------------------------------------------------------------------------
log_step "TLS Certificates"

TLS_CERT_PATH="${TLS_CERT_PATH:-/etc/ssl/stroma-ai}"
TLS_CERT="${TLS_CERT_PATH}/server.crt"
TLS_KEY="${TLS_CERT_PATH}/server.key"

if [[ -f "${TLS_CERT}" && -f "${TLS_KEY}" ]]; then
    log_ok "TLS certs found: ${TLS_CERT}"
elif [[ "${GEN_CERTS}" -eq 1 ]]; then
    log_info "Generating self-signed TLS certificate pair..."
    run_cmd mkdir -p "${TLS_CERT_PATH}"
    _cn="${STROMA_HEAD_HOST:-stroma-ai.local}"
    run_cmd openssl req -x509 -nodes -days 3650 -newkey rsa:4096 \
        -keyout "${TLS_KEY}" \
        -out    "${TLS_CERT}" \
        -subj   "/CN=${_cn}" \
        -addext "subjectAltName=DNS:${_cn}"
    run_cmd chmod 600 "${TLS_KEY}"
    log_ok "Self-signed cert generated: ${TLS_CERT} (valid 10 years)"
    log_warn "For production, replace with a CA-signed certificate."
else
    log_warn "TLS certs not found at ${TLS_CERT_PATH}/"
    log_warn "Generate with: $0 --gen-certs"
    log_warn "Or set TLS_CERT_PATH in ${CONFIG_FILE} to point at existing certs."
    if ! confirm "Continue without verified TLS certs? (nginx may fail to start)"; then
        die "Aborted. Run with --gen-certs to create self-signed certs."
    fi
fi

# ---------------------------------------------------------------------------
# Step 3: Slurm CLI access
# ---------------------------------------------------------------------------
log_step "Slurm CLI Bind-Mount Verification"

_slurm_warn=0
for _bin_var in SLURM_SBATCH_BIN SLURM_SQUEUE_BIN SLURM_SCANCEL_BIN SLURM_SINFO_BIN; do
    _bin_name="$(echo "${_bin_var}" | sed 's/^SLURM_//;s/_BIN$//' | tr '[:upper:]' '[:lower:]')"
    _default_bin="/usr/bin/${_bin_name}"
    _path="${!_bin_var:-}"
    
    # Try to find binary: 1) config value, 2) PATH, 3) default location
    if [[ -n "${_path}" && -x "${_path}" ]]; then
        log_ok "Slurm binary verified: ${_path}"
    elif command -v "${_bin_name}" &>/dev/null; then
        _path="$(command -v "${_bin_name}")"
        log_ok "Slurm binary found in PATH: ${_path}"
        # Auto-populate config variable for container bind-mount
        write_env_var "${_bin_var}" "${_path}" "${CONFIG_FILE}"
        log_info "  → Set ${_bin_var}=${_path} in ${CONFIG_FILE}"
    elif [[ -x "${_default_bin}" ]]; then
        _path="${_default_bin}"
        log_ok "Slurm binary verified: ${_path}"
    else
        log_warn "Slurm binary not found: ${_bin_name}"
        log_warn "  Not in PATH, not at ${_default_bin}, and ${_bin_var} not set in ${CONFIG_FILE}"
        log_warn "  If Slurm is available via environment modules, run: module load slurm"
        _slurm_warn=1
    fi
done
unset _bin_var _path _default_bin _bin_name

MUNGE_SOCK_DIR="${SLURM_MUNGE_SOCKET_DIR:-/var/run/munge}"
if [[ -S "${MUNGE_SOCK_DIR}/munge.socket.2" ]]; then
    log_ok "MUNGE socket found: ${MUNGE_SOCK_DIR}/munge.socket.2"
else
    log_warn "MUNGE socket not found at ${MUNGE_SOCK_DIR}/munge.socket.2"
    log_warn "  The watcher container requires MUNGE for Slurm authentication."
    log_warn "  Set SLURM_MUNGE_SOCKET_DIR in ${CONFIG_FILE} if using a non-default path."
    _slurm_warn=1
fi

if [[ "${_slurm_warn}" -eq 1 ]]; then
    log_warn "The watcher service may fail to submit Slurm jobs until Slurm paths are configured."
    confirm "Continue anyway?" || die "Aborted."
fi

# ---------------------------------------------------------------------------
# Step 4: Model weights
# ---------------------------------------------------------------------------
log_step "Model Weights"

if [[ -d "${STROMA_MODEL_PATH:-}" ]]; then
    log_ok "Model path exists: ${STROMA_MODEL_PATH}"
else
    log_warn "Model path not found: ${STROMA_MODEL_PATH:-<unset>}"
    log_warn "  vLLM will fail to start until model weights are present at this path."
    confirm "Continue anyway?" || die "Aborted."
fi

# ---------------------------------------------------------------------------
# Step 5: Build container images
# ---------------------------------------------------------------------------
if [[ "${START_ONLY}" -eq 0 ]]; then
    log_step "Building Container Images"
    log_info "Building stroma-ai-gateway..."
    run_cmd ${COMPOSE_CMD} \
        --env-file "${CONFIG_FILE}" \
        -f "${SCRIPT_DIR}/docker-compose.yml" \
        build gateway

    log_info "Building stroma-ai-watcher..."
    run_cmd ${COMPOSE_CMD} \
        --env-file "${CONFIG_FILE}" \
        -f "${SCRIPT_DIR}/docker-compose.yml" \
        build watcher

    log_ok "Custom images built successfully."

    log_step "Pulling Pre-built Images"
    for _svc in nginx ray-head vllm; do
        log_info "Pulling image for service: ${_svc}"
        run_cmd ${COMPOSE_CMD} \
            --env-file "${CONFIG_FILE}" \
            -f "${SCRIPT_DIR}/docker-compose.yml" \
            pull "${_svc}" || \
            log_warn "Pull failed for ${_svc} — may continue if image is already cached."
    done
    unset _svc
    log_ok "Image pull complete."
fi

if [[ "${BUILD_ONLY}" -eq 1 ]]; then
    log_ok "Build complete. Run the stack with: ${COMPOSE_CMD} up -d"
    exit 0
fi

# ---------------------------------------------------------------------------
# Step 6: Start the stack
# ---------------------------------------------------------------------------
log_step "Starting Head Node Stack"

confirm "Start all StromaAI head node services?" || die "Aborted by user."

run_cmd ${COMPOSE_CMD} \
    --env-file "${CONFIG_FILE}" \
    -f "${SCRIPT_DIR}/docker-compose.yml" \
    up -d

log_step "Configuring Firewall"
open_firewall_port "80/tcp"
open_firewall_port "${STROMA_HTTPS_PORT:-443}/tcp"

log_step "Installing Systemd Service"
install_systemd_service "${SCRIPT_DIR}/stroma-ai-head.service" "stroma-ai-head"

echo ""
log_ok "StromaAI head node stack started."
echo ""
echo -e "${BOLD}╔══════════════════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║   Head Node Stack — Summary                           ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════════════════╝${RESET}"
echo ""
echo "  nginx     — HTTPS reverse proxy  → https://${STROMA_HEAD_HOST:-localhost}:${STROMA_HTTPS_PORT:-443}"
echo "  gateway   — OIDC security proxy  → http://localhost:${GATEWAY_PORT:-9000}"
echo "  ray-head  — Ray GCS coordinator  → localhost:${STROMA_RAY_PORT:-6380}"
echo "  vllm      — vLLM inference API   → http://localhost:${STROMA_VLLM_PORT:-8000}"
echo "  watcher   — Slurm burst scaler"
echo ""
echo "  Logs : ${COMPOSE_CMD} -f ${SCRIPT_DIR}/docker-compose.yml logs -f"
echo "  Status: ${COMPOSE_CMD} -f ${SCRIPT_DIR}/docker-compose.yml ps"
echo "  Stop : ${COMPOSE_CMD} -f ${SCRIPT_DIR}/docker-compose.yml down"
echo ""
echo "  Next: python3 src/stroma_cli.py --status"
echo ""
