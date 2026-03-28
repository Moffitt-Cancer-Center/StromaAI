#!/usr/bin/env bash
# =============================================================================
# AI_Flux — Package management (dnf / apt wrappers)
# =============================================================================
# Provides: pkg_install(), pkg_update(), enable_epel(), enable_crb(),
#           install_python311(), install_nginx()
# Requires: OS_FAMILY set by detect.sh
# =============================================================================

[[ -n "${_AI_FLUX_PACKAGES_LOADED:-}" ]] && return 0
readonly _AI_FLUX_PACKAGES_LOADED=1

# ---------------------------------------------------------------------------
# pkg_update — refresh package metadata
# ---------------------------------------------------------------------------
pkg_update() {
    log_step "Refreshing package metadata"
    case "${OS_FAMILY}" in
        rhel)   run_cmd dnf makecache -y ;;
        debian) run_cmd apt-get update -y ;;
    esac
}

# ---------------------------------------------------------------------------
# pkg_install — install one or more packages
# ---------------------------------------------------------------------------
pkg_install() {
    log_info "Installing packages: $*"
    case "${OS_FAMILY}" in
        rhel)   run_cmd dnf install -y "$@" ;;
        debian) run_cmd env DEBIAN_FRONTEND=noninteractive apt-get install -y "$@" ;;
    esac
}

# ---------------------------------------------------------------------------
# pkg_installed — return 0 if package is already installed
# ---------------------------------------------------------------------------
pkg_installed() {
    case "${OS_FAMILY}" in
        rhel)   rpm -q "$1" &>/dev/null ;;
        debian) dpkg-query -W -f='${Status}' "$1" 2>/dev/null | grep -q "install ok installed" ;;
        *)      return 1 ;;
    esac
}

# ---------------------------------------------------------------------------
# enable_epel — install EPEL repository (RHEL/Rocky only)
# ---------------------------------------------------------------------------
enable_epel() {
    [[ "${OS_FAMILY}" == "rhel" ]] || return 0

    if pkg_installed epel-release; then
        log_info "EPEL already enabled."
        return 0
    fi

    log_step "Enabling EPEL repository"
    case "${OS_ID}" in
        rhel)
            # RHEL needs subscription-manager or EPEL RPM directly
            run_cmd dnf install -y \
                "https://dl.fedoraproject.org/pub/epel/epel-release-latest-${OS_VERSION_MAJOR}.noarch.rpm" \
                || run_cmd dnf install -y epel-release
            ;;
        rocky|almalinux|ol)
            run_cmd dnf install -y epel-release
            ;;
        centos)
            run_cmd dnf install -y epel-release
            ;;
    esac
    run_cmd dnf makecache -y
}

# ---------------------------------------------------------------------------
# enable_crb — enable CodeReady Builder / PowerTools (needed by some EPEL pkgs)
# ---------------------------------------------------------------------------
enable_crb() {
    [[ "${OS_FAMILY}" == "rhel" ]] || return 0
    log_step "Enabling CRB/PowerTools repository"

    case "${OS_ID}" in
        rhel)
            run_cmd subscription-manager repos --enable "codeready-builder-for-rhel-${OS_VERSION_MAJOR}-x86_64-rpms" 2>/dev/null \
                || run_cmd dnf config-manager --set-enabled crb 2>/dev/null \
                || log_warn "Could not enable CRB repo — some packages may be missing."
            ;;
        rocky|almalinux)
            # Rocky/Alma 9: crb; Rocky/Alma 8: powertools
            if [[ "${OS_VERSION_MAJOR}" == "9" ]]; then
                run_cmd dnf config-manager --set-enabled crb
            else
                run_cmd dnf config-manager --set-enabled powertools
            fi
            ;;
    esac
}

# ---------------------------------------------------------------------------
# install_python311 — ensure Python 3.11+ is available
# ---------------------------------------------------------------------------
install_python311() {
    # Check if already present
    if detect_python311 2>/dev/null && [[ -n "${PYTHON311:-}" ]]; then
        log_ok "Python 3.11+ already available: ${PYTHON311}"
        return 0
    fi

    log_step "Installing Python 3.11"
    case "${OS_FAMILY}" in
        rhel)
            # Both RHEL 8 AppStream and Rocky 9 AppStream carry python3.11
            run_cmd dnf install -y python3.11 python3.11-devel python3.11-pip || {
                # Fallback: try without devel (may not be needed for venv)
                run_cmd dnf install -y python3.11
            }
            PYTHON311="python3.11"
            ;;
        debian)
            # Ubuntu 22.04: python3 is 3.10; install 3.11 from deadsnakes PPA
            if ! pkg_installed python3.11; then
                run_cmd env DEBIAN_FRONTEND=noninteractive apt-get install -y software-properties-common
                run_cmd add-apt-repository -y ppa:deadsnakes/ppa
                run_cmd apt-get update -y
            fi
            run_cmd env DEBIAN_FRONTEND=noninteractive apt-get install -y \
                python3.11 python3.11-venv python3.11-dev python3-pip
            PYTHON311="python3.11"
            ;;
    esac

    export PYTHON311
    log_ok "Python 3.11 installed: ${PYTHON311}"
}

# ---------------------------------------------------------------------------
# install_base_deps — common prerequisites for all modes
# ---------------------------------------------------------------------------
install_base_deps() {
    log_step "Installing base dependencies"
    case "${OS_FAMILY}" in
        rhel)
            pkg_install curl wget git openssl ca-certificates jq
            ;;
        debian)
            pkg_install curl wget git openssl ca-certificates jq
            ;;
    esac
}

# ---------------------------------------------------------------------------
# install_nginx — install nginx
# ---------------------------------------------------------------------------
install_nginx() {
    if pkg_installed nginx; then
        log_info "nginx already installed."
        return 0
    fi
    log_step "Installing nginx"
    case "${OS_FAMILY}" in
        rhel)
            # nginx is in AppStream on RHEL 8+ / Rocky 9
            pkg_install nginx
            ;;
        debian)
            pkg_install nginx
            ;;
    esac
}

# ---------------------------------------------------------------------------
# install_head_python_deps — install vLLM, Ray, and supporting packages
# into the AI_Flux virtual environment.
# ---------------------------------------------------------------------------
install_head_python_deps() {
    log_step "Installing Python packages into ${AI_FLUX_VENV}"

    # Ensure venv exists
    if [[ ! -d "${AI_FLUX_VENV}" ]]; then
        log_info "Creating Python virtual environment at ${AI_FLUX_VENV}"
        run_cmd "${PYTHON311}" -m venv "${AI_FLUX_VENV}"
    fi

    # Upgrade pip first
    run_cmd "${AI_FLUX_PIP}" install --upgrade pip wheel setuptools

    # Install Ray before vLLM — vLLM pulls it anyway, but pinning first avoids conflicts
    log_info "Installing Ray 2.40.0 ..."
    run_cmd "${AI_FLUX_PIP}" install \
        "ray[default]==2.40.0"

    # Install vLLM — may take 5–15 minutes depending on bandwidth
    log_info "Installing vLLM 0.7.3 (this may take several minutes) ..."
    run_cmd "${AI_FLUX_PIP}" install \
        "vllm==0.7.3"

    # Additional runtime dependencies
    run_cmd "${AI_FLUX_PIP}" install \
        "requests>=2.32.3" \
        "openai>=1.65.0" \
        "huggingface_hub"

    log_ok "Python packages installed successfully."
}

# ---------------------------------------------------------------------------
# install_worker_build_deps — packages needed on worker nodes
# (no Python pip install — workers use the Apptainer container)
# ---------------------------------------------------------------------------
install_worker_build_deps() {
    log_step "Installing worker node build dependencies"
    case "${OS_FAMILY}" in
        rhel)
            pkg_install curl wget git fuse2fs fuse-overlayfs squashfuse
            ;;
        debian)
            pkg_install curl wget git fuse2fs fuse-overlayfs squashfuse
            ;;
    esac
}
