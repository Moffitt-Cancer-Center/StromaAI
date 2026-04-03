#!/usr/bin/env bash
# =============================================================================
# StromaAI — Apptainer / Singularity installation
# =============================================================================
# Provides: install_apptainer()
# Supports: RHEL 8, Rocky Linux 9, Ubuntu 22.04
#
# Apptainer is required on Slurm worker nodes to run the vLLM container.
# On RHEL/Rocky it is installed from EPEL; on Ubuntu from the official
# GitHub release .deb or the apptainer PPA.
#
# Pinned version: 1.3.6 (last tested)
# Override with: APPTAINER_VERSION=x.y.z before calling install_apptainer()
# =============================================================================

[[ -n "${_STROMA_APPTAINER_LOADED:-}" ]] && return 0
readonly _STROMA_APPTAINER_LOADED=1

set -euo pipefail

APPTAINER_VERSION="${APPTAINER_VERSION:-1.3.6}"

# ---------------------------------------------------------------------------
# try_load_module — attempt to load a module if module system is available
# ---------------------------------------------------------------------------
try_load_module() {
    local module_names=("$@")
    
    # Check if module command exists
    if ! command -v module &>/dev/null; then
        return 1
    fi
    
    # Try each module name in order
    for mod in "${module_names[@]}"; do
        log_info "Checking for environment module: ${mod}"
        
        # Try to load the module silently
        if module load "${mod}" &>/dev/null; then
            log_ok "Loaded module: ${mod}"
            return 0
        fi
        
        # Check if module is available but not loaded
        if module avail "${mod}" 2>&1 | grep -q "${mod}"; then
            log_info "Module '${mod}' exists but failed to load."
        fi
    done
    
    return 1
}

# ---------------------------------------------------------------------------
# install_apptainer — dispatch to distro-specific installers
# ---------------------------------------------------------------------------
install_apptainer() {
    # Skip if already installed at the requested version
    if check_cmd apptainer; then
        local installed_ver
        installed_ver=$(apptainer version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
        log_ok "Apptainer ${installed_ver} already installed."
        return 0
    fi

    # Singularity is an acceptable fallback (won't install if present)
    if check_cmd singularity; then
        local installed_ver
        installed_ver=$(singularity version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
        log_warn "Singularity ${installed_ver} found instead of Apptainer. Will use Singularity."
        return 0
    fi
    
    # Try loading from environment modules (common in HPC environments)
    log_step "Checking for Apptainer/Singularity environment modules"
    if try_load_module apptainer singularity; then
        # Verify it's now available
        if check_cmd apptainer || check_cmd singularity; then
            log_ok "Container runtime available via environment module."
            log_info "Add 'module load apptainer' (or singularity) to worker job scripts if needed."
            return 0
        fi
    fi

    log_step "Installing Apptainer ${APPTAINER_VERSION} from packages"
    case "${OS_FAMILY}" in
        rhel)  _install_apptainer_rhel  ;;
        debian) _install_apptainer_ubuntu ;;
        *) die "Cannot install Apptainer: unknown OS family '${OS_FAMILY}'" ;;
    esac
}

# ---------------------------------------------------------------------------
# _install_apptainer_rhel — install via EPEL (RHEL 8 / Rocky 9)
# ---------------------------------------------------------------------------
_install_apptainer_rhel() {
    # Ensure EPEL is available
    enable_epel
    enable_crb

    # EPEL carries an apptainer RPM for both RHEL 8 and Rocky 9
    if pkg_install apptainer; then
        log_ok "Apptainer installed from EPEL."
        return 0
    fi

    # Fallback: install RPM directly from GitHub releases
    log_warn "EPEL install failed; falling back to GitHub RPM download."
    _install_apptainer_from_github_rpm
}

# ---------------------------------------------------------------------------
# _install_apptainer_from_github_rpm — download RPM from GitHub releases
# ---------------------------------------------------------------------------
_install_apptainer_from_github_rpm() {
    local arch
    arch=$(uname -m)  # x86_64 or aarch64
    local rpm_url="https://github.com/apptainer/apptainer/releases/download/v${APPTAINER_VERSION}/apptainer-${APPTAINER_VERSION}-1.${arch}.rpm"
    local tmp_rpm="/tmp/apptainer-${APPTAINER_VERSION}.rpm"

    log_info "Downloading Apptainer RPM from: ${rpm_url}"
    if [[ "${STROMA_DRY_RUN:-0}" == "0" ]]; then
        curl -fsSL -o "${tmp_rpm}" "${rpm_url}" \
            || die "Failed to download Apptainer RPM. Check network or set APPTAINER_VERSION."
    fi
    run_cmd dnf install -y "${tmp_rpm}"
    rm -f "${tmp_rpm}"
    log_ok "Apptainer installed from GitHub RPM."
}

# ---------------------------------------------------------------------------
# _install_apptainer_ubuntu — install .deb from GitHub releases (Ubuntu 22.04)
# ---------------------------------------------------------------------------
_install_apptainer_ubuntu() {
    local arch
    arch=$(dpkg --print-architecture)  # amd64 or arm64
    local deb_url="https://github.com/apptainer/apptainer/releases/download/v${APPTAINER_VERSION}/apptainer_${APPTAINER_VERSION}_${arch}.deb"
    local tmp_deb="/tmp/apptainer_${APPTAINER_VERSION}_${arch}.deb"

    # Install runtime dependencies first
    run_cmd env DEBIAN_FRONTEND=noninteractive apt-get install -y \
        fuse2fs fuse-overlayfs squashfuse libfuse2

    log_info "Downloading Apptainer .deb from: ${deb_url}"
    if [[ "${STROMA_DRY_RUN:-0}" == "0" ]]; then
        curl -fsSL -o "${tmp_deb}" "${deb_url}" \
            || die "Failed to download Apptainer .deb. Check network or set APPTAINER_VERSION."
    fi
    run_cmd env DEBIAN_FRONTEND=noninteractive dpkg -i "${tmp_deb}"
    run_cmd env DEBIAN_FRONTEND=noninteractive apt-get install -f -y  # fix any deps
    rm -f "${tmp_deb}"
    log_ok "Apptainer installed from GitHub .deb."
}

# ---------------------------------------------------------------------------
# configure_apptainer — post-install configuration for HPC environments
# ---------------------------------------------------------------------------
configure_apptainer() {
    local conf_dir="/etc/apptainer"
    local conf_file="${conf_dir}/apptainer.conf"

    # Singularity compatibility
    if [[ -d /etc/singularity && ! -d "${conf_dir}" ]]; then
        conf_dir="/etc/singularity"
        conf_file="${conf_dir}/singularity.conf"
    fi

    [[ -d "${conf_dir}" ]] || return 0

    log_step "Configuring Apptainer for HPC environment"

    # Allow user namespaces (required for --fakeroot builds)
    if [[ -f "${conf_file}" ]]; then
        backup_file "${conf_file}"
        # Allow setuid workflow (needed for --nv on older kernels)
        if grep -q "^allow setuid" "${conf_file}" 2>/dev/null; then
            run_cmd sed -i 's/^allow setuid = no/allow setuid = yes/' "${conf_file}"
        fi
    fi

    # Set TMPDIR to a large partition if /tmp is small
    local tmp_space_kb
    tmp_space_kb=$(df -k /tmp 2>/dev/null | awk 'NR==2 {print $4}')
    if [[ "${tmp_space_kb:-0}" -lt 20971520 ]]; then  # < 20GB
        log_warn "/tmp has less than 20GB free — Apptainer container builds may fail."
        log_warn "Set APPTAINER_TMPDIR=/path/to/large/tmp before building containers."
    fi

    log_ok "Apptainer configuration complete."
}

# ---------------------------------------------------------------------------
# verify_apptainer — smoke test the container runtime
# ---------------------------------------------------------------------------
verify_apptainer() {
    local runtime="${CONTAINER_RUNTIME:-apptainer}"
    log_step "Verifying Apptainer installation"

    if ! check_cmd "${runtime}"; then
        log_error "Apptainer/Singularity not found in PATH after installation."
        return 1
    fi

    # Run a trivial container test
    if [[ "${STROMA_DRY_RUN:-0}" == "0" ]]; then
        if "${runtime}" exec --bind /tmp:/tmp \
            docker://alpine:3.19 echo "Apptainer container test OK" 2>/dev/null; then
            log_ok "Apptainer smoke test passed."
        else
            log_warn "Apptainer smoke test failed (this may be OK in air-gapped environments)."
            log_warn "Verify manually: ${runtime} exec docker://alpine echo hello"
        fi
    fi

    return 0
}
