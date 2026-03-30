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
export AI_FLUX_DRY_RUN=0
export AI_FLUX_YES=0

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
        --dry-run)    AI_FLUX_DRY_RUN=1 ;;
        --yes)        AI_FLUX_YES=1 ;;
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

if [[ "${AI_FLUX_DRY_RUN}" == "1" ]]; then
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
    elif [[ -f /opt/ai-flux/config.env ]]; then
        log_info "Existing config found at /opt/ai-flux/config.env — loading."
        source /opt/ai-flux/config.env
    else
        log_info "No config file found — running interactive setup."
        _interactive_config
    fi

    # Apply defaults for any unset values
    AI_FLUX_SHARED_ROOT="${AI_FLUX_SHARED_ROOT:-/share}"
    AI_FLUX_HEAD_HOST="${AI_FLUX_HEAD_HOST:-ai-flux.$(hostname -d 2>/dev/null || echo 'cluster.local')}"
    AI_FLUX_VLLM_PORT="${AI_FLUX_VLLM_PORT:-8000}"
    AI_FLUX_HTTPS_PORT="${AI_FLUX_HTTPS_PORT:-443}"
    AI_FLUX_RAY_PORT="${AI_FLUX_RAY_PORT:-6380}"
    AI_FLUX_RAY_DASHBOARD_PORT="${AI_FLUX_RAY_DASHBOARD_PORT:-8265}"
    AI_FLUX_MODEL_PATH="${AI_FLUX_MODEL_PATH:-${AI_FLUX_SHARED_ROOT}/models/Qwen2.5-Coder-32B-Instruct-AWQ}"
    AI_FLUX_MODEL_NAME="${AI_FLUX_MODEL_NAME:-ai-flux-coder}"
    AI_FLUX_CONTAINER="${AI_FLUX_CONTAINER:-${AI_FLUX_SHARED_ROOT}/containers/ai-flux-vllm.sif}"
    AI_FLUX_SLURM_PARTITION="${AI_FLUX_SLURM_PARTITION:-ai-flux-gpu}"
    AI_FLUX_SLURM_ACCOUNT="${AI_FLUX_SLURM_ACCOUNT:-ai-flux-service}"
    AI_FLUX_SLURM_SCRIPT="${AI_FLUX_SLURM_SCRIPT:-${AI_FLUX_SHARED_ROOT}/slurm/ai_flux_worker.slurm}"
    AI_FLUX_LOG_DIR="${AI_FLUX_LOG_DIR:-${AI_FLUX_SHARED_ROOT}/logs/ai-flux}"
    AI_FLUX_SLURM_WALLTIME="${AI_FLUX_SLURM_WALLTIME:-7-00:00:00}"
    AI_FLUX_MAX_BURST_WORKERS="${AI_FLUX_MAX_BURST_WORKERS:-5}"
    AI_FLUX_GPU_MEM_UTIL="${AI_FLUX_GPU_MEM_UTIL:-0.85}"
    AI_FLUX_CPU_OFFLOAD_GB="${AI_FLUX_CPU_OFFLOAD_GB:-200}"
    AI_FLUX_MAX_MODEL_LEN="${AI_FLUX_MAX_MODEL_LEN:-32768}"
    AI_FLUX_MAX_NUM_SEQS="${AI_FLUX_MAX_NUM_SEQS:-64}"
    AI_FLUX_VLLM_CPU_KV_THREADS="${AI_FLUX_VLLM_CPU_KV_THREADS:-32}"
    AI_FLUX_SCALE_UP_THRESHOLD="${AI_FLUX_SCALE_UP_THRESHOLD:-5}"
    AI_FLUX_SCALE_DOWN_IDLE_SECONDS="${AI_FLUX_SCALE_DOWN_IDLE_SECONDS:-300}"
    AI_FLUX_SCALE_UP_COOLDOWN="${AI_FLUX_SCALE_UP_COOLDOWN:-120}"
    AI_FLUX_STATE_FILE="${AI_FLUX_STATE_FILE:-/opt/ai-flux/state/watcher_state.json}"

    # Validate API key
    if [[ -z "${AI_FLUX_API_KEY:-}" || "${AI_FLUX_API_KEY}" == "CHANGEME"* ]]; then
        if [[ "${AI_FLUX_YES}" == "1" ]]; then
            log_info "Generating random API key..."
            AI_FLUX_API_KEY=$(openssl rand -hex 32)
        else
            echo -en "${BOLD}Enter AI_FLUX_API_KEY (or press Enter to generate one): ${RESET}"
            read -r input_key
            if [[ -z "${input_key}" ]]; then
                AI_FLUX_API_KEY=$(openssl rand -hex 32)
                log_info "Generated API key: ${AI_FLUX_API_KEY}"
                log_warn "SAVE this key — you will need it for OOD configuration."
            else
                AI_FLUX_API_KEY="${input_key}"
            fi
        fi
    fi

    export AI_FLUX_HEAD_HOST AI_FLUX_VLLM_PORT AI_FLUX_HTTPS_PORT AI_FLUX_RAY_PORT
    export AI_FLUX_RAY_DASHBOARD_PORT AI_FLUX_MODEL_PATH AI_FLUX_MODEL_NAME
    export AI_FLUX_CONTAINER AI_FLUX_SLURM_PARTITION AI_FLUX_SLURM_ACCOUNT
    export AI_FLUX_SLURM_SCRIPT AI_FLUX_SLURM_WALLTIME AI_FLUX_MAX_BURST_WORKERS
    export AI_FLUX_GPU_MEM_UTIL AI_FLUX_CPU_OFFLOAD_GB AI_FLUX_MAX_MODEL_LEN
    export AI_FLUX_MAX_NUM_SEQS AI_FLUX_VLLM_CPU_KV_THREADS AI_FLUX_SCALE_UP_THRESHOLD
    export AI_FLUX_SCALE_DOWN_IDLE_SECONDS AI_FLUX_SCALE_UP_COOLDOWN AI_FLUX_STATE_FILE
    export AI_FLUX_API_KEY AI_FLUX_SHARED_ROOT AI_FLUX_LOG_DIR

    log_ok "Configuration loaded."
}

_interactive_config() {
    cat <<EOF

This installer needs a few site-specific values to configure StromaAI.
Press Enter to accept the default shown in [brackets].

EOF
    local default_host="ai-flux.$(hostname -d 2>/dev/null || echo 'cluster.local')"

    echo -en "Shared filesystem root [/share]: "
    read -r input; AI_FLUX_SHARED_ROOT="${input:-/share}"

    echo -en "Head node hostname [${default_host}]: "
    read -r input; AI_FLUX_HEAD_HOST="${input:-${default_host}}"

    echo -en "Shared model weight path [${AI_FLUX_SHARED_ROOT}/models/Qwen2.5-Coder-32B-Instruct-AWQ]: "
    read -r input; AI_FLUX_MODEL_PATH="${input:-${AI_FLUX_SHARED_ROOT}/models/Qwen2.5-Coder-32B-Instruct-AWQ}"

    echo -en "Shared container SIF path [${AI_FLUX_SHARED_ROOT}/containers/ai-flux-vllm.sif]: "
    read -r input; AI_FLUX_CONTAINER="${input:-${AI_FLUX_SHARED_ROOT}/containers/ai-flux-vllm.sif}"

    echo -en "Slurm GPU partition [ai-flux-gpu]: "
    read -r input; AI_FLUX_SLURM_PARTITION="${input:-ai-flux-gpu}"

    echo -en "Slurm account [ai-flux-service]: "
    read -r input; AI_FLUX_SLURM_ACCOUNT="${input:-ai-flux-service}"

    echo -en "Max concurrent burst workers [5]: "
    read -r input; AI_FLUX_MAX_BURST_WORKERS="${input:-5}"

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
    log_step "Creating aiflux system user"
    if id aiflux &>/dev/null; then
        log_info "User 'aiflux' already exists."
        return 0
    fi
    run_cmd useradd \
        --system \
        --no-create-home \
        --home-dir /opt/ai-flux \
        --shell /sbin/nologin \
        --comment "StromaAI service account" \
        aiflux
    log_ok "User 'aiflux' created."
}

_create_directories() {
    log_step "Creating directory structure"
    local dirs=(
        /opt/ai-flux
        /opt/ai-flux/src
        /opt/ai-flux/state
        /etc/ssl/ai-flux
        "${AI_FLUX_LOG_DIR}"
    )
    for dir in "${dirs[@]}"; do
        run_cmd mkdir -p "${dir}"
    done
    run_cmd chown -R aiflux:aiflux /opt/ai-flux
    run_cmd chmod 750 /opt/ai-flux
    run_cmd chown aiflux:aiflux "${AI_FLUX_LOG_DIR}" 2>/dev/null || true
    log_ok "Directories created."
}

_install_head_packages() {
    log_step "Installing system packages"
    pkg_update
    install_base_deps
    install_python311
    install_nginx

    # Install Python venv into /opt/ai-flux/venv
    install_head_python_deps
}

_deploy_config_env() {
    log_step "Writing /opt/ai-flux/config.env"
    if [[ -f /opt/ai-flux/config.env && "${AI_FLUX_YES}" != "1" ]]; then
        backup_file /opt/ai-flux/config.env
        if ! confirm "/opt/ai-flux/config.env already exists. Overwrite?"; then
            log_info "Keeping existing config.env."
            return 0
        fi
    fi

    if [[ "${AI_FLUX_DRY_RUN}" == "0" ]]; then
        cat > /opt/ai-flux/config.env <<EOF
# StromaAI configuration — generated by install.sh on $(date)
# Do NOT commit this file. Contains secrets.

AI_FLUX_SHARED_ROOT=${AI_FLUX_SHARED_ROOT}

AI_FLUX_HEAD_HOST=${AI_FLUX_HEAD_HOST}
AI_FLUX_VLLM_PORT=${AI_FLUX_VLLM_PORT}
AI_FLUX_HTTPS_PORT=${AI_FLUX_HTTPS_PORT}
AI_FLUX_RAY_PORT=${AI_FLUX_RAY_PORT}
AI_FLUX_RAY_DASHBOARD_PORT=${AI_FLUX_RAY_DASHBOARD_PORT}
AI_FLUX_API_KEY=${AI_FLUX_API_KEY}

AI_FLUX_MODEL_PATH=${AI_FLUX_MODEL_PATH}
AI_FLUX_MODEL_NAME=${AI_FLUX_MODEL_NAME}
AI_FLUX_CONTAINER=${AI_FLUX_CONTAINER}

AI_FLUX_SLURM_PARTITION=${AI_FLUX_SLURM_PARTITION}
AI_FLUX_SLURM_ACCOUNT=${AI_FLUX_SLURM_ACCOUNT}
AI_FLUX_SLURM_SCRIPT=${AI_FLUX_SLURM_SCRIPT}
AI_FLUX_SLURM_WALLTIME=${AI_FLUX_SLURM_WALLTIME}
AI_FLUX_MAX_BURST_WORKERS=${AI_FLUX_MAX_BURST_WORKERS}
AI_FLUX_WARM_RESERVATION=ai-flux-warm
AI_FLUX_LOG_DIR=${AI_FLUX_LOG_DIR}

AI_FLUX_GPU_MEM_UTIL=${AI_FLUX_GPU_MEM_UTIL}
AI_FLUX_CPU_OFFLOAD_GB=${AI_FLUX_CPU_OFFLOAD_GB}
AI_FLUX_MAX_MODEL_LEN=${AI_FLUX_MAX_MODEL_LEN}
AI_FLUX_MAX_NUM_SEQS=${AI_FLUX_MAX_NUM_SEQS}
AI_FLUX_VLLM_CPU_KV_THREADS=${AI_FLUX_VLLM_CPU_KV_THREADS}

AI_FLUX_SCALE_UP_THRESHOLD=${AI_FLUX_SCALE_UP_THRESHOLD}
AI_FLUX_SCALE_DOWN_IDLE_SECONDS=${AI_FLUX_SCALE_DOWN_IDLE_SECONDS}
AI_FLUX_SCALE_UP_COOLDOWN=${AI_FLUX_SCALE_UP_COOLDOWN}
AI_FLUX_STATE_FILE=${AI_FLUX_STATE_FILE}
EOF
        chown aiflux:aiflux /opt/ai-flux/config.env
        chmod 640 /opt/ai-flux/config.env
    else
        log_dry "Would write /opt/ai-flux/config.env with site values"
    fi
    log_ok "config.env written."
}

_deploy_source_files() {
    log_step "Deploying StromaAI source files to /opt/ai-flux"

    # Copy watcher
    run_cmd cp "${REPO_DIR}/src/vllm_watcher.py" /opt/ai-flux/src/vllm_watcher.py
    run_cmd chown aiflux:aiflux /opt/ai-flux/src/vllm_watcher.py
    run_cmd chmod 750 /opt/ai-flux/src/vllm_watcher.py

    # Copy shared Slurm script to shared filesystem (if mounted)
    local slurm_script_dir
    slurm_script_dir="$(dirname "${AI_FLUX_SLURM_SCRIPT}")"
    if [[ -d "${slurm_script_dir}" ]]; then
        run_cmd cp "${REPO_DIR}/deploy/slurm/ai_flux_worker.slurm" "${AI_FLUX_SLURM_SCRIPT}"
        run_cmd chmod 755 "${AI_FLUX_SLURM_SCRIPT}"
        log_ok "Slurm script deployed to ${AI_FLUX_SLURM_SCRIPT}"
    else
        log_warn "Slurm script directory ${slurm_script_dir} not found — copy manually:"
        log_warn "  cp deploy/slurm/ai_flux_worker.slurm ${AI_FLUX_SLURM_SCRIPT}"
    fi
}

_deploy_nginx() {
    log_step "Configuring nginx"

    # Distro-specific nginx config path
    local nginx_conf_path
    case "${OS_FAMILY}" in
        rhel)
            # RHEL/Rocky: drop file in conf.d (nginx reads all *.conf there)
            nginx_conf_path="/etc/nginx/conf.d/ai-flux.conf"
            ;;
        debian)
            # Ubuntu: use sites-available + symlink
            nginx_conf_path="/etc/nginx/sites-available/ai-flux"
            ;;
    esac

    backup_file "${nginx_conf_path}" 2>/dev/null || true
    run_cmd cp "${REPO_DIR}/deploy/nginx/ai-flux.conf" "${nginx_conf_path}"
    log_ok "nginx config installed at ${nginx_conf_path}"

    # Ubuntu: enable the site
    if [[ "${OS_FAMILY}" == "debian" ]]; then
        run_cmd ln -sf "${nginx_conf_path}" /etc/nginx/sites-enabled/ai-flux
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
    if [[ "${AI_FLUX_DRY_RUN}" == "0" ]]; then
        nginx -t && log_ok "nginx config syntax OK" \
            || log_warn "nginx -t failed — check ${nginx_conf_path} before starting nginx."
    fi
}

_generate_tls_cert() {
    log_step "TLS certificate"

    if [[ -f /etc/ssl/ai-flux/server.crt && -f /etc/ssl/ai-flux/server.key ]]; then
        log_ok "TLS certificate already exists at /etc/ssl/ai-flux/ — skipping generation."
        return 0
    fi

    log_info "Generating self-signed TLS certificate for ${AI_FLUX_HEAD_HOST}"
    log_warn "For production, replace with a CA-signed certificate."

    run_cmd mkdir -p /etc/ssl/ai-flux
    run_cmd openssl req -x509 -nodes -days 3650 -newkey rsa:4096 \
        -keyout /etc/ssl/ai-flux/server.key \
        -out    /etc/ssl/ai-flux/server.crt \
        -subj "/CN=${AI_FLUX_HEAD_HOST}" \
        -addext "subjectAltName=DNS:${AI_FLUX_HEAD_HOST}"
    run_cmd chmod 600 /etc/ssl/ai-flux/server.key
    run_cmd chmod 644 /etc/ssl/ai-flux/server.crt
    run_cmd chown root:root /etc/ssl/ai-flux/server.*

    log_ok "Self-signed TLS certificate generated (valid 10 years)."
}

_deploy_systemd_units() {
    log_step "Installing systemd service units"

    local units=(
        "deploy/systemd/ray-head.service:ray-head.service"
        "deploy/systemd/ai-flux-vllm.service:ai-flux-vllm.service"
        "deploy/systemd/ai-flux-watcher.service:ai-flux-watcher.service"
    )

    for entry in "${units[@]}"; do
        local src="${REPO_DIR}/${entry%%:*}"
        local dest="${AI_FLUX_SYSTEMD_DIR}/${entry##*:}"
        backup_file "${dest}" 2>/dev/null || true
        run_cmd cp "${src}" "${dest}"
        log_ok "Installed ${dest}"
    done

    # Patch ReadWritePaths in ai-flux-vllm.service to use the actual shared
    # storage root. systemd cannot expand shell variables in ReadWritePaths,
    # so the installer substitutes the configured path at deploy time.
    local vllm_unit="${AI_FLUX_SYSTEMD_DIR}/ai-flux-vllm.service"
    if [[ "${AI_FLUX_DRY_RUN}" == "0" && -f "${vllm_unit}" ]]; then
        sed -i "s|ReadWritePaths=/opt/ai-flux /tmp /share|ReadWritePaths=/opt/ai-flux /tmp ${AI_FLUX_SHARED_ROOT}|" \
            "${vllm_unit}"
        log_ok "Patched ReadWritePaths in ai-flux-vllm.service to use ${AI_FLUX_SHARED_ROOT}"
    elif [[ "${AI_FLUX_DRY_RUN}" != "0" ]]; then
        log_dry "Would patch ReadWritePaths in ai-flux-vllm.service: /share -> ${AI_FLUX_SHARED_ROOT}"
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
    local services=(ray-head ai-flux-vllm ai-flux-watcher)
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
        log_info "Start manually: systemctl start ray-head ai-flux-vllm ai-flux-watcher"
    fi
}

_print_head_summary() {
    local api_url="https://${AI_FLUX_HEAD_HOST}:${AI_FLUX_HTTPS_PORT}"
    echo ""
    echo -e "${BOLD}╔══════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${BOLD}║   StromaAI Head Node Installation Complete                ║${RESET}"
    echo -e "${BOLD}╚══════════════════════════════════════════════════════════╝${RESET}"
    echo ""
    echo -e "  API endpoint:   ${CYAN}${api_url}/v1${RESET}"
    echo -e "  Health check:   ${CYAN}${api_url}/health${RESET}"
    echo -e "  Metrics:        ${CYAN}${api_url}/metrics${RESET} (internal only)"
    echo -e "  Config file:    /opt/ai-flux/config.env"
    echo -e "  API key:        ${YELLOW}${AI_FLUX_API_KEY}${RESET}"
    echo ""
    echo -e "  Log commands:"
    echo -e "    journalctl -u ray-head -f"
    echo -e "    journalctl -u ai-flux-vllm -f"
    echo -e "    journalctl -u ai-flux-watcher -f"
    echo ""
    echo -e "  Next steps:"
    echo -e "    1. Run preflight on Slurm worker nodes:"
    echo -e "       sudo ./install/preflight.sh --mode=worker"
    echo -e "    2. Build the Apptainer container:"
    echo -e "       apptainer build ${AI_FLUX_CONTAINER} deploy/containers/ai-flux-vllm.def"
    echo -e "    3. Configure OOD integration:"
    echo -e "       sudo ./install/install.sh --mode=ood --config=/opt/ai-flux/config.env"
    echo ""
}

# ---------------------------------------------------------------------------
# ── WORKER NODE INSTALLATION ────────────────────────────────────────────────
# ---------------------------------------------------------------------------
install_worker() {
    log_step "Configuring Slurm worker node on ${OS_PRETTY}"
    confirm "This will install Apptainer, NVIDIA Container Toolkit, and configure security settings. Continue?" \
        || die "Installation cancelled."

    pkg_update
    install_base_deps
    install_worker_build_deps
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
    local log_dir="${AI_FLUX_LOG_DIR:-/share/logs/ai-flux}"
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
    echo -e "    ${CONTAINER_RUNTIME:-apptainer} exec --nv ${AI_FLUX_CONTAINER} \\"
    echo -e "      python3 -c 'import torch; print(torch.cuda.is_available())'"
    echo ""
    echo -e "  Build the container (on an internet-connected machine):"
    echo -e "    apptainer build ${AI_FLUX_CONTAINER} deploy/containers/ai-flux-vllm.def"
    echo ""
    echo -e "  Next step: verify shared filesystem and Slurm account:"
    echo -e "    scontrol show partition ${AI_FLUX_SLURM_PARTITION}"
    echo -e "    sacctmgr show account ${AI_FLUX_SLURM_ACCOUNT}"
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
    log_step "Deploying /etc/ood/ai-flux.conf"

    if [[ "${AI_FLUX_DRY_RUN}" == "0" ]]; then
        backup_file /etc/ood/ai-flux.conf 2>/dev/null || true
        cat > /etc/ood/ai-flux.conf <<EOF
# StromaAI OOD configuration — generated by install.sh on $(date)
# Sourced by deploy/ood/script.sh.erb at code-server session start.

AI_FLUX_HEAD_HOST=${AI_FLUX_HEAD_HOST}
AI_FLUX_HTTPS_PORT=${AI_FLUX_HTTPS_PORT}
AI_FLUX_API_KEY=${AI_FLUX_API_KEY}
AI_FLUX_MODEL_NAME=${AI_FLUX_MODEL_NAME}
EOF
        chmod 640 /etc/ood/ai-flux.conf
        chown root:ood /etc/ood/ai-flux.conf 2>/dev/null || \
            chown root:root /etc/ood/ai-flux.conf
    fi
    log_ok "/etc/ood/ai-flux.conf written."
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

    local ai_flux_app_dir="${ood_apps_dir}/ai-flux-code"
    run_cmd mkdir -p "${ai_flux_app_dir}/template"
    run_cmd cp "${REPO_DIR}/deploy/ood/ai-flux.conf" "${ai_flux_app_dir}/"
    run_cmd cp "${REPO_DIR}/deploy/ood/script.sh.erb" "${ai_flux_app_dir}/template/"

    log_ok "OOD app files deployed to ${ai_flux_app_dir}"
}

_print_ood_summary() {
    echo ""
    echo -e "${BOLD}╔══════════════════════════════════════════════════════════╗${RESET}"
    echo -e "${BOLD}║   StromaAI OOD Integration Complete                       ║${RESET}"
    echo -e "${BOLD}╚══════════════════════════════════════════════════════════╝${RESET}"
    echo ""
    echo -e "  OOD config:  /etc/ood/ai-flux.conf"
    echo ""
    echo -e "  Manual verification steps:"
    echo -e "  1. Start a code-server session via OOD"
    echo -e "  2. Open the terminal and run:"
    echo -e "     curl -sk https://${AI_FLUX_HEAD_HOST}/health"
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
