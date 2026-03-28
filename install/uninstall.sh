#!/usr/bin/env bash
# =============================================================================
# AI_Flux — Uninstaller
# =============================================================================
# Removes AI_Flux from a head node. Does NOT remove system packages (nginx,
# Python, NVIDIA toolkit) since those may be used by other services.
#
# Usage:
#   sudo ./install/uninstall.sh [--yes]
#
# What is removed:
#   - systemd service units (ray-head, ai-flux-vllm, ai-flux-watcher)
#   - /opt/ai-flux/ directory (source, venv, config, state)
#   - /etc/nginx/conf.d/ai-flux.conf (RHEL/Rocky)
#     /etc/nginx/sites-{available,enabled}/ai-flux (Ubuntu)
#   - /etc/ood/ai-flux.conf
#   - /etc/ssl/ai-flux/ (TLS keys)
#   - 'aiflux' system user
#
# What is NOT removed (intentionally):
#   - /shared/containers/ai-flux-vllm.sif  (your data, not ours)
#   - /shared/models/                       (your data, not ours)
#   - /shared/logs/ai-flux/                 (audit trail)
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

for arg in "$@"; do
    case "${arg}" in
        --yes)    AI_FLUX_YES=1 ;;
        --help|-h)
            echo "Usage: sudo $0 [--yes]"
            echo "Removes AI_Flux from a head node. Use --yes to skip confirmation prompts."
            exit 0
            ;;
        *) log_warn "Unknown argument: ${arg}" ;;
    esac
done

export AI_FLUX_YES="${AI_FLUX_YES:-0}"

echo ""
echo -e "${BOLD}AI_Flux Uninstaller${RESET}"
echo ""
log_warn "This will stop all AI_Flux services and remove installation files."
log_warn "Model weights and container images are NOT affected."
echo ""

confirm "Proceed with uninstallation?" || { log_info "Aborted."; exit 0; }

# ---------------------------------------------------------------------------
# Stop and disable services
# ---------------------------------------------------------------------------
log_step "Stopping AI_Flux services"
for svc in ai-flux-watcher ai-flux-vllm ray-head; do
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
for unit in ray-head.service ai-flux-vllm.service ai-flux-watcher.service; do
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
        if [[ -f /etc/nginx/conf.d/ai-flux.conf ]]; then
            run_cmd rm -f /etc/nginx/conf.d/ai-flux.conf
            log_ok "Removed /etc/nginx/conf.d/ai-flux.conf"
        fi
        ;;
    debian)
        run_cmd rm -f /etc/nginx/sites-enabled/ai-flux 2>/dev/null || true
        run_cmd rm -f /etc/nginx/sites-available/ai-flux 2>/dev/null || true
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
if [[ -d /etc/ssl/ai-flux ]]; then
    if confirm "Remove /etc/ssl/ai-flux/ (TLS keys)?"; then
        run_cmd rm -rf /etc/ssl/ai-flux
        log_ok "Removed /etc/ssl/ai-flux/"
    fi
fi

# ---------------------------------------------------------------------------
# Remove OOD config
# ---------------------------------------------------------------------------
log_step "Removing OOD configuration"
if [[ -f /etc/ood/ai-flux.conf ]]; then
    run_cmd rm -f /etc/ood/ai-flux.conf
    log_ok "Removed /etc/ood/ai-flux.conf"
fi

# ---------------------------------------------------------------------------
# Remove /opt/ai-flux
# ---------------------------------------------------------------------------
log_step "Removing /opt/ai-flux"
if [[ -d /opt/ai-flux ]]; then
    if confirm "Remove /opt/ai-flux/ (includes config.env with API key)?"; then
        run_cmd rm -rf /opt/ai-flux
        log_ok "Removed /opt/ai-flux/"
    else
        log_info "Keeping /opt/ai-flux/ — remove manually when ready."
    fi
fi

# ---------------------------------------------------------------------------
# Remove aiflux system user
# ---------------------------------------------------------------------------
log_step "Removing aiflux system user"
if id aiflux &>/dev/null; then
    if confirm "Remove system user 'aiflux'?"; then
        run_cmd userdel aiflux
        log_ok "Removed user 'aiflux'."
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
echo -e "${BOLD}AI_Flux uninstallation complete.${RESET}"
echo ""
echo "Remaining (not removed — your data):"
echo "  /shared/containers/  — container images"
echo "  /shared/models/      — model weights"
echo "  /shared/logs/ai-flux — audit logs"
echo ""
echo "System packages NOT removed: nginx, python3.11, nvidia-container-toolkit"
echo "Remove manually if no longer needed."
echo ""
