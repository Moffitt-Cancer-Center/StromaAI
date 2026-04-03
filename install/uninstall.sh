#!/usr/bin/env bash
# =============================================================================
# StromaAI — Uninstaller
# =============================================================================
# Removes StromaAI from a head node. Does NOT remove system packages (nginx,
# Python, NVIDIA toolkit) since those may be used by other services.
#
# Usage:
#   sudo ./install/uninstall.sh [--yes]
#
# What is removed:
#   - systemd service units (ray-head, stroma-ai-vllm, stroma-ai-watcher)
#   - Install directory (default: /opt/stroma-ai/; source, venv, config, state)
#   - /etc/nginx/conf.d/stroma-ai.conf (RHEL/Rocky)
#     /etc/nginx/sites-{available,enabled}/stroma-ai (Ubuntu)
#   - /etc/ood/stroma-ai.conf
#   - /etc/ssl/stroma-ai/ (TLS keys)
#   - 'stromaai' system user
#
# What is NOT removed (intentionally):
#   - /share/containers/stroma-ai-vllm.sif  (your data, not ours)
#   - /share/models/                       (your data, not ours)
#   - ${STROMA_INSTALL_DIR}/logs/            (audit trail)
#   - nginx, Python 3.11, NVIDIA toolkit    (shared system packages)
# =============================================================================

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=install/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=install/lib/detect.sh
source "${SCRIPT_DIR}/lib/detect.sh"

require_root
detect_os

# ---------------------------------------------------------------------------
# Detect installation directory
# ---------------------------------------------------------------------------
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

_detect_install_dir() {
    # 1. Environment variable override
    if [[ -n "${STROMA_INSTALL_DIR:-}" ]]; then
        return 0
    fi
    
    # 2. Check if running from installed directory (repo used as install dir)
    if [[ -f "${REPO_DIR}/config.env" ]]; then
        STROMA_INSTALL_DIR="${REPO_DIR}"
        return 0
    fi
    
    # 3. Look for config.env in common installation locations
    local common_paths=(
        "/opt/stroma-ai"
        "/cm/shared/apps/stroma-ai"
        "/opt/apps/stroma-ai"
        "/usr/local/stroma-ai"
        "${HOME}/stroma-ai"
    )
    
    for path in "${common_paths[@]}"; do
        if [[ -f "${path}/config.env" ]]; then
            STROMA_INSTALL_DIR="${path}"
            return 0
        fi
    done
    
    # 4. Default to /opt/stroma-ai
    STROMA_INSTALL_DIR="/opt/stroma-ai"
}

_detect_install_dir

# Show what was detected
if [[ -d "${STROMA_INSTALL_DIR}" ]]; then
    log_info "Target installation: ${STROMA_INSTALL_DIR}"
else
    log_warn "Installation directory not found: ${STROMA_INSTALL_DIR}"
fi

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
for arg in "$@"; do
    case "${arg}" in
        --yes)    STROMA_YES=1 ;;
        --help|-h)
            echo "Usage: sudo $0 [--yes]"
            echo "Removes StromaAI from a head node. Use --yes to skip confirmation prompts."
            exit 0
            ;;
        *) log_warn "Unknown argument: ${arg}" ;;
    esac
done

export STROMA_YES="${STROMA_YES:-0}"

echo ""
echo -e "${BOLD}StromaAI Uninstaller${RESET}"
echo ""
log_warn "This will stop all StromaAI services and remove installation files."
log_warn "Model weights and container images are NOT affected."
echo ""

confirm "Proceed with uninstallation?" || { log_info "Aborted."; exit 0; }

# ---------------------------------------------------------------------------
# Stop and disable services
# ---------------------------------------------------------------------------
log_step "Stopping StromaAI services"
for svc in stroma-ai-watcher stroma-ai-vllm ray-head; do
    if systemctl is-active --quiet "${svc}" 2>/dev/null; then
        run_cmd systemctl stop "${svc}" && log_ok "Stopped ${svc}."
    fi
    if systemctl is-enabled --quiet "${svc}" 2>/dev/null; then
        run_cmd systemctl disable "${svc}" && log_ok "Disabled ${svc}."
    fi
done

# ---------------------------------------------------------------------------
# Remove systemd units
# ---------------------------------------------------------------------------
log_step "Removing systemd service units"
for unit in ray-head.service stroma-ai-vllm.service stroma-ai-watcher.service; do
    if [[ -f "/etc/systemd/system/${unit}" ]]; then
        run_cmd rm -f "/etc/systemd/system/${unit}"
        log_ok "Removed /etc/systemd/system/${unit}"
    fi
done
run_cmd systemctl daemon-reload

# ---------------------------------------------------------------------------
# Remove nginx config
# ---------------------------------------------------------------------------
log_step "Removing nginx configuration"
case "${OS_FAMILY}" in
    rhel)
        if [[ -f /etc/nginx/conf.d/stroma-ai.conf ]]; then
            run_cmd rm -f /etc/nginx/conf.d/stroma-ai.conf
            log_ok "Removed /etc/nginx/conf.d/stroma-ai.conf"
        fi
        ;;
    debian)
        run_cmd rm -f /etc/nginx/sites-enabled/stroma-ai 2>/dev/null || true
        run_cmd rm -f /etc/nginx/sites-available/stroma-ai 2>/dev/null || true
        log_ok "Removed nginx site config"
        ;;
esac

if check_cmd nginx; then
    run_cmd systemctl reload nginx 2>/dev/null || true
fi

# ---------------------------------------------------------------------------
# Remove TLS certificates
# ---------------------------------------------------------------------------
log_step "Removing TLS certificates"
if [[ -d /etc/ssl/stroma-ai ]]; then
    if confirm "Remove /etc/ssl/stroma-ai/ (TLS keys)?"; then
        run_cmd rm -rf /etc/ssl/stroma-ai
        log_ok "Removed /etc/ssl/stroma-ai/"
    fi
fi

# ---------------------------------------------------------------------------
# Remove OOD config
# ---------------------------------------------------------------------------
log_step "Removing OOD configuration"
if [[ -f /etc/ood/stroma-ai.conf ]]; then
    run_cmd rm -f /etc/ood/stroma-ai.conf
    log_ok "Removed /etc/ood/stroma-ai.conf"
fi

# ---------------------------------------------------------------------------
# Remove ${STROMA_INSTALL_DIR}
# ---------------------------------------------------------------------------
log_step "Removing ${STROMA_INSTALL_DIR}"
if [[ -d ${STROMA_INSTALL_DIR} ]]; then
    if confirm "Remove ${STROMA_INSTALL_DIR}/ (includes config.env with API key)?"; then
        run_cmd rm -rf "${STROMA_INSTALL_DIR}"
        log_ok "Removed ${STROMA_INSTALL_DIR}/"
    else
        log_info "Keeping ${STROMA_INSTALL_DIR}/ — remove manually when ready."
    fi
fi

# ---------------------------------------------------------------------------
# Remove stromaai system user
# ---------------------------------------------------------------------------
log_step "Removing stromaai system user"
if id stromaai &>/dev/null; then
    if confirm "Remove system user 'stromaai'?"; then
        run_cmd userdel stromaai
        log_ok "Removed user 'stromaai'."
    fi
fi

# ---------------------------------------------------------------------------
# Remove firewall rules (best-effort)
# ---------------------------------------------------------------------------
log_step "Removing firewall rules (if applicable)"
case "${OS_FAMILY}" in
    rhel)
        if check_cmd firewall-cmd && systemctl is-active --quiet firewalld 2>/dev/null; then
            firewall-cmd --permanent --remove-port="6380/tcp" 2>/dev/null || true
            firewall-cmd --permanent --remove-service=http 2>/dev/null || true
            firewall-cmd --permanent --remove-service=https 2>/dev/null || true
            firewall-cmd --reload 2>/dev/null || true
            log_ok "Firewall rules removed."
        fi
        ;;
    debian)
        if check_cmd ufw; then
            ufw delete allow 6380/tcp 2>/dev/null || true
            ufw delete allow 80/tcp 2>/dev/null || true
            ufw delete allow 443/tcp 2>/dev/null || true
            log_ok "ufw rules removed."
        fi
        ;;
esac

echo ""
echo -e "${BOLD}StromaAI uninstallation complete.${RESET}"
echo ""
echo "Remaining (not removed — your data):"
echo "  /share/containers/  — container images"
echo "  /share/models/      — model weights"
echo "  ${STROMA_INSTALL_DIR}/logs — audit logs"
echo ""
echo "System packages NOT removed: nginx, python3.11, nvidia-container-toolkit"
echo "Remove manually if no longer needed."
echo ""
