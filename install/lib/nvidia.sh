#!/usr/bin/env bash
# =============================================================================
# StromaAI — NVIDIA Container Toolkit installation
# =============================================================================
# Provides: install_nvidia_container_toolkit(), verify_nvidia_gpu()
# Supports: RHEL 8, Rocky Linux 9, Ubuntu 22.04
#
# The NVIDIA Container Toolkit is required on Slurm worker nodes so that
# Apptainer/Singularity can pass GPUs into containers via --nv or --nvccli.
#
# IMPORTANT: NVIDIA GPU drivers must already be installed before running this.
# This script ONLY installs the container toolkit + CDI config.
# =============================================================================

[[ -n "${_STROMA_NVIDIA_LOADED:-}" ]] && return 0
readonly _STROMA_NVIDIA_LOADED=1

# ---------------------------------------------------------------------------
# verify_nvidia_gpu — confirm nvidia-smi works and driver is loaded
# ---------------------------------------------------------------------------
verify_nvidia_gpu() {
    log_step "Verifying NVIDIA GPU and driver"

    if ! check_cmd nvidia-smi; then
        log_error "nvidia-smi not found. Install NVIDIA drivers before running this step."
        log_error "Driver installation is site-specific — consult your HPC team."
        return 1
    fi

    local driver_ver gpu_name
    driver_ver=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1)
    gpu_name=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)

    if [[ -z "${driver_ver}" ]]; then
        log_error "nvidia-smi returned no GPUs. Check that the NVIDIA module is loaded."
        return 1
    fi

    log_ok "GPU: ${gpu_name}"
    log_ok "Driver version: ${driver_ver}"

    # Warn if driver is older than 525 (minimum for vLLM FP8 on L30)
    local driver_major="${driver_ver%%.*}"
    if [[ "${driver_major}" -lt 525 ]]; then
        log_warn "Driver ${driver_ver} is older than 525.x — FP8 KV cache may not work on Ada Lovelace GPUs."
        log_warn "Recommended: 535.x or newer for L30/L40 series."
    fi

    return 0
}

# ---------------------------------------------------------------------------
# install_nvidia_container_toolkit — distro dispatch
# ---------------------------------------------------------------------------
install_nvidia_container_toolkit() {
    # Check if already installed
    if check_cmd nvidia-ctk; then
        local ver
        ver=$(nvidia-ctk version --short 2>/dev/null || echo "unknown")
        log_ok "NVIDIA Container Toolkit already installed (${ver})."
        return 0
    fi

    log_step "Installing NVIDIA Container Toolkit"
    case "${OS_FAMILY}" in
        rhel)   _install_nct_rhel ;;
        debian) _install_nct_ubuntu ;;
        *)      die "Cannot install NVIDIA Container Toolkit: unknown OS family '${OS_FAMILY}'" ;;
    esac

    _configure_nct_for_apptainer
}

# ---------------------------------------------------------------------------
# _install_nct_rhel — RHEL 8 or Rocky 9
# ---------------------------------------------------------------------------
_install_nct_rhel() {
    local distro_tag
    case "${OS_ID}" in
        rhel)   distro_tag="rhel${OS_VERSION_MAJOR}" ;;
        rocky)  distro_tag="rhel${OS_VERSION_MAJOR}" ;;
        *)      distro_tag="rhel${OS_VERSION_MAJOR}" ;;
    esac

    local arch
    arch=$(uname -m)  # x86_64 or aarch64
    local repo_url="https://nvidia.github.io/libnvidia-container/${distro_tag}/${arch}/libnvidia-container.repo"

    log_info "Adding NVIDIA Container Toolkit repo for ${distro_tag}/${arch}"
    if [[ "${STROMA_DRY_RUN:-0}" == "0" ]]; then
        curl -fsSL "${repo_url}" \
            -o /etc/yum.repos.d/nvidia-container-toolkit.repo \
            || die "Failed to download NVIDIA repo file. Check network connectivity."
    fi

    run_cmd dnf install -y nvidia-container-toolkit
}

# ---------------------------------------------------------------------------
# _install_nct_ubuntu — Ubuntu 22.04
# ---------------------------------------------------------------------------
_install_nct_ubuntu() {
    local arch
    arch=$(dpkg --print-architecture)

    # Add the NVIDIA GPG key
    log_info "Adding NVIDIA Container Toolkit GPG key"
    if [[ "${STROMA_DRY_RUN:-0}" == "0" ]]; then
        curl -fsSL https://nvidia.github.io/libnvidia-container/gpgkey \
            | gpg --dearmor -o /usr/share/keyrings/nvidia-container-toolkit-keyring.gpg \
            || die "Failed to download NVIDIA GPG key."
    fi

    # Add the APT repo
    if [[ "${STROMA_DRY_RUN:-0}" == "0" ]]; then
        curl -fsSL \
            "https://nvidia.github.io/libnvidia-container/stable/deb/${arch}/libnvidia-container.list" \
            | sed 's#deb https://#deb [signed-by=/usr/share/keyrings/nvidia-container-toolkit-keyring.gpg] https://#g' \
            | tee /etc/apt/sources.list.d/nvidia-container-toolkit.list >/dev/null \
            || die "Failed to add NVIDIA APT repo."
    fi

    run_cmd apt-get update -y
    run_cmd env DEBIAN_FRONTEND=noninteractive apt-get install -y nvidia-container-toolkit
}

# ---------------------------------------------------------------------------
# _configure_nct_for_apptainer — configure CDI device files
# so Apptainer --nvccli flag works without setuid
# ---------------------------------------------------------------------------
_configure_nct_for_apptainer() {
    log_step "Configuring NVIDIA CDI for Apptainer"

    if ! check_cmd nvidia-ctk; then
        log_warn "nvidia-ctk not found after install — skipping CDI configuration."
        return 1
    fi

    # Generate CDI spec for all GPUs
    run_cmd nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml 2>/dev/null || {
        log_warn "CDI generation failed — Apptainer will fall back to --nv mode."
        log_warn "This is expected if no GPU is present on this node."
        return 0
    }

    log_ok "CDI device files generated at /etc/cdi/nvidia.yaml"
    log_info "Workers can now use: apptainer exec --nvccli <image> ..."
    log_info "Or legacy mode:      apptainer exec --nv <image> ..."
}

# ---------------------------------------------------------------------------
# verify_gpu_in_container — run a brief GPU test inside a container
# ---------------------------------------------------------------------------
verify_gpu_in_container() {
    local runtime="${CONTAINER_RUNTIME:-apptainer}"
    local sif="${STROMA_CONTAINER:-/share/containers/ai-flux-vllm.sif}"

    log_step "Verifying GPU access inside container"

    if [[ ! -f "${sif}" ]]; then
        log_warn "Container image not found at ${sif} — skipping GPU-in-container test."
        log_warn "Build the container first: apptainer build ${sif} deploy/containers/ai-flux-vllm.def"
        return 0
    fi

    if [[ "${STROMA_DRY_RUN:-0}" == "0" ]]; then
        if "${runtime}" exec --nv "${sif}" python3 -c \
            "import torch; print('CUDA available:', torch.cuda.is_available()); \
             print('GPU count:', torch.cuda.device_count())" 2>/dev/null; then
            log_ok "GPU access inside container verified."
        else
            log_warn "GPU test inside container failed."
            log_warn "Check NVIDIA driver, container toolkit, and SELinux settings."
        fi
    fi
}
