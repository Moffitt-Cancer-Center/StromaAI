#!/usr/bin/env bash
# =============================================================================
# StromaAI — Main Installer
# =============================================================================
# Installs the StromaAI HPC burst inference platform on RHEL 8, Rocky Linux 9,
# or Ubuntu 22.04. Supports head node, Slurm worker node, and OOD integration.
#
# Usage:
#   sudo ./install/install.sh [OPTIONS]
#
# Options:
#   --mode=head     Install head node (Ray + vLLM + nginx + systemd)
#   --mode=worker   Configure Slurm worker nodes (Apptainer + NVIDIA toolkit)
#   --mode=ood      Install Open OnDemand integration
#   --config=FILE   Path to a pre-filled config.env (skips interactive prompts)
#   --dry-run       Print what would be done without making changes
#   --yes           Non-interactive mode (auto-answer yes to confirmations)
#   --help          Show this help message
#
# Examples:
#   sudo ./install/install.sh --mode=head
#   sudo ./install/install.sh --mode=worker --yes
#   sudo ./install/install.sh --mode=head --config=/tmp/my-site.env --dry-run
# =============================================================================

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# ---------------------------------------------------------------------------
# Source library modules
# ---------------------------------------------------------------------------
# shellcheck source=install/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=install/lib/detect.sh
source "${SCRIPT_DIR}/lib/detect.sh"
# shellcheck source=install/lib/packages.sh
source "${SCRIPT_DIR}/lib/packages.sh"
# shellcheck source=install/lib/apptainer.sh
source "${SCRIPT_DIR}/lib/apptainer.sh"
# shellcheck source=install/lib/nvidia.sh
source "${SCRIPT_DIR}/lib/nvidia.sh"
# shellcheck source=install/lib/selinux.sh
source "${SCRIPT_DIR}/lib/selinux.sh"

# ---------------------------------------------------------------------------
# Defaults and argument parsing
# ---------------------------------------------------------------------------
MODE=""
CONFIG_FILE=""
export STROMA_DRY_RUN=0
export STROMA_YES=0

usage() {
    cat <<EOF
Usage: sudo $0 [OPTIONS]

Options:
  --mode=head     Install Ray head + vLLM + nginx (Proxmox VM / head server)
  --mode=worker   Configure Slurm worker nodes (GPU nodes)
  --mode=ood      Install Open OnDemand integration
  --config=FILE   Path to pre-filled config.env template
  --dry-run       Show what would be done without making changes
  --yes           Non-interactive (no confirmation prompts)
  --help          Show this help

Supported OS: RHEL 8.x, Rocky Linux 9.x, Ubuntu 22.04
EOF
    exit 0
}

for arg in "$@"; do
    case "${arg}" in
        --mode=*)     MODE="${arg#*=}" ;;
        --config=*)   CONFIG_FILE="${arg#*=}" ;;
        --dry-run)    STROMA_DRY_RUN=1 ;;
        --yes)        STROMA_YES=1 ;;
        --help|-h)    usage ;;
        *)            die "Unknown argument: ${arg}. Run with --help for usage." ;;
    esac
done

[[ -z "${MODE}" ]] && die "Required: --mode=head|worker|ood. Run with --help for usage."

# ---------------------------------------------------------------------------
# Bootstrap
# ---------------------------------------------------------------------------
require_root

echo ""
echo -e "${BOLD}╔══════════════════════════════════════════╗${RESET}"
echo -e "${BOLD}║       StromaAI Installer v1.0             ║${RESET}"
echo -e "${BOLD}╚══════════════════════════════════════════╝${RESET}"
echo ""

if [[ "${STROMA_DRY_RUN}" == "1" ]]; then
    log_warn "DRY-RUN mode — no changes will be made."
    echo ""
fi

detect_os

# ---------------------------------------------------------------------------
# Configuration loading / interactive setup
# ---------------------------------------------------------------------------
load_or_prompt_config() {
    log_step "Configuration"

    if [[ -n "${CONFIG_FILE}" ]]; then
        [[ -f "${CONFIG_FILE}" ]] || die "Config file not found: ${CONFIG_FILE}"
        log_info "Loading configuration from: ${CONFIG_FILE}"
        # shellcheck source=/dev/null
        source "${CONFIG_FILE}"
    elif [[ -f ${STROMA_INSTALL_DIR:-/opt/stroma-ai}/config.env ]]; then
        log_info "Existing config found at ${STROMA_INSTALL_DIR:-/opt/stroma-ai}/config.env — loading."
        source "${STROMA_INSTALL_DIR:-/opt/stroma-ai}/config.env"
    else
        log_info "No config file found — running interactive setup."
        _interactive_config
    fi

    # Apply defaults for any unset values
    STROMA_INSTALL_DIR="${STROMA_INSTALL_DIR:-/opt/stroma-ai}"
    STROMA_SHARED_ROOT="${STROMA_SHARED_ROOT:-/share}"
    STROMA_HEAD_HOST="${STROMA_HEAD_HOST:-stroma-ai.$(hostname -d 2>/dev/null || echo 'cluster.local')}"
    STROMA_VLLM_PORT="${STROMA_VLLM_PORT:-8000}"
    STROMA_HTTPS_PORT="${STROMA_HTTPS_PORT:-443}"
    STROMA_RAY_PORT="${STROMA_RAY_PORT:-6380}"
    STROMA_RAY_DASHBOARD_PORT="${STROMA_RAY_DASHBOARD_PORT:-8265}"
    STROMA_MODEL_PATH="${STROMA_MODEL_PATH:-${STROMA_SHARED_ROOT}/models/Qwen2.5-Coder-32B-Instruct-AWQ}"
    STROMA_MODEL_NAME="${STROMA_MODEL_NAME:-stroma-ai-coder}"
    STROMA_CONTAINER="${STROMA_CONTAINER:-${STROMA_SHARED_ROOT}/containers/stroma-ai-vllm.sif}"
    STROMA_SLURM_PARTITION="${STROMA_SLURM_PARTITION:-stroma-ai-gpu}"
    STROMA_SLURM_ACCOUNT="${STROMA_SLURM_ACCOUNT:-stroma-ai-service}"
    STROMA_WARM_RESERVATION="${STROMA_WARM_RESERVATION:-stroma-ai-warm}"
    STROMA_SLURM_SCRIPT="${STROMA_SLURM_SCRIPT:-${STROMA_SHARED_ROOT}/slurm/stroma_ai_worker.slurm}"
    # Migrate from old default (${STROMA_SHARED_ROOT}/logs/stroma-ai -> ${STROMA_INSTALL_DIR}/logs)
    if [[ "${STROMA_LOG_DIR:-}" == "${STROMA_SHARED_ROOT}/logs/stroma-ai" ]]; then
        unset STROMA_LOG_DIR
    fi
    STROMA_LOG_DIR="${STROMA_LOG_DIR:-${STROMA_INSTALL_DIR}/logs}"
    STROMA_SLURM_WALLTIME="${STROMA_SLURM_WALLTIME:-12:00:00}"
    STROMA_MAX_BURST_WORKERS="${STROMA_MAX_BURST_WORKERS:-5}"
    STROMA_GPU_MEM_UTIL="${STROMA_GPU_MEM_UTIL:-0.85}"
    STROMA_CPU_OFFLOAD_GB="${STROMA_CPU_OFFLOAD_GB:-200}"
    STROMA_MAX_MODEL_LEN="${STROMA_MAX_MODEL_LEN:-32768}"
    STROMA_MAX_NUM_SEQS="${STROMA_MAX_NUM_SEQS:-64}"
    STROMA_VLLM_CPU_KV_THREADS="${STROMA_VLLM_CPU_KV_THREADS:-32}"
    STROMA_VLLM_QUANTIZATION="${STROMA_VLLM_QUANTIZATION:-awq}"
    STROMA_KV_CACHE_DTYPE="${STROMA_KV_CACHE_DTYPE:-auto}"
    STROMA_SCALE_UP_THRESHOLD="${STROMA_SCALE_UP_THRESHOLD:-5}"
    STROMA_SCALE_DOWN_IDLE_SECONDS="${STROMA_SCALE_DOWN_IDLE_SECONDS:-300}"
    STROMA_SCALE_UP_COOLDOWN="${STROMA_SCALE_UP_COOLDOWN:-120}"
    STROMA_STATE_FILE="${STROMA_STATE_FILE:-${STROMA_INSTALL_DIR}/state/watcher_state.json}"

    # Validate API key
    if [[ -z "${STROMA_API_KEY:-}" || "${STROMA_API_KEY}" == "CHANGEME"* ]]; then
        if [[ "${STROMA_YES}" == "1" ]]; then
            log_info "Generating random API key..."
            STROMA_API_KEY=$(openssl rand -hex 32)
        else
            echo -en "${BOLD}Enter STROMA_API_KEY (or press Enter to generate one): ${RESET}"
            read -r input_key
            if [[ -z "${input_key}" ]]; then
                STROMA_API_KEY=$(openssl rand -hex 32)
                log_info "Generated API key: ${STROMA_API_KEY}"
                log_warn "SAVE this key — you will need it for OOD configuration."
            else
                STROMA_API_KEY="${input_key}"
            fi
        fi
    fi

    export STROMA_HEAD_HOST STROMA_VLLM_PORT STROMA_HTTPS_PORT STROMA_RAY_PORT
    export STROMA_RAY_DASHBOARD_PORT STROMA_MODEL_PATH STROMA_MODEL_NAME
    export STROMA_CONTAINER STROMA_SLURM_PARTITION STROMA_SLURM_ACCOUNT
    export STROMA_SLURM_SCRIPT STROMA_SLURM_WALLTIME STROMA_MAX_BURST_WORKERS
    export STROMA_GPU_MEM_UTIL STROMA_CPU_OFFLOAD_GB STROMA_MAX_MODEL_LEN
    export STROMA_MAX_NUM_SEQS STROMA_VLLM_CPU_KV_THREADS STROMA_SCALE_UP_THRESHOLD
    export STROMA_SCALE_DOWN_IDLE_SECONDS STROMA_SCALE_UP_COOLDOWN STROMA_STATE_FILE
    export STROMA_API_KEY STROMA_SHARED_ROOT STROMA_LOG_DIR

    log_ok "Configuration loaded."
}

_interactive_config() {
    cat <<EOF

This installer needs a few site-specific values to configure StromaAI.
Press Enter to accept the default shown in [brackets].

EOF
    local default_host
    default_host="stroma-ai.$(hostname -d 2>/dev/null || echo 'cluster.local')"

    echo -en "Install directory [/opt/stroma-ai]: "
    read -r input; STROMA_INSTALL_DIR="${input:-/opt/stroma-ai}"

    echo -en "Shared filesystem root [/share]: "
    read -r input; STROMA_SHARED_ROOT="${input:-/share}"

    echo -en "Head node hostname [${default_host}]: "
    read -r input; STROMA_HEAD_HOST="${input:-${default_host}}"

    echo -en "Shared model weight path [${STROMA_SHARED_ROOT}/models/Qwen2.5-Coder-32B-Instruct-AWQ]: "
    read -r input; STROMA_MODEL_PATH="${input:-${STROMA_SHARED_ROOT}/models/Qwen2.5-Coder-32B-Instruct-AWQ}"

    echo -en "Shared container SIF path [${STROMA_SHARED_ROOT}/containers/stroma-ai-vllm.sif]: "
    read -r input; STROMA_CONTAINER="${input:-${STROMA_SHARED_ROOT}/containers/stroma-ai-vllm.sif}"

    echo -en "Slurm GPU partition [stroma-ai-gpu]: "
    read -r input; STROMA_SLURM_PARTITION="${input:-stroma-ai-gpu}"

    echo -en "Slurm account [stroma-ai-service]: "
    read -r input; STROMA_SLURM_ACCOUNT="${input:-stroma-ai-service}"

    echo -en "Max concurrent burst workers [5]: "
    read -r input; STROMA_MAX_BURST_WORKERS="${input:-5}"

    echo ""
}

# ---------------------------------------------------------------------------
# ── HEAD NODE INSTALLATION ──────────────────────────────────────────────────
# ---------------------------------------------------------------------------
install_head() {
    log_step "Installing StromaAI head node on ${OS_PRETTY}"
    confirm "This will install Ray, vLLM, nginx, and configure systemd services. Continue?" \
        || die "Installation cancelled."

    _create_system_user
    _create_directories
    _install_head_packages
    _deploy_config_env
    _deploy_source_files
    _deploy_nginx
    _generate_tls_cert
    _deploy_systemd_units
    configure_security head
    configure_firewall head
    _enable_services
    _print_head_summary
}

_create_system_user() {
    log_step "Creating stromaai system user"
    if id stromaai &>/dev/null; then
        log_info "User 'stromaai' already exists."
        return 0
    fi
    run_cmd useradd \
        --system \
        --no-create-home \
        --home-dir "${STROMA_INSTALL_DIR}" \
        --shell /sbin/nologin \
        --comment "StromaAI service account" \
        stromaai
    log_ok "User 'stromaai' created."
}

_create_directories() {
    log_step "Creating directory structure"
    local dirs=(
        "${STROMA_INSTALL_DIR}"
        "${STROMA_INSTALL_DIR}/src"
        "${STROMA_INSTALL_DIR}/state"
        /etc/ssl/stroma-ai
        "${STROMA_LOG_DIR}"
    )
    for dir in "${dirs[@]}"; do
        run_cmd mkdir -p "${dir}"
    done
    run_cmd chown -R stromaai:stromaai "${STROMA_INSTALL_DIR}"
    run_cmd chmod 750 "${STROMA_INSTALL_DIR}"
    run_cmd chown stromaai:stromaai "${STROMA_LOG_DIR}" 2>/dev/null || true
}

_install_head_packages() {
    log_step "Installing system packages"
    enable_epel
    pkg_update
    install_base_deps
    install_python311
    install_nginx

    # Install Python venv into ${STROMA_INSTALL_DIR}/venv
    install_head_python_deps
}

_deploy_config_env() {
    log_step "Writing ${STROMA_INSTALL_DIR}/config.env"
    if [[ -f ${STROMA_INSTALL_DIR}/config.env && "${STROMA_YES}" != "1" ]]; then
        backup_file "${STROMA_INSTALL_DIR}/config.env"
        if ! confirm "${STROMA_INSTALL_DIR}/config.env already exists. Overwrite?"; then
            log_info "Keeping existing config.env."
            return 0
        fi
    fi

    if [[ "${STROMA_DRY_RUN}" == "0" ]]; then
        cat > "${STROMA_INSTALL_DIR}/config.env" <<EOF
# StromaAI configuration — generated by install.sh on $(date)
# Do NOT commit this file. Contains secrets.

STROMA_INSTALL_DIR=${STROMA_INSTALL_DIR}
STROMA_SHARED_ROOT=${STROMA_SHARED_ROOT}

STROMA_HEAD_HOST=${STROMA_HEAD_HOST}
STROMA_VLLM_PORT=${STROMA_VLLM_PORT}
VLLM_INTERNAL_URL=http://127.0.0.1:${STROMA_VLLM_PORT}
STROMA_HTTPS_PORT=${STROMA_HTTPS_PORT}
STROMA_RAY_PORT=${STROMA_RAY_PORT}
STROMA_RAY_DASHBOARD_PORT=${STROMA_RAY_DASHBOARD_PORT}
STROMA_API_KEY=${STROMA_API_KEY}

# Backend URLs for nginx reverse proxy (change when services move to separate hosts)
KC_INTERNAL_URL=http://127.0.0.1:8080
OPENWEBUI_INTERNAL_URL=http://127.0.0.1:3000

STROMA_MODEL_PATH=${STROMA_MODEL_PATH}
STROMA_MODEL_NAME=${STROMA_MODEL_NAME}
STROMA_CONTAINER=${STROMA_CONTAINER}

STROMA_SLURM_PARTITION=${STROMA_SLURM_PARTITION}
STROMA_SLURM_ACCOUNT=${STROMA_SLURM_ACCOUNT}
STROMA_SLURM_SCRIPT=${STROMA_SLURM_SCRIPT}
STROMA_SLURM_WALLTIME=${STROMA_SLURM_WALLTIME}
STROMA_MAX_BURST_WORKERS=${STROMA_MAX_BURST_WORKERS}
STROMA_WARM_RESERVATION=${STROMA_WARM_RESERVATION}
STROMA_LOG_DIR=${STROMA_LOG_DIR}

STROMA_GPU_MEM_UTIL=${STROMA_GPU_MEM_UTIL}
STROMA_CPU_OFFLOAD_GB=${STROMA_CPU_OFFLOAD_GB}
STROMA_MAX_MODEL_LEN=${STROMA_MAX_MODEL_LEN}
STROMA_MAX_NUM_SEQS=${STROMA_MAX_NUM_SEQS}
STROMA_VLLM_CPU_KV_THREADS=${STROMA_VLLM_CPU_KV_THREADS}
STROMA_VLLM_QUANTIZATION=${STROMA_VLLM_QUANTIZATION}
STROMA_KV_CACHE_DTYPE=${STROMA_KV_CACHE_DTYPE}

STROMA_SCALE_UP_THRESHOLD=${STROMA_SCALE_UP_THRESHOLD}
STROMA_SCALE_DOWN_IDLE_SECONDS=${STROMA_SCALE_DOWN_IDLE_SECONDS}
STROMA_SCALE_UP_COOLDOWN=${STROMA_SCALE_UP_COOLDOWN}
STROMA_STATE_FILE=${STROMA_STATE_FILE}
EOF
        chown stromaai:stromaai "${STROMA_INSTALL_DIR}/config.env"
        chmod 640 "${STROMA_INSTALL_DIR}/config.env"
    else
        log_dry "Would write ${STROMA_INSTALL_DIR}/config.env with site values"
    fi
    log_ok "config.env written."
}

_deploy_source_files() {
    log_step "Deploying StromaAI source files to ${STROMA_INSTALL_DIR}"

    # Copy watcher
    run_cmd cp "${REPO_DIR}/src/vllm_watcher.py" "${STROMA_INSTALL_DIR}/src/vllm_watcher.py"
    run_cmd chown stromaai:stromaai "${STROMA_INSTALL_DIR}/src/vllm_watcher.py"
    run_cmd chmod 750 "${STROMA_INSTALL_DIR}/src/vllm_watcher.py"

    # Copy shared Slurm script to shared filesystem (if mounted)
    local slurm_script_dir
    slurm_script_dir="$(dirname "${STROMA_SLURM_SCRIPT}")"
    if [[ -d "${slurm_script_dir}" ]]; then
        run_cmd cp "${REPO_DIR}/deploy/slurm/stroma_ai_worker.slurm" "${STROMA_SLURM_SCRIPT}"
        run_cmd chmod 755 "${STROMA_SLURM_SCRIPT}"
        log_ok "Slurm script deployed to ${STROMA_SLURM_SCRIPT}"
    else
        log_warn "Slurm script directory ${slurm_script_dir} not found — copy manually:"
        log_warn "  cp deploy/slurm/stroma_ai_worker.slurm ${STROMA_SLURM_SCRIPT}"
    fi
}

_deploy_nginx() {
    log_step "Configuring nginx"

    # Distro-specific nginx config path
    local nginx_conf_path
    case "${OS_FAMILY}" in
        rhel)
            # RHEL/Rocky: drop file in conf.d (nginx reads all *.conf there)
            nginx_conf_path="/etc/nginx/conf.d/stroma-ai.conf"
            ;;
        debian)
            # Ubuntu: use sites-available + symlink
            nginx_conf_path="/etc/nginx/sites-available/stroma-ai"
            ;;
    esac

    backup_file "${nginx_conf_path}" 2>/dev/null || true
    
    # Process nginx config template with envsubst to support flexible backend URLs
    log_info "Processing nginx config template with backend URLs from ${CONFIG_FILE}"
    if [[ "${STROMA_DRY_RUN}" == "0" ]]; then
        # Read backend URL variables from config and strip http:// prefix for nginx upstream
        export VLLM_INTERNAL_URL="$(grep -E '^VLLM_INTERNAL_URL=' "${CONFIG_FILE}" 2>/dev/null | cut -d= -f2- || echo 'http://127.0.0.1:8000')"
        export KC_INTERNAL_URL="$(grep -E '^KC_INTERNAL_URL=' "${CONFIG_FILE}" 2>/dev/null | cut -d= -f2- || echo 'http://127.0.0.1:8080')"
        export OPENWEBUI_INTERNAL_URL="$(grep -E '^OPENWEBUI_INTERNAL_URL=' "${CONFIG_FILE}" 2>/dev/null | cut -d= -f2- || echo 'http://127.0.0.1:3000')"
        
        # Strip http:// prefix for nginx upstream blocks (envsubst doesn't support parameter expansion)
        export VLLM_INTERNAL_URL="${VLLM_INTERNAL_URL#http://}"
        export KC_INTERNAL_URL="${KC_INTERNAL_URL#http://}"
        export OPENWEBUI_INTERNAL_URL="${OPENWEBUI_INTERNAL_URL#http://}"
        
        envsubst '${VLLM_INTERNAL_URL} ${KC_INTERNAL_URL} ${OPENWEBUI_INTERNAL_URL}' \
            < "${REPO_DIR}/deploy/nginx/stroma-ai.conf" \
            > "${nginx_conf_path}"
        
        log_ok "nginx config installed at ${nginx_conf_path}"
        log_info "  vLLM backend:     ${VLLM_INTERNAL_URL}"
        log_info "  Keycloak backend: ${KC_INTERNAL_URL}"
        log_info "  OpenWebUI backend: ${OPENWEBUI_INTERNAL_URL}"
    else
        log_dry "Would process nginx template and write to ${nginx_conf_path}"
    fi

    # Ubuntu: enable the site
    if [[ "${OS_FAMILY}" == "debian" ]]; then
        run_cmd ln -sf "${nginx_conf_path}" /etc/nginx/sites-enabled/stroma-ai
        # Disable default site if present (conflicts with port 80)
        if [[ -f /etc/nginx/sites-enabled/default ]]; then
            run_cmd rm -f /etc/nginx/sites-enabled/default
            log_info "Removed default nginx site."
        fi
    fi

    # RHEL: disable default server_name _ if nginx.conf has a default server block
    if [[ "${OS_FAMILY}" == "rhel" ]]; then
        if grep -q 'server_name  localhost' /etc/nginx/nginx.conf 2>/dev/null; then
            backup_file /etc/nginx/nginx.conf
            run_cmd sed -i \
                '/server {/{:l /server_name.*localhost/{ /}/d; N; bl }; /server_name.*localhost/d}' \
                /etc/nginx/nginx.conf 2>/dev/null || \
                log_warn "Could not remove default nginx server block — verify /etc/nginx/nginx.conf manually."
        fi
    fi

    # Validate nginx config
    if [[ "${STROMA_DRY_RUN}" == "0" ]]; then
        nginx -t && log_ok "nginx config syntax OK" \
            || log_warn "nginx -t failed — check ${nginx_conf_path} before starting nginx."
    fi
}

_generate_tls_cert() {
    log_step "TLS certificate"

    if [[ -f /etc/ssl/stroma-ai/server.crt && -f /etc/ssl/stroma-ai/server.key ]]; then
        log_ok "TLS certificate already exists at /etc/ssl/stroma-ai/ — skipping generation."
        return 0
    fi

    log_info "Generating self-signed TLS certificate for ${STROMA_HEAD_HOST}"
    log_warn "For production, replace with a CA-signed certificate."

    run_cmd mkdir -p /etc/ssl/stroma-ai
    run_cmd openssl req -x509 -nodes -days 3650 -newkey rsa:4096 \
        -keyout /etc/ssl/stroma-ai/server.key \
        -out    /etc/ssl/stroma-ai/server.crt \
        -subj "/CN=${STROMA_HEAD_HOST}" \
        -addext "subjectAltName=DNS:${STROMA_HEAD_HOST}"
    run_cmd chmod 600 /etc/ssl/stroma-ai/server.key
    run_cmd chmod 644 /etc/ssl/stroma-ai/server.crt
    run_cmd chown root:root /etc/ssl/stroma-ai/server.*

    log_ok "Self-signed TLS certificate generated (valid 10 years)."
}

_deploy_systemd_units() {
    log_step "Installing systemd service units"

    local units=(
        "deploy/systemd/ray-head.service:ray-head.service"
        "deploy/systemd/stroma-ai-vllm.service:stroma-ai-vllm.service"
        "deploy/systemd/stroma-ai-watcher.service:stroma-ai-watcher.service"
    )

    for entry in "${units[@]}"; do
        local src="${REPO_DIR}/${entry%%:*}"
        local dest="${STROMA_SYSTEMD_DIR}/${entry##*:}"
        backup_file "${dest}" 2>/dev/null || true
        run_cmd cp "${src}" "${dest}"
        log_ok "Installed ${dest}"
    done

    # Patch all deployed units: substitute the actual install dir and shared root.
    # systemd cannot expand shell variables in paths, so the installer does it.
    if [[ "${STROMA_DRY_RUN}" == "0" ]]; then
        for unit in ray-head stroma-ai-vllm stroma-ai-watcher; do
            local dest="${STROMA_SYSTEMD_DIR}/${unit}.service"
            [[ -f "${dest}" ]] || continue
            sed -i "s|/opt/stroma-ai|${STROMA_INSTALL_DIR}|g" "${dest}"
        done
        # Also patch ReadWritePaths shared-root placeholder in vllm unit
        local vllm_unit="${STROMA_SYSTEMD_DIR}/stroma-ai-vllm.service"
        if [[ -f "${vllm_unit}" ]]; then
            sed -i "s|ReadWritePaths=${STROMA_INSTALL_DIR} /tmp /share|ReadWritePaths=${STROMA_INSTALL_DIR} /tmp ${STROMA_SHARED_ROOT}|" \
                "${vllm_unit}"
        fi
        log_ok "Patched systemd units: install_dir=${STROMA_INSTALL_DIR}, shared_root=${STROMA_SHARED_ROOT}"
    else
        log_dry "Would patch systemd units: /opt/stroma-ai -> ${STROMA_INSTALL_DIR}, /share -> ${STROMA_SHARED_ROOT}"
    fi

    run_cmd systemctl daemon-reload
    log_ok "systemd units reloaded."
}

_enable_services() {
    log_step "Enabling and starting services"

    # nginx
    run_cmd systemctl enable nginx
    run_cmd systemctl restart nginx
    log_ok "nginx started."

    # StromaAI services (Ray → vLLM → Watcher, in dependency order)
    local services=(ray-head stroma-ai-vllm stroma-ai-watcher)
    for svc in "${services[@]}"; do
        run_cmd systemctl enable "${svc}"
    done

    # Ask before starting (vLLM takes 5+ minutes to load)
    if confirm "Start StromaAI services now? (Ray, vLLM, Watcher — model loading takes 3-10 minutes)"; then
        for svc in "${services[@]}"; do
            run_cmd systemctl start "${svc}"
            log_ok "Started ${svc}."
        done
    else
        log_info "Services are enabled but not started."
        log_info "Start manually: systemctl start ray-head stroma-ai-vllm stroma-ai-watcher"
    fi
}

_print_head_summary() {
    local api_url="https://${STROMA_HEAD_HOST}:${STROMA_HTTPS_PORT}"
    echo ""
    echo -e "${BOLD}╔══════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${BOLD}║   StromaAI Head Node Installation Complete                ║${RESET}"
    echo -e "${BOLD}╚══════════════════════════════════════════════════════════╝${RESET}"
    echo ""
    echo -e "  API endpoint:   ${CYAN}${api_url}/v1${RESET}"
    echo -e "  Health check:   ${CYAN}${api_url}/health${RESET}"
    echo -e "  Metrics:        ${CYAN}${api_url}/metrics${RESET} (internal only)"
    echo -e "  Config file:    ${STROMA_INSTALL_DIR}/config.env"
    echo -e "  API key:        ${YELLOW}${STROMA_API_KEY}${RESET}"
    echo ""
    echo -e "  Log commands:"
    echo -e "    journalctl -u ray-head -f"
    echo -e "    journalctl -u stroma-ai-vllm -f"
    echo -e "    journalctl -u stroma-ai-watcher -f"
    echo ""
    echo -e "  Next steps:"
    echo -e "    1. Run preflight on Slurm worker nodes:"
    echo -e "       sudo ./install/preflight.sh --mode=worker"
    echo -e "    2. Build the Apptainer container:"
    echo -e "       apptainer build ${STROMA_CONTAINER} deploy/containers/stroma-ai-vllm.def"
    echo -e "    3. Configure OOD integration:"
    echo -e "       sudo ./install/install.sh --mode=ood --config=${STROMA_INSTALL_DIR}/config.env"
    echo ""
}

# ---------------------------------------------------------------------------
# ── WORKER NODE INSTALLATION ────────────────────────────────────────────────
# ---------------------------------------------------------------------------
install_worker() {
    log_step "Configuring Slurm worker node on ${OS_PRETTY}"
    confirm "This will install Apptainer, NVIDIA Container Toolkit, and configure security settings. Continue?" \
        || die "Installation cancelled."

    # Check for environment modules BEFORE refreshing package metadata
    # If modules provide what we need, skip expensive dnf/apt operations
    local need_packages=0
    
    # Check if Apptainer/Singularity is available via modules
    if ! check_cmd apptainer && ! check_cmd singularity; then
        if command -v module &>/dev/null; then
            log_info "Container runtime not in PATH, checking environment modules..."
            if ! (module load apptainer 2>/dev/null || module load singularity 2>/dev/null); then
                need_packages=1
            fi
        else
            need_packages=1
        fi
    fi
    
    # Check if NVIDIA drivers are available via modules
    if ! check_cmd nvidia-smi; then
        if command -v module &>/dev/null; then
            log_info "nvidia-smi not in PATH, checking CUDA/NVIDIA modules..."
            if ! (module load cuda 2>/dev/null || module load nvidia 2>/dev/null || module load nvidia-driver 2>/dev/null); then
                need_packages=1
            fi
        else
            need_packages=1
        fi
    fi
    
    # Only refresh package metadata if we actually need to install packages
    if [[ "${need_packages}" -eq 1 ]]; then
        enable_epel
        pkg_update
        install_base_deps
        install_worker_build_deps
    else
        log_ok "Required software available via environment modules - skipping package installation"
    fi
    
    install_apptainer
    configure_apptainer
    verify_nvidia_gpu || log_warn "GPU verification failed — proceeding anyway."
    install_nvidia_container_toolkit
    configure_security worker
    configure_firewall worker

    _create_shared_log_dirs
    _print_worker_summary
}

_create_shared_log_dirs() {
    local log_dir="${STROMA_LOG_DIR:-/share/logs/stroma-ai}"
    if [[ -d "$(dirname "${log_dir}")" ]]; then
        run_cmd mkdir -p "${log_dir}"
        run_cmd chmod 2775 "${log_dir}"
        log_ok "Created Slurm log directory: ${log_dir}"
    else
        log_warn "Shared log path $(dirname "${log_dir}") not found — create ${log_dir} manually."
    fi
}

_print_worker_summary() {
    echo ""
    echo -e "${BOLD}╔══════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${BOLD}║   StromaAI Worker Node Configuration Complete             ║${RESET}"
    echo -e "${BOLD}╚══════════════════════════════════════════════════════════╝${RESET}"
    echo ""
    echo -e "  Container runtime: ${CONTAINER_RUNTIME:-apptainer}"
    echo -e "  SELinux status:    ${SELINUX_STATUS:-N/A}"
    echo ""
    echo -e "  Verify GPU access inside container:"
    echo -e "    ${CONTAINER_RUNTIME:-apptainer} exec --nv ${STROMA_CONTAINER} \\"
    echo -e "      python3 -c 'import torch; print(torch.cuda.is_available())'"
    echo ""
    echo -e "  Build the container (on an internet-connected machine):"
    echo -e "    apptainer build ${STROMA_CONTAINER} deploy/containers/stroma-ai-vllm.def"
    echo ""
    echo -e "  Next step: verify shared filesystem and Slurm account:"
    echo -e "    scontrol show partition ${STROMA_SLURM_PARTITION}"
    echo -e "    sacctmgr show account ${STROMA_SLURM_ACCOUNT}"
    echo ""
}

# ---------------------------------------------------------------------------
# ── OOD INTEGRATION INSTALLATION ────────────────────────────────────────────
# ---------------------------------------------------------------------------
install_ood() {
    log_step "Installing Open OnDemand integration on ${OS_PRETTY}"

    # OOD directory check
    if [[ ! -d /etc/ood ]]; then
        log_error "/etc/ood not found — is Open OnDemand installed on this node?"
        log_error "Install OOD first: https://osc.github.io/ood-documentation/"
        die "OOD not found."
    fi

    _deploy_ood_config
    _deploy_ood_app
    _print_ood_summary
}

_deploy_ood_config() {
    log_step "Deploying /etc/ood/stroma-ai.conf"

    if [[ "${STROMA_DRY_RUN}" == "0" ]]; then
        backup_file /etc/ood/stroma-ai.conf 2>/dev/null || true
        cat > /etc/ood/stroma-ai.conf <<EOF
# StromaAI OOD configuration — generated by install.sh on $(date)
# Sourced by deploy/ood/script.sh.erb at code-server session start.

STROMA_HEAD_HOST=${STROMA_HEAD_HOST}
STROMA_HTTPS_PORT=${STROMA_HTTPS_PORT}
STROMA_API_KEY=${STROMA_API_KEY}
STROMA_MODEL_NAME=${STROMA_MODEL_NAME}
EOF
        chmod 640 /etc/ood/stroma-ai.conf
        chown root:ood /etc/ood/stroma-ai.conf 2>/dev/null || \
            chown root:root /etc/ood/stroma-ai.conf
    fi
    log_ok "/etc/ood/stroma-ai.conf written."
}

_deploy_ood_app() {
    log_step "Deploying OOD application files"

    # Find OOD apps directory
    local ood_apps_dir
    for candidate in /var/www/ood/apps/sys /etc/ood/apps /opt/ood/apps; do
        if [[ -d "${candidate}" ]]; then
            ood_apps_dir="${candidate}"
            break
        fi
    done

    if [[ -z "${ood_apps_dir:-}" ]]; then
        log_warn "Could not find OOD apps directory. Checked:"
        log_warn "  /var/www/ood/apps/sys, /etc/ood/apps, /opt/ood/apps"
        log_warn "Deploy manually: copy deploy/ood/ contents to your OOD app directory."
        return 0
    fi

    local stroma_ai_app_dir="${ood_apps_dir}/stroma-ai-code"
    run_cmd mkdir -p "${stroma_ai_app_dir}/template"
    run_cmd cp "${REPO_DIR}/deploy/ood/stroma-ai.conf" "${stroma_ai_app_dir}/"
    run_cmd cp "${REPO_DIR}/deploy/ood/script.sh.erb" "${stroma_ai_app_dir}/template/"

    log_ok "OOD app files deployed to ${stroma_ai_app_dir}"
}

_print_ood_summary() {
    echo ""
    echo -e "${BOLD}╔══════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${BOLD}║   StromaAI OOD Integration Complete                       ║${RESET}"
    echo -e "${BOLD}╚══════════════════════════════════════════════════════════╝${RESET}"
    echo ""
    echo -e "  OOD config:  /etc/ood/stroma-ai.conf"
    echo ""
    echo -e "  Manual verification steps:"
    echo -e "  1. Start a code-server session via OOD"
    echo -e "  2. Open the terminal and run:"
    echo -e "     curl -sk https://${STROMA_HEAD_HOST}/health"
    echo -e "  3. Verify Kilo Code settings.json key names:"
    echo -e "     cat ~/.local/share/code-server/extensions/kilocode.kilo-code-*/package.json \\"
    echo -e "       | python3 -c \"import json,sys; d=json.load(sys.stdin); \\"
    echo -e "         [print(k) for k in d.get('contributes',{}).get('configuration',{}).get('properties',{})\""
    echo ""
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    load_or_prompt_config

    case "${MODE}" in
        head)   install_head ;;
        worker) install_worker ;;
        ood)    install_ood ;;
        *)      die "Unknown mode: ${MODE}. Use --mode=head|worker|ood" ;;
    esac
}

main "$@"
