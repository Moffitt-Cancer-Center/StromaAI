#!/usr/bin/env bash
# =============================================================================
# StromaAI — OS and hardware detection
# =============================================================================
# Exports: OS_ID, OS_VERSION, OS_VERSION_MAJOR, OS_FAMILY, OS_PRETTY,
#          HAS_GPU, GPU_COUNT, GPU_MODEL, TOTAL_RAM_GB, PYTHON311
# =============================================================================

[[ -n "${_STROMA_DETECT_LOADED:-}" ]] && return 0
readonly _STROMA_DETECT_LOADED=1

set -euo pipefail

# ---------------------------------------------------------------------------
# detect_os — populate OS_* variables from /etc/os-release
# ---------------------------------------------------------------------------
detect_os() {
    if [[ ! -f /etc/os-release ]]; then
        die "/etc/os-release not found — cannot detect OS. Supported: RHEL 8, Rocky Linux 9, Ubuntu 22.04"
    fi

    # shellcheck source=/dev/null
    source /etc/os-release

    OS_ID="${ID:-unknown}"
    OS_VERSION="${VERSION_ID:-unknown}"
    OS_VERSION_MAJOR="${VERSION_ID%%.*}"
    OS_PRETTY="${PRETTY_NAME:-${ID} ${VERSION_ID}}"

    case "${OS_ID}" in
        rhel)
            [[ "${OS_VERSION_MAJOR}" == "8" ]] || \
                log_warn "RHEL ${OS_VERSION} detected; only RHEL 8.x is tested. Proceeding anyway."
            OS_FAMILY="rhel"
            ;;
        rocky)
            [[ "${OS_VERSION_MAJOR}" == "9" ]] || \
                log_warn "Rocky Linux ${OS_VERSION} detected; only Rocky 9.x is tested. Proceeding anyway."
            OS_FAMILY="rhel"
            ;;
        almalinux|centos|ol)
            log_warn "${OS_PRETTY} detected — treated as RHEL-family. Review package names if installs fail."
            OS_FAMILY="rhel"
            ;;
        ubuntu)
            [[ "${OS_VERSION}" == "22.04" ]] || \
                log_warn "Ubuntu ${OS_VERSION} detected; only 22.04 is tested. Proceeding anyway."
            OS_FAMILY="debian"
            ;;
        debian)
            log_warn "Debian detected — treated as Ubuntu/Debian family. Review package names if installs fail."
            OS_FAMILY="debian"
            ;;
        *)
            die "Unsupported OS: ${OS_PRETTY}. Supported: RHEL 8, Rocky Linux 9, Ubuntu 22.04"
            ;;
    esac

    export OS_ID OS_VERSION OS_VERSION_MAJOR OS_PRETTY OS_FAMILY
    log_ok "Detected OS: ${OS_PRETTY} (family: ${OS_FAMILY})"
}

# ---------------------------------------------------------------------------
# detect_python311 — find a Python 3.11+ executable with SSL support
# Sets PYTHON311 to the executable path, or dies if none found.
# Prefers system Python (/usr/bin/) over custom builds for reliability.
# ---------------------------------------------------------------------------
detect_python311() {
    # First pass: check system Python locations (/usr/bin/)
    local candidates=(python3.12 python3.11 python3)
    for py in "${candidates[@]}"; do
        local py_path="/usr/bin/${py}"
        if [[ -x "${py_path}" ]]; then
            local ver
            ver=$("${py_path}" -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')" 2>/dev/null)
            if version_ge "${ver}" "3.11"; then
                # Check for SSL support (critical for pip)
                if "${py_path}" -c "import ssl" 2>/dev/null; then
                    PYTHON311="${py_path}"
                    export PYTHON311
                    log_ok "Found Python ${ver} at: ${py_path}"
                    return 0
                else
                    log_warn "Python ${ver} at ${py_path} lacks SSL support (unusable for pip)"
                fi
            fi
        fi
    done
    
    # Second pass: check PATH (may find custom builds)
    for py in "${candidates[@]}"; do
        if check_cmd "${py}"; then
            local py_path
            py_path="$(command -v "${py}")"
            # Skip if we already checked this in first pass
            [[ "${py_path}" == /usr/bin/* ]] && continue
            
            local ver
            ver=$("${py}" -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')" 2>/dev/null)
            if version_ge "${ver}" "3.11"; then
                # Check for SSL support (critical for pip)
                if "${py}" -c "import ssl" 2>/dev/null; then
                    PYTHON311="${py}"
                    export PYTHON311
                    log_ok "Found Python ${ver} at: ${py_path}"
                    log_warn "Using non-system Python - if issues occur, install system python3.11"
                    return 0
                else
                    log_warn "Python ${ver} at ${py_path} lacks SSL support (unusable for pip)"
                fi
            fi
        fi
    done

    log_warn "No Python 3.11+ with SSL support found. The installer will install python3.11."
    PYTHON311=""
    export PYTHON311
    return 1
}

# ---------------------------------------------------------------------------
# detect_gpu — populate HAS_GPU, GPU_COUNT, GPU_MODEL
# ---------------------------------------------------------------------------
detect_gpu() {
    HAS_GPU=0
    GPU_COUNT=0
    GPU_MODEL="none"

    if check_cmd nvidia-smi; then
        local smi_out
        if smi_out=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null); then
            GPU_COUNT=$(echo "${smi_out}" | wc -l | tr -d ' ')
            GPU_MODEL=$(echo "${smi_out}" | head -1 | tr -d '\r')
            if [[ "${GPU_COUNT}" -gt 0 ]]; then
                HAS_GPU=1
                log_ok "Detected ${GPU_COUNT}× GPU: ${GPU_MODEL}"
            fi
        fi
    fi

    if [[ "${HAS_GPU}" -eq 0 ]]; then
        log_warn "No NVIDIA GPU detected via nvidia-smi."
    fi

    export HAS_GPU GPU_COUNT GPU_MODEL
}

# ---------------------------------------------------------------------------
# detect_ram — populate TOTAL_RAM_GB
# ---------------------------------------------------------------------------
detect_ram() {
    TOTAL_RAM_GB=0
    if [[ -f /proc/meminfo ]]; then
        local kb
        kb=$(awk '/MemTotal/ {print $2}' /proc/meminfo)
        TOTAL_RAM_GB=$(( kb / 1024 / 1024 ))
    fi
    export TOTAL_RAM_GB
    log_info "Total RAM: ${TOTAL_RAM_GB} GB"
}

# ---------------------------------------------------------------------------
# detect_shared_fs — check if the expected shared path is mounted
# ---------------------------------------------------------------------------
detect_shared_fs() {
    local shared_path="${1:-/share}"
    if mountpoint -q "${shared_path}" 2>/dev/null; then
        log_ok "Shared filesystem mounted at ${shared_path}"
        return 0
    else
        log_warn "No filesystem mounted at ${shared_path} — model and container paths may not be accessible."
        return 1
    fi
}

# ---------------------------------------------------------------------------
# detect_slurm — check if sbatch/squeue are available
# ---------------------------------------------------------------------------
detect_slurm() {
    if check_cmd sbatch && check_cmd squeue; then
        local version
        version=$(sbatch --version 2>/dev/null | head -1)
        log_ok "Slurm found: ${version}"
        return 0
    else
        log_warn "Slurm commands (sbatch/squeue) not found in PATH."
        return 1
    fi
}

# ---------------------------------------------------------------------------
# detect_selinux — check if SELinux is active
# ---------------------------------------------------------------------------
detect_selinux() {
    if check_cmd getenforce; then
        SELINUX_STATUS=$(getenforce 2>/dev/null || echo "Disabled")
        export SELINUX_STATUS
        log_info "SELinux status: ${SELINUX_STATUS}"
        return 0
    fi
    SELINUX_STATUS="N/A"
    export SELINUX_STATUS
    return 1
}

# ---------------------------------------------------------------------------
# detect_container_runtime — find apptainer or singularity on PATH
# ---------------------------------------------------------------------------
detect_container_runtime() {
    CONTAINER_RUNTIME=""
    if check_cmd apptainer; then
        CONTAINER_RUNTIME="apptainer"
    elif check_cmd singularity; then
        CONTAINER_RUNTIME="singularity"
    fi
    export CONTAINER_RUNTIME
    if [[ -n "${CONTAINER_RUNTIME}" ]]; then
        local ver
        ver=$("${CONTAINER_RUNTIME}" version 2>/dev/null | head -1)
        log_ok "Container runtime: ${CONTAINER_RUNTIME} ${ver}"
        return 0
    fi
    log_warn "No container runtime found (apptainer or singularity required on worker nodes)."
    return 1
}

# ---------------------------------------------------------------------------
# detect_all — run all detectors and summarize
# ---------------------------------------------------------------------------
detect_all() {
    detect_os
    detect_gpu
    detect_ram
    detect_selinux || true
    detect_container_runtime || true
}
