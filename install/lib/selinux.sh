#!/usr/bin/env bash
# =============================================================================
# AI_Flux — SELinux / AppArmor / Firewall configuration
# =============================================================================
# Provides: configure_selinux(), configure_apparmor(), configure_firewall()
# Supports: RHEL 8, Rocky Linux 9 (SELinux + firewalld)
#           Ubuntu 22.04 (AppArmor + ufw)
# =============================================================================

[[ -n "${_AI_FLUX_SELINUX_LOADED:-}" ]] && return 0
readonly _AI_FLUX_SELINUX_LOADED=1

# ---------------------------------------------------------------------------
# configure_security — dispatch to SELinux or AppArmor based on OS
# ---------------------------------------------------------------------------
configure_security() {
    case "${OS_FAMILY}" in
        rhel)   configure_selinux ;;
        debian) configure_apparmor ;;
    esac
}

# ---------------------------------------------------------------------------
# configure_selinux — set required booleans for container + systemd workloads
#
# Required booleans:
#   container_use_cgroups   — Apptainer jobs can manage cgroups
#   container_manage_cgroup — containers can write /sys/fs/cgroup
#   httpd_can_network_connect — nginx → vLLM reverse proxy
# ---------------------------------------------------------------------------
configure_selinux() {
    log_step "Configuring SELinux booleans for AI_Flux"

    if ! check_cmd getenforce; then
        log_info "getenforce not found — SELinux not installed, skipping."
        return 0
    fi

    local status
    status=$(getenforce 2>/dev/null)
    log_info "SELinux mode: ${status}"

    if [[ "${status}" == "Disabled" ]]; then
        log_info "SELinux is Disabled — nothing to configure."
        return 0
    fi

    # Ensure policycoreutils-python-utils is available for semanage
    if ! check_cmd setsebool; then
        pkg_install policycoreutils
    fi

    # Booleans required by worker nodes (Apptainer + cgroups)
    local worker_booleans=(
        container_use_cgroups
        container_manage_cgroup
    )

    # Booleans required by head node (nginx proxy)
    local head_booleans=(
        httpd_can_network_connect
        httpd_can_network_relay
    )

    local mode="${1:-head}"  # "head" or "worker"

    local booleans=()
    if [[ "${mode}" == "worker" ]]; then
        booleans=("${worker_booleans[@]}")
    elif [[ "${mode}" == "head" ]]; then
        booleans=("${head_booleans[@]}")
    else
        booleans=("${worker_booleans[@]}" "${head_booleans[@]}")
    fi

    for bool in "${booleans[@]}"; do
        log_info "Setting SELinux boolean: ${bool}=on (persistent)"
        run_cmd setsebool -P "${bool}" 1 || \
            log_warn "Failed to set SELinux boolean '${bool}' — may not exist on this version."
    done

    # If nginx is being installed, set correct file context on log directory
    if [[ "${mode}" == "head" ]] && check_cmd semanage 2>/dev/null; then
        # Allow nginx to read ssl certs in /etc/ssl/ai-flux
        run_cmd semanage fcontext -a -t cert_t "/etc/ssl/ai-flux(/.*)?" 2>/dev/null || true
        run_cmd restorecon -Rv /etc/ssl/ai-flux 2>/dev/null || true
    fi

    log_ok "SELinux booleans configured."
}

# ---------------------------------------------------------------------------
# configure_apparmor — ensure AppArmor does not block Apptainer on Ubuntu
# ---------------------------------------------------------------------------
configure_apparmor() {
    log_step "Checking AppArmor configuration"

    if ! check_cmd aa-status; then
        log_info "AppArmor not found — skipping."
        return 0
    fi

    # Ubuntu 22.04+ ships an AppArmor profile for unprivileged userns clone
    # that can block Apptainer's user namespace operations.
    # The correct fix is to ensure the kernel allows unprivileged user namespaces.
    local sysctl_val
    sysctl_val=$(sysctl -n kernel.unprivileged_userns_clone 2>/dev/null || echo "1")
    if [[ "${sysctl_val}" == "0" ]]; then
        log_warn "kernel.unprivileged_userns_clone=0 — Apptainer rootless mode will fail."
        log_info "Setting kernel.unprivileged_userns_clone=1 (persistent)"
        run_cmd sysctl -w kernel.unprivileged_userns_clone=1
        if [[ "${AI_FLUX_DRY_RUN:-0}" == "0" ]]; then
            echo "kernel.unprivileged_userns_clone=1" \
                >> /etc/sysctl.d/99-ai-flux.conf
        fi
    else
        log_ok "kernel.unprivileged_userns_clone is enabled."
    fi

    # Check if Apptainer has its own AppArmor profile
    if aa-status 2>/dev/null | grep -q "apptainer"; then
        log_info "AppArmor profile for Apptainer is loaded — no changes needed."
    fi

    log_ok "AppArmor configuration complete."
}

# ---------------------------------------------------------------------------
# configure_firewall — open required ports
#
# Ports:
#   443  — nginx HTTPS (user-facing API)
#   80   — nginx HTTP (redirects to HTTPS)
#   6380 — Ray GCS (AI_FLUX_RAY_PORT; Slurm workers connect inbound)
#   8265 — Ray dashboard (bind to localhost; not opened externally)
# ---------------------------------------------------------------------------
configure_firewall() {
    local mode="${1:-head}"  # "head" or "worker"
    log_step "Configuring firewall (mode: ${mode})"

    case "${OS_FAMILY}" in
        rhel)   _configure_firewalld "${mode}" ;;
        debian) _configure_ufw "${mode}" ;;
    esac
}

# ---------------------------------------------------------------------------
# _configure_firewalld — for RHEL 8 / Rocky 9
# ---------------------------------------------------------------------------
_configure_firewalld() {
    local mode="$1"

    if ! check_cmd firewall-cmd; then
        log_warn "firewalld not found — skipping firewall configuration."
        log_warn "Ensure ports 443, 80, and ${AI_FLUX_RAY_PORT:-6380} are open in your site firewall."
        return 0
    fi

    if ! systemctl is-active --quiet firewalld; then
        log_info "Starting firewalld"
        run_cmd systemctl enable --now firewalld
    fi

    if [[ "${mode}" == "head" ]]; then
        log_info "Opening head node ports: 80/tcp, 443/tcp, ${AI_FLUX_RAY_PORT:-6380}/tcp"
        run_cmd firewall-cmd --permanent --add-service=http
        run_cmd firewall-cmd --permanent --add-service=https
        run_cmd firewall-cmd --permanent --add-port="${AI_FLUX_RAY_PORT:-6380}/tcp"
    fi

    # Worker nodes only need outbound access (they connect TO the head node).
    # No inbound rules needed on workers.

    run_cmd firewall-cmd --reload
    log_ok "Firewall rules applied."
}

# ---------------------------------------------------------------------------
# _configure_ufw — for Ubuntu 22.04
# ---------------------------------------------------------------------------
_configure_ufw() {
    local mode="$1"

    if ! check_cmd ufw; then
        log_warn "ufw not found — skipping firewall configuration."
        return 0
    fi

    if [[ "${mode}" == "head" ]]; then
        log_info "Opening head node ports: 80, 443, ${AI_FLUX_RAY_PORT:-6380}"
        run_cmd ufw allow 80/tcp
        run_cmd ufw allow 443/tcp
        run_cmd ufw allow "${AI_FLUX_RAY_PORT:-6380}/tcp"
    fi

    # Enable ufw if not already active (non-interactively)
    if ! ufw status | grep -q "Status: active"; then
        run_cmd ufw --force enable
    fi

    log_ok "ufw rules applied."
}
