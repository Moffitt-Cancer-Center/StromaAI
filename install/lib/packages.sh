#!/usr/bin/env bash
# =============================================================================
# StromaAI — Package management (dnf / apt wrappers)
# =============================================================================
# Provides: pkg_install(), pkg_update(), enable_epel(), enable_crb(),
#           install_python311(), install_nginx()
# Requires: OS_FAMILY set by detect.sh
# =============================================================================

[[ -n "${_STROMA_PACKAGES_LOADED:-}" ]] && return 0
readonly _STROMA_PACKAGES_LOADED=1

set -euo pipefail

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
        log_info "EPEL already installed."
    else
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
    fi
    
    # Ensure EPEL repos are actually enabled (they can be disabled even when installed)
    if [[ "${OS_ID}" == "rhel" ]]; then
        run_cmd dnf config-manager --set-enabled epel 2>/dev/null || log_warn "Could not enable EPEL repo"
    fi
    
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
            # Install OpenSSL development libs first (ensures SSL module availability)
            run_cmd dnf install -y openssl-devel || log_warn "openssl-devel install failed (may already be present)"
            
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
                python3.11 python3.11-venv python3.11-dev python3-pip libssl-dev
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
            # jq is in EPEL - install separately with error handling
            pkg_install curl wget git openssl ca-certificates gettext
            pkg_install jq || log_warn "jq not available (optional - used by some scripts)"
            ;;
        debian)
            pkg_install curl wget git openssl ca-certificates jq gettext-base
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
# into the StromaAI virtual environment.
# ---------------------------------------------------------------------------
install_head_python_deps() {
    log_step "Installing Python packages into ${STROMA_VENV}"

    # Ensure OpenSSL development headers are present (critical for SSL module in venv)
    if [[ "${OS_FAMILY}" == "rhel" ]]; then
        if ! pkg_installed openssl-devel; then
            log_info "Installing openssl-devel (required for SSL support in Python venv)..."
            run_cmd dnf install -y openssl-devel
        fi
    elif [[ "${OS_FAMILY}" == "debian" ]]; then
        if ! pkg_installed libssl-dev; then
            log_info "Installing libssl-dev (required for SSL support in Python venv)..."
            run_cmd apt-get install -y libssl-dev
        fi
    fi

    # Check if existing venv has SSL support; recreate if broken
    if [[ -d "${STROMA_VENV}" ]]; then
        if "${STROMA_VENV}/bin/python" -c "import ssl" 2>/dev/null; then
            log_info "Existing venv at ${STROMA_VENV} has SSL support — reusing."
        else
            log_warn "Existing venv at ${STROMA_VENV} lacks SSL support (created with broken Python)."
            log_warn "Removing and recreating with ${PYTHON311}..."
            run_cmd rm -rf "${STROMA_VENV}"
        fi
    fi

    # Ensure venv exists
    if [[ ! -d "${STROMA_VENV}" ]]; then
        log_info "Creating Python virtual environment at ${STROMA_VENV}"
        run_cmd "${PYTHON311}" -m venv "${STROMA_VENV}"
        
        # Verify the new venv has SSL support
        if ! "${STROMA_VENV}/bin/python" -c "import ssl" 2>/dev/null; then
            die "CRITICAL: Newly created venv still lacks SSL support. Install openssl-devel and python3.11-devel, then re-run."
        fi
        log_ok "Virtual environment created with SSL support"
    fi

    # Upgrade pip first
    run_cmd "${STROMA_PIP}" install --upgrade pip wheel setuptools

    # Install Ray before vLLM — vLLM pulls it anyway, but pinning first avoids conflicts
    log_info "Installing Ray 2.40.0 ..."
    run_cmd "${STROMA_PIP}" install \
        "ray[default]==2.40.0"

    # Install vLLM — may take 5–15 minutes depending on bandwidth
    # Pin transformers<4.50.0: transformers 4.50.0 added __init_subclass__ dataclass
    # wrapping to PretrainedConfig; DeepseekVLV2Config's field ordering causes a
    # TypeError on both Python 3.10 and 3.11. vLLM 0.7.x requires >=4.45.0.
    log_info "Installing vLLM 0.7.2 + pinned transformers (this may take several minutes) ..."
    run_cmd "${STROMA_PIP}" install \
        "vllm==0.7.2" \
        "transformers==4.49.0"

    # Additional runtime dependencies
    run_cmd "${STROMA_PIP}" install \
        "requests>=2.32.3" \
        "openai>=1.65.0" \
        "huggingface_hub"

    # Hardware-aware model selection tool — detects GPU/VRAM and filters Hub
    # search results to models that fit; suggests quantization when a model
    # is slightly too large.  Installs as `hfw` (safe alias) and `hf` (hub wrapper).
    # Downloads are routed to ${STROMA_SHARED_ROOT}/models/ automatically.
    log_info "Installing hfmodel-check ..."
    run_cmd "${STROMA_PIP}" install \
        "git+https://git@github.com/Moffitt-Cancer-Center/hfmodel-check"

    # Gateway OIDC proxy dependencies (FastAPI, uvicorn, httpx, PyJWT, cryptography)
    if [[ -f "${REPO_DIR}/requirements-gateway.txt" ]]; then
        log_info "Installing gateway dependencies from requirements-gateway.txt ..."
        run_cmd "${STROMA_PIP}" install -r "${REPO_DIR}/requirements-gateway.txt"
    else
        log_info "Installing gateway dependencies inline ..."
        run_cmd "${STROMA_PIP}" install \
            "fastapi>=0.115.0" \
            "uvicorn[standard]>=0.32.0" \
            "httpx>=0.27.0" \
            "PyJWT[crypto]>=2.9.0" \
            "cryptography>=43.0.0"
    fi

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
            # fuse2fs is provided by e2fsprogs on RHEL/Rocky/AlmaLinux (not a separate package)
            pkg_install curl wget git e2fsprogs fuse-overlayfs squashfuse
            ;;
        debian)
            pkg_install curl wget git fuse2fs fuse-overlayfs squashfuse
            ;;
    esac
}
