#!/usr/bin/env bash
# =============================================================================
# StromaAI — Head Node Container Stack Setup
# =============================================================================
# Prepares the environment for running the StromaAI head node as a Podman
# Compose stack (deploy/head/docker-compose.yml).
#
# Responsibilities
# ----------------
#   1. Verify or detect the Compose command (podman compose / podman-compose).
#   2. Locate or create the .env configuration file from config.example.env.
#   3. Optionally generate a self-signed TLS certificate pair for nginx.
#   4. Verify Slurm CLI binaries are accessible at bind-mount paths.
#   5. Build the gateway and watcher container images.
#   6. Pull pre-built images (nginx:1.27-alpine, rayproject/ray:2.40.0-py311,
#      vllm/vllm-openai:v0.7.2).
#   7. Start the stack with `compose up -d`.
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

# ---------------------------------------------------------------------------
# Colour helpers (inline — no lib dependency for a standalone setup script)
# ---------------------------------------------------------------------------
_tty() { [[ -t 1 ]]; }
if _tty; then
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

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
_show_usage() {
    cat <<EOF
Usage: $0 [OPTIONS]

Options:
  --config=FILE     Path to .env config file (default: deploy/head/.env)
  --gen-certs       Generate self-signed TLS certs in TLS_CERT_PATH
  --build-only      Build images then exit, don't start the stack
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
        --build-only)  BUILD_ONLY=1 ;;
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
echo -e "${BOLD}"
echo "╔══════════════════════════════════════════════════════╗"
echo "║   StromaAI — Head Node Container Stack Setup         ║"
echo "╚══════════════════════════════════════════════════════╝"
echo -e "${RESET}"

detect_compose

# ---------------------------------------------------------------------------
# Step 1: Configuration file
# ---------------------------------------------------------------------------
log_step "Configuration"

if [[ ! -f "${CONFIG_FILE}" ]]; then
    log_warn ".env not found at: ${CONFIG_FILE}"
    EXAMPLE="${REPO_ROOT}/config/config.example.env"
    if confirm "Copy config.example.env to ${CONFIG_FILE} as a starting point?"; then
        run_cmd cp "${EXAMPLE}" "${CONFIG_FILE}"
        log_ok "Copied to ${CONFIG_FILE}"
        log_warn "IMPORTANT: Edit ${CONFIG_FILE} and fill in all required values before continuing."
        log_warn "  Especially: STROMA_API_KEY, STROMA_MODEL_PATH, STROMA_HEAD_HOST,"
        log_warn "              OIDC_DISCOVERY_URL, STROMA_SLURM_PARTITION"
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

# Validate mandatory variables are set and not placeholders
_check_var() {
    local var="$1" val="${!1:-}"
    if [[ -z "${val}" ]]; then
        log_error "Required variable ${var} is not set in ${CONFIG_FILE}"
        return 1
    fi
    if [[ "${val}" == *"CHANGEME"* ]]; then
        log_error "${var} still contains the placeholder value in ${CONFIG_FILE}"
        return 1
    fi
    return 0
}

VALIDATION_FAILED=0
for _var in STROMA_API_KEY STROMA_MODEL_PATH STROMA_HEAD_HOST STROMA_SLURM_PARTITION; do
    _check_var "${_var}" || VALIDATION_FAILED=1
done
unset _var

[[ "${VALIDATION_FAILED}" -eq 0 ]] || \
    die "Fix the above variables in ${CONFIG_FILE} then re-run this script."

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
    _default_bin="/usr/bin/$(echo "${_bin_var}" | sed 's/SLURM_//;s/_BIN//;tr A-Z a-z')"
    _path="${!_bin_var:-${_default_bin}}"
    if [[ -x "${_path}" ]]; then
        log_ok "Slurm binary verified: ${_path}"
    else
        log_warn "Slurm binary not found: ${_path}"
        log_warn "  Set ${_bin_var}=/actual/path/to/$(basename "${_path}") in ${CONFIG_FILE}"
        _slurm_warn=1
    fi
done
unset _bin_var _path _default_bin

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

echo ""
log_ok "StromaAI head node stack started."
echo ""
echo -e "${BOLD}Services:${RESET}"
echo "  nginx     — HTTPS reverse proxy  → https://${STROMA_HEAD_HOST:-localhost}:${STROMA_HTTPS_PORT:-443}"
echo "  gateway   — OIDC security proxy  → http://localhost:${GATEWAY_PORT:-9000}"
echo "  ray-head  — Ray GCS coordinator  → localhost:${STROMA_RAY_PORT:-6380}"
echo "  vllm      — vLLM inference API   → http://localhost:${STROMA_VLLM_PORT:-8000}"
echo "  watcher   — Slurm burst scaler"
echo ""
echo -e "${BOLD}Useful commands:${RESET}"
echo "  ${COMPOSE_CMD} -f ${SCRIPT_DIR}/docker-compose.yml logs -f"
echo "  ${COMPOSE_CMD} -f ${SCRIPT_DIR}/docker-compose.yml ps"
echo "  ${COMPOSE_CMD} -f ${SCRIPT_DIR}/docker-compose.yml down"
