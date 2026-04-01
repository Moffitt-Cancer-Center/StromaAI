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
#
# Options (used with 'up'):
#   --inference      Include the ray-head + vLLM inference stack
#   --watcher        Include the Slurm burst scaler (requires sbatch on host)
#   --full           Equivalent to --inference --watcher
#   --model-path=PATH  Override the model weights directory
#   --port=PORT      Override STROMA_HTTPS_PORT (nginx TLS, default 443)
#   --dry-run        Print commands without executing them
#   --rebuild        Force rebuild of custom images before starting
#   -h, --help       Show this help
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
MODEL_PATH_OVERRIDE=""
HTTPS_PORT_OVERRIDE=""
DRY_RUN=0
DO_REBUILD=0
SERVICE_ARG=""

for _arg in "$@"; do
    case "${_arg}" in
        up|down|restart|build|logs|ps|status|clean|ip)
            SUBCMD="${_arg}" ;;
        --inference)   PROFILE_INFERENCE=1 ;;
        --watcher)     PROFILE_WATCHER=1 ;;
        --full)        PROFILE_INFERENCE=1; PROFILE_WATCHER=1 ;;
        --model-path=*) MODEL_PATH_OVERRIDE="${_arg#--model-path=}" ;;
        --port=*)      HTTPS_PORT_OVERRIDE="${_arg#--port=}" ;;
        --dry-run)     DRY_RUN=1 ;;
        --rebuild)     DO_REBUILD=1 ;;
        -h|--help)     usage ;;
        -*)            die "Unknown option: ${_arg}. Use --help for usage." ;;
        *)             SERVICE_ARG="${_arg}" ;;  # service name for logs/restart
    esac
done
unset _arg

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
        grep -E "^${key}=" "${file}" | head -1 | cut -d= -f2-
    fi
}

# ---------------------------------------------------------------------------
# gen_secret [length_bytes] — generate a random hex secret
# ---------------------------------------------------------------------------
gen_secret() { openssl rand -hex "${1:-32}"; }

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

    [[ -z "${db_pass}" ]]          && db_pass=$(gen_secret 16)
    [[ -z "${admin_pass}" ]]       && admin_pass=$(gen_secret 12)
    [[ -z "${api_key}" ]]          && api_key=$(gen_secret 32)
    [[ -z "${webui_secret}" ]]     && webui_secret=$(gen_secret 32)
    [[ -z "${gw_client_secret}" ]] && gw_client_secret=$(gen_secret 16)
    [[ -z "${owu_client_secret}" ]] && owu_client_secret=$(gen_secret 16)

    write_env_var KC_DB_PASSWORD            "${db_pass}"         "${DEV_ENV}"
    write_env_var KC_ADMIN_USER             "admin"              "${DEV_ENV}"
    write_env_var KC_ADMIN_PASSWORD         "${admin_pass}"      "${DEV_ENV}"
    write_env_var STROMA_API_KEY            "${api_key}"         "${DEV_ENV}"
    write_env_var WEBUI_SECRET_KEY          "${webui_secret}"    "${DEV_ENV}"
    write_env_var KC_GATEWAY_CLIENT_SECRET  "${gw_client_secret}" "${DEV_ENV}"
    write_env_var KC_OPENWEBUI_CLIENT_SECRET "${owu_client_secret}" "${DEV_ENV}"

    # Paths and ports
    local model_path; model_path=$(read_env_var DEV_MODEL_PATH "${DEV_ENV}")
    [[ -z "${model_path}" ]] && model_path="${MODELS_DIR}"
    write_env_var DEV_MODEL_PATH     "${model_path}"      "${DEV_ENV}"
    write_env_var DEV_SHARED_ROOT    "${SHARED_DIR}"      "${DEV_ENV}"
    write_env_var KC_PORT            "8080"               "${DEV_ENV}"
    write_env_var OPENWEBUI_PORT     "3000"               "${DEV_ENV}"
    write_env_var GATEWAY_PORT       "9000"               "${DEV_ENV}"
    write_env_var STROMA_VLLM_PORT   "8000"               "${DEV_ENV}"
    write_env_var STROMA_RAY_PORT    "6380"               "${DEV_ENV}"
    write_env_var STROMA_HTTPS_PORT  "${HTTPS_PORT_OVERRIDE:-443}" "${DEV_ENV}"
    write_env_var WEBUI_NAME         "StromaAI Dev"       "${DEV_ENV}"

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
# check_slurm_binaries — warn if Slurm binaries are missing (watcher profile)
# ---------------------------------------------------------------------------
check_slurm_binaries() {
    local missing=0
    for b in sbatch squeue scancel sinfo; do
        if ! command -v "${b}" &>/dev/null; then
            log_warn "Slurm binary not found: ${b}"
            missing=1
        fi
    done
    if [[ "${missing}" -eq 1 ]]; then
        log_warn "Watcher service requires Slurm client binaries on this host."
        log_warn "The watcher container will fail to start without them."
        log_warn "To skip the watcher, use:  ./dev.sh up --inference"
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

        ensure_dot_env
        generate_tls_cert

        if [[ "${PROFILE_WATCHER}" -eq 1 ]]; then
            log_step "Checking Slurm binaries (watcher profile)"
            check_slurm_binaries
        fi

        if [[ "${DO_REBUILD}" -eq 1 ]]; then
            log_step "Building custom images"
            compose build gateway watcher
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

        compose up -d --remove-orphans

        # Brief wait for keycloak to start accepting connections
        if [[ "${DRY_RUN}" -eq 0 ]]; then
            local kc_port; kc_port=$(read_env_var KC_PORT "${DEV_ENV}"); kc_port="${kc_port:-8080}"
            log_info "Waiting for Keycloak (can take up to 90s on first run)..."
            local waited=0
            until bash -c "</dev/tcp/127.0.0.1/${kc_port}" 2>/dev/null; do
                sleep 5; waited=$((waited + 5))
                printf '.'
                (( waited >= 120 )) && { echo; log_warn "Keycloak hasn't responded in 120s — check: ./dev.sh logs keycloak"; break; }
            done
            echo
            (( waited < 120 )) && log_ok "Keycloak is accepting connections"
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
        run_cmd rm -rf "${CERT_DIR}"
        log_ok "Cleaned. dev-data/models/ and dev-data/shared/ are preserved."
        ;;

    # -------------------------------------------------------------------------
    ip)
        detect_host_ip
        ;;

    *)
        usage
        ;;
esac
