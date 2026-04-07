#!/usr/bin/env bash
# =============================================================================
# StromaAI — Deploy/Update nginx Configuration
# =============================================================================
# Deploys or updates nginx reverse proxy in either containerized or bare-metal mode.
#
# Modes:
#   container — nginx runs in Podman Compose stack (deploy/head/docker-compose.yml)
#               • Uses deploy/head/nginx.conf (hardcoded service names)
#               • Routes through OIDC gateway container
#               • Restarts nginx container to apply changes
#
#   host      — nginx runs as system service via systemd
#               • Uses deploy/nginx/stroma-ai.conf (template with envsubst)
#               • Routes to backend URLs from config.env
#               • Reloads system nginx to apply changes
#
# Both modes:
#   • Automatically generate self-signed SSL certs if missing
#   • Validate configuration before applying
#
# Usage:
#   scripts/deploy-nginx.sh [OPTIONS]
#
# Options:
#   --mode=container|host   Deployment mode (default: auto-detect)
#   --repo-dir=PATH         Path to StromaAI repository (default: auto-detect)
#   -h, --help              Show this help
#
# Environment overrides:
#   STROMA_CONFIG       path to config.env (default: /opt/stroma-ai/config.env)
#   STROMA_REPO_DIR     path to StromaAI git repo (default: auto-detect)
#   TLS_CERT_PATH       SSL cert directory (default: /etc/ssl/stroma-ai)
# =============================================================================

set -euo pipefail

# =============================================================================
# Configuration
# =============================================================================

# Resolve config file path:
#   1. STROMA_CONFIG env var
#   2. --config argument (parsed below, may override)
#   3. STROMA_INSTALL_DIR/config.env
#   4. Search well-known HPC / system paths
_resolve_config_file() {
    [[ -n "${CONFIG_FILE:-}" ]] && return 0
    local _paths=(
        "${STROMA_INSTALL_DIR:+${STROMA_INSTALL_DIR}/config.env}"
        "/cm/shared/apps/stroma-ai/config.env"
        "/opt/stroma-ai/config.env"
        "/opt/apps/stroma-ai/config.env"
        "/usr/local/stroma-ai/config.env"
        "${HOME}/stroma-ai/config.env"
    )
    local _p
    for _p in "${_paths[@]}"; do
        [[ -z "${_p}" ]] && continue
        if [[ -f "${_p}" ]]; then
            CONFIG_FILE="${_p}"
            return 0
        fi
    done
}

CONFIG_FILE="${STROMA_CONFIG:-}"
REPO_DIR="${STROMA_REPO_DIR:-}"
SSL_CERT_DIR="${TLS_CERT_PATH:-/etc/ssl/stroma-ai}"
SSL_CERT_PATH="${SSL_CERT_DIR}/server.crt"
SSL_KEY_PATH="${SSL_CERT_DIR}/server.key"
MODE=""  # container | host | auto-detect

# =============================================================================
# Helper Functions
# =============================================================================

log_info() {
    echo "[INFO] $*" >&2
}

log_ok() {
    echo "[OK] $*" >&2
}

log_error() {
    echo "[ERROR] $*" >&2
}

log_fatal() {
    log_error "$@"
    exit 1
}

detect_os_family() {
    if [[ -f /etc/redhat-release ]] || [[ -f /etc/rocky-release ]]; then
        echo "rhel"
    elif [[ -f /etc/debian_version ]]; then
        echo "debian"
    else
        log_fatal "Unsupported OS: cannot detect RHEL/Rocky or Debian/Ubuntu"
    fi
}

detect_repo_dir() {
    # Try to find StromaAI repo directory
    local candidates=(
        "/root/StromaAI"
        "/opt/StromaAI"
        "$(pwd)"
        "$(dirname "$(dirname "$(readlink -f "$0")")")"
    )
    
    for dir in "${candidates[@]}"; do
        if [[ -f "${dir}/deploy/nginx/stroma-ai.conf" ]]; then
            echo "${dir}"
            return 0
        fi
    done
    
    log_fatal "Cannot find StromaAI repository. Set STROMA_REPO_DIR or use --repo-dir=PATH"
}

generate_self_signed_cert() {
    local hostname="${1:-stroma-ai.cluster.local}"
    
    log_info "Generating self-signed SSL certificate for ${hostname}"
    
    mkdir -p "${SSL_CERT_DIR}"
    
    openssl req -x509 -nodes -days 3650 -newkey rsa:4096 \
        -keyout "${SSL_KEY_PATH}" \
        -out "${SSL_CERT_PATH}" \
        -subj "/CN=${hostname}" \
        -addext "subjectAltName=DNS:${hostname},DNS:localhost,IP:127.0.0.1" \
        2>/dev/null || log_fatal "Failed to generate SSL certificate"
    
    chmod 600 "${SSL_KEY_PATH}"
    chmod 644 "${SSL_CERT_PATH}"
    chown root:root "${SSL_CERT_PATH}" "${SSL_KEY_PATH}"
    
    log_ok "SSL certificate created at ${SSL_CERT_PATH}"
}

check_or_create_ssl_cert() {
    if [[ -f "${SSL_CERT_PATH}" ]] && [[ -f "${SSL_KEY_PATH}" ]]; then
        log_ok "SSL certificate exists: ${SSL_CERT_PATH}"
        return 0
    fi
    
    log_info "SSL certificate not found, generating self-signed certificate"
    
    # Try to read hostname from config
    local hostname="stroma-ai.cluster.local"
    if [[ -f "${CONFIG_FILE}" ]]; then
        hostname=$(grep -E '^STROMA_HEAD_HOST=' "${CONFIG_FILE}" 2>/dev/null | cut -d= -f2- || echo "stroma-ai.cluster.local")
    fi
    
    generate_self_signed_cert "${hostname}"
}

detect_nginx_mode() {
    # Check if nginx container is running from the head stack
    if command -v podman &>/dev/null; then
        if podman ps --format '{{.Names}}' 2>/dev/null | grep -q '^stroma-nginx$'; then
            echo "container"
            return 0
        fi
    fi
    
    # Check if system nginx service exists
    if systemctl list-unit-files nginx.service &>/dev/null; then
        echo "host"
        return 0
    fi
    
    # Default to host mode if neither detected (fresh install)
    echo "host"
}

deploy_container_mode() {
    log_info "Deploying nginx in container mode (Podman Compose stack)"
    
    local compose_file="${REPO_DIR}/deploy/head/docker-compose.yml"
    if [[ ! -f "${compose_file}" ]]; then
        log_fatal "docker-compose.yml not found: ${compose_file}"
    fi

    # Ensure SSL certs exist (container mounts from ${SSL_CERT_DIR})
    check_or_create_ssl_cert

    # Generate nginx.conf from template before restarting the container.
    # nginx.conf is not committed — it is produced by envsubst from
    # nginx.conf.template so that KC and OpenWebUI upstream addresses
    # (which live outside the Compose network) are injected at deploy time.
    local nginx_tmpl="${REPO_DIR}/deploy/head/nginx.conf.template"
    local nginx_out="${REPO_DIR}/deploy/head/nginx.conf"

    [[ -f "${nginx_tmpl}" ]] || log_fatal "nginx.conf.template not found: ${nginx_tmpl}"

    # Load upstream URLs from config
    if [[ -f "${CONFIG_FILE}" ]]; then
        export KC_INTERNAL_URL=$(grep -E '^KC_INTERNAL_URL=' "${CONFIG_FILE}" 2>/dev/null | cut -d= -f2- || echo 'http://127.0.0.1:8080')
        export OPENWEBUI_INTERNAL_URL=$(grep -E '^OPENWEBUI_INTERNAL_URL=' "${CONFIG_FILE}" 2>/dev/null | cut -d= -f2- || echo 'http://127.0.0.1:3000')
    else
        log_info "Config not found — using default upstream URLs"
        export KC_INTERNAL_URL='http://127.0.0.1:8080'
        export OPENWEBUI_INTERNAL_URL='http://127.0.0.1:3000'
    fi

    log_info "Generating nginx.conf from template"
    log_info "  Keycloak  → ${KC_INTERNAL_URL}"
    log_info "  OpenWebUI → ${OPENWEBUI_INTERNAL_URL}"
    envsubst '${KC_INTERNAL_URL} ${OPENWEBUI_INTERNAL_URL}' \
        < "${nginx_tmpl}" > "${nginx_out}" || log_fatal "envsubst failed"
    log_ok "nginx.conf generated at ${nginx_out}"

    # Check if compose stack is running
    if ! podman ps --format '{{.Names}}' 2>/dev/null | grep -q '^stroma-nginx$'; then
        log_error "nginx container not running. Start the full stack first:"
        log_error "  cd ${REPO_DIR}/deploy/head"
        log_error "  ./setup-head.sh"
        exit 1
    fi

    # Restart nginx container to pick up the new config
    log_info "Restarting nginx container"
    cd "${REPO_DIR}/deploy/head"

    # Detect compose command
    local compose_cmd
    if podman compose version &>/dev/null 2>&1; then
        compose_cmd="podman compose"
    elif command -v podman-compose &>/dev/null; then
        compose_cmd="podman-compose"
    else
        log_fatal "No Podman Compose found. Install: dnf install podman-compose"
    fi

    ${compose_cmd} restart nginx || log_fatal "Failed to restart nginx container"

    log_ok "nginx container restarted"
    echo ""
    log_ok "Container nginx deployment complete"
    log_info "Check logs: cd ${REPO_DIR}/deploy/head && ${compose_cmd} logs nginx"
}

deploy_host_mode() {
    log_info "Deploying nginx in host mode (systemd service)"
    
    local template="${REPO_DIR}/deploy/nginx/stroma-ai.conf"
    
    # Detect OS family for nginx config path
    local os_family
    os_family=$(detect_os_family)
    log_info "Detected OS family: ${os_family}"
    
    local nginx_conf_path
    case "${os_family}" in
        rhel)
            nginx_conf_path="/etc/nginx/conf.d/stroma-ai.conf"
            ;;
        debian)
            nginx_conf_path="/etc/nginx/sites-available/stroma-ai"
            ;;
    esac
    
    log_info "nginx config path: ${nginx_conf_path}"
    
    # Check/create SSL certificates
    check_or_create_ssl_cert
    
    # Load backend URL variables from config with defaults
    log_info "Loading backend URLs from ${CONFIG_FILE}"
    
    if [[ -f "${CONFIG_FILE}" ]]; then
        export VLLM_INTERNAL_URL=$(grep -E '^VLLM_INTERNAL_URL=' "${CONFIG_FILE}" 2>/dev/null | cut -d= -f2- || echo 'http://127.0.0.1:8000')
        export KC_INTERNAL_URL=$(grep -E '^KC_INTERNAL_URL=' "${CONFIG_FILE}" 2>/dev/null | cut -d= -f2- || echo 'http://127.0.0.1:8080')
        export OPENWEBUI_INTERNAL_URL=$(grep -E '^OPENWEBUI_INTERNAL_URL=' "${CONFIG_FILE}" 2>/dev/null | cut -d= -f2- || echo 'http://127.0.0.1:3000')
        _gw_port=$(grep -E '^GATEWAY_PORT=' "${CONFIG_FILE}" 2>/dev/null | cut -d= -f2- || echo '9000')
        export GATEWAY_INTERNAL_URL=$(grep -E '^GATEWAY_INTERNAL_URL=' "${CONFIG_FILE}" 2>/dev/null | cut -d= -f2- || echo "http://127.0.0.1:${_gw_port}")
    else
        log_info "Config file not found, using defaults"
        export VLLM_INTERNAL_URL='http://127.0.0.1:8000'
        export KC_INTERNAL_URL='http://127.0.0.1:8080'
        export OPENWEBUI_INTERNAL_URL='http://127.0.0.1:3000'
        export GATEWAY_INTERNAL_URL='http://127.0.0.1:9000'
    fi
    
    # Strip http:// prefix for nginx upstream blocks (envsubst doesn't support parameter expansion)
    export VLLM_INTERNAL_URL="${VLLM_INTERNAL_URL#http://}"
    export KC_INTERNAL_URL="${KC_INTERNAL_URL#http://}"
    export OPENWEBUI_INTERNAL_URL="${OPENWEBUI_INTERNAL_URL#http://}"
    export GATEWAY_INTERNAL_URL="${GATEWAY_INTERNAL_URL#http://}"
    
    log_info "Backend URLs:"
    log_info "  vLLM:     ${VLLM_INTERNAL_URL}"
    log_info "  Gateway:  ${GATEWAY_INTERNAL_URL}"
    log_info "  Keycloak: ${KC_INTERNAL_URL}"
    log_info "  OpenWebUI: ${OPENWEBUI_INTERNAL_URL}"
    
    # Backup existing config if present
    if [[ -f "${nginx_conf_path}" ]]; then
        local backup="${nginx_conf_path}.backup.$(date +%Y%m%d-%H%M%S)"
        cp "${nginx_conf_path}" "${backup}"
        log_ok "Backed up existing config to ${backup}"
        # Keep only the 3 most recent backups to avoid accumulation
        ls -t "${nginx_conf_path}".backup.* 2>/dev/null | tail -n +4 | xargs -r rm -f --
    fi
    
    # Process template with envsubst
    log_info "Generating nginx config from template"
    envsubst '${VLLM_INTERNAL_URL} ${GATEWAY_INTERNAL_URL} ${KC_INTERNAL_URL} ${OPENWEBUI_INTERNAL_URL}' \
        < "${template}" \
        > "${nginx_conf_path}" || log_fatal "envsubst failed"
    
    log_ok "nginx config written to ${nginx_conf_path}"
    
    # On RHEL/Rocky: ensure nginx can proxy to remote hosts.
    # If any upstream is non-localhost, httpd_can_network_connect must be on.
    # This is normally set by install.sh but may be missing if deploy-nginx.sh
    # is run independently or if the install predates the remote upstream config.
    if [[ "${os_family}" == "rhel" ]] && command -v setsebool &>/dev/null; then
        local _has_remote=0
        for _url in "${KC_INTERNAL_URL}" "${OPENWEBUI_INTERNAL_URL}" "${VLLM_INTERNAL_URL}" "${GATEWAY_INTERNAL_URL}"; do
            if [[ "${_url}" != 127.0.0.1* && "${_url}" != localhost* ]]; then
                _has_remote=1
                break
            fi
        done
        if [[ "${_has_remote}" -eq 1 ]]; then
            log_info "Remote upstreams detected — verifying SELinux httpd_can_network_connect"
            if setsebool -P httpd_can_network_connect 1 2>/dev/null && \
               setsebool -P httpd_can_network_relay 1 2>/dev/null; then
                log_ok "SELinux: httpd_can_network_connect and httpd_can_network_relay are on"
            else
                log_error "WARNING: Could not set SELinux booleans. nginx may time out proxying to remote upstreams."
                log_error "Run manually: sudo setsebool -P httpd_can_network_connect 1 httpd_can_network_relay 1"
            fi
        fi
    fi

    # On Ubuntu/Debian, ensure symlink exists
    if [[ "${os_family}" == "debian" ]]; then
        if [[ ! -L /etc/nginx/sites-enabled/stroma-ai ]]; then
            ln -sf "${nginx_conf_path}" /etc/nginx/sites-enabled/stroma-ai
            log_ok "Created symlink in sites-enabled"
        fi
        
        # Disable default site if present
        if [[ -L /etc/nginx/sites-enabled/default ]]; then
            rm -f /etc/nginx/sites-enabled/default
            log_info "Removed default site symlink"
        fi
    fi
    
    # Test nginx configuration
    log_info "Testing nginx configuration"
    if nginx -t 2>&1; then
        log_ok "nginx configuration valid"
    else
        log_fatal "nginx configuration test failed. Check syntax or restore from backup."
    fi
    
    # Start or reload nginx depending on current state
    if systemctl is-active --quiet nginx; then
        log_info "Reloading nginx"
        if systemctl reload nginx 2>&1; then
            log_ok "nginx reloaded successfully"
        else
            log_error "nginx reload failed. Try manual restart:"
            log_error "  systemctl restart nginx"
            exit 1
        fi
    else
        log_info "Starting nginx (service was not running)"
        if systemctl enable --now nginx 2>&1; then
            log_ok "nginx started and enabled"
        else
            log_fatal "Failed to start nginx. Check systemctl status nginx"
        fi
    fi
    
    echo ""
    log_ok "Host nginx deployment complete"
    log_info "Access endpoints:"
    log_info "  Main API:       https://$(hostname)/v1/chat/completions"
    log_info "  OpenWebUI:      https://$(hostname)/webui"
    log_info "  Keycloak:       https://$(hostname)/realms/stroma-ai"
}

# =============================================================================
# Main Deployment Logic
# =============================================================================

main() {
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --mode=*)
                MODE="${1#*=}"
                if [[ "${MODE}" != "container" && "${MODE}" != "host" ]]; then
                    log_fatal "Invalid mode: ${MODE}. Use --mode=container or --mode=host"
                fi
                shift
                ;;
            --repo-dir=*)
                REPO_DIR="${1#*=}"
                shift
                ;;
            --help|-h)
                grep '^#' "$0" | grep -v '#!/usr/bin/env' | sed 's/^# //' | sed 's/^#//'
                exit 0
                ;;
            *)
                log_fatal "Unknown option: $1"
                ;;
        esac
    done
    
    # Detect repository directory if not set
    if [[ -z "${REPO_DIR}" ]]; then
        REPO_DIR=$(detect_repo_dir)
    fi

    # Resolve CONFIG_FILE after arg parsing so explicit --config-like overrides take effect,
    # but REPO_DIR is now known so we can also search the repo root.
    if [[ -z "${CONFIG_FILE}" && -f "${REPO_DIR}/config.env" ]]; then
        CONFIG_FILE="${REPO_DIR}/config.env"
    fi
    _resolve_config_file
    [[ -n "${CONFIG_FILE}" ]] && log_info "Using config: ${CONFIG_FILE}"
    
    log_info "Using StromaAI repository: ${REPO_DIR}"
    
    # Auto-detect mode if not specified
    if [[ -z "${MODE}" ]]; then
        MODE=$(detect_nginx_mode)
        log_info "Auto-detected deployment mode: ${MODE}"
    else
        log_info "Deployment mode: ${MODE}"
    fi
    
    # Route to appropriate deployment function
    case "${MODE}" in
        container)
            deploy_container_mode
            ;;
        host)
            deploy_host_mode
            ;;
        *)
            log_fatal "Invalid mode: ${MODE}"
            ;;
    esac
}

# =============================================================================
# Entry Point
# =============================================================================

# Require root
if [[ $EUID -ne 0 ]]; then
    log_fatal "This script must be run as root"
fi

main "$@"
