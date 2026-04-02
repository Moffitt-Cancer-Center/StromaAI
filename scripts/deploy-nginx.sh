#!/usr/bin/env bash
# =============================================================================
# StromaAI — Deploy/Update nginx Configuration
# =============================================================================
# Regenerates nginx reverse proxy config from template using envsubst.
# Automatically handles:
#   • Backend URL variable loading from config.env
#   • http:// prefix stripping for nginx upstream blocks
#   • Missing SSL certificate generation (self-signed)
#   • OS-specific nginx config paths (RHEL/Rocky vs Ubuntu/Debian)
#   • Configuration validation before reload
#
# Usage:
#   scripts/deploy-nginx.sh [--repo-dir=/path/to/StromaAI]
#
# Environment overrides:
#   STROMA_CONFIG       path to config.env (default: /opt/stroma-ai/config.env)
#   STROMA_REPO_DIR     path to StromaAI git repo (default: auto-detect)
# =============================================================================

set -euo pipefail

# =============================================================================
# Configuration
# =============================================================================

CONFIG_FILE="${STROMA_CONFIG:-/opt/stroma-ai/config.env}"
REPO_DIR="${STROMA_REPO_DIR:-}"
SSL_CERT_DIR="/etc/ssl/stroma-ai"
SSL_CERT_PATH="${SSL_CERT_DIR}/server.crt"
SSL_KEY_PATH="${SSL_CERT_DIR}/server.key"

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

# =============================================================================
# Main Deployment Logic
# =============================================================================

main() {
    # Parse arguments
    while [[ $# -gt 0 ]]; do
        case "$1" in
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
    
    log_info "Using StromaAI repository: ${REPO_DIR}"
    
    # Verify template exists
    local template="${REPO_DIR}/deploy/nginx/stroma-ai.conf"
    if [[ ! -f "${template}" ]]; then
        log_fatal "nginx template not found: ${template}"
    fi
    
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
    else
        log_info "Config file not found, using defaults"
        export VLLM_INTERNAL_URL='http://127.0.0.1:8000'
        export KC_INTERNAL_URL='http://127.0.0.1:8080'
        export OPENWEBUI_INTERNAL_URL='http://127.0.0.1:3000'
    fi
    
    # Strip http:// prefix for nginx upstream blocks (envsubst doesn't support parameter expansion)
    export VLLM_INTERNAL_URL="${VLLM_INTERNAL_URL#http://}"
    export KC_INTERNAL_URL="${KC_INTERNAL_URL#http://}"
    export OPENWEBUI_INTERNAL_URL="${OPENWEBUI_INTERNAL_URL#http://}"
    
    log_info "Backend URLs:"
    log_info "  vLLM:     ${VLLM_INTERNAL_URL}"
    log_info "  Keycloak: ${KC_INTERNAL_URL}"
    log_info "  OpenWebUI: ${OPENWEBUI_INTERNAL_URL}"
    
    # Backup existing config if present
    if [[ -f "${nginx_conf_path}" ]]; then
        local backup="${nginx_conf_path}.backup.$(date +%Y%m%d-%H%M%S)"
        cp "${nginx_conf_path}" "${backup}"
        log_ok "Backed up existing config to ${backup}"
    fi
    
    # Process template with envsubst
    log_info "Generating nginx config from template"
    envsubst '${VLLM_INTERNAL_URL} ${KC_INTERNAL_URL} ${OPENWEBUI_INTERNAL_URL}' \
        < "${template}" \
        > "${nginx_conf_path}" || log_fatal "envsubst failed"
    
    log_ok "nginx config written to ${nginx_conf_path}"
    
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
    log_ok "nginx deployment complete"
    log_info "Access endpoints:"
    log_info "  Main API:       https://$(hostname)/v1/chat/completions"
    log_info "  OpenWebUI:      https://$(hostname)/webui"
    log_info "  Keycloak admin: https://$(hostname)/admin"
    log_info "  Health check:   https://$(hostname)/health"
}

# =============================================================================
# Entry Point
# =============================================================================

# Require root
if [[ $EUID -ne 0 ]]; then
    log_fatal "This script must be run as root"
fi

main "$@"
