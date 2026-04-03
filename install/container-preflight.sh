#!/usr/bin/env bash
# =============================================================================
# StromaAI — Container Environment Preflight + Dependency Installer
# =============================================================================
# Checks that all prerequisites for running StromaAI containers are present
# on the current node, then optionally installs any missing dependencies.
#
# Three node targets are supported:
#
#   --target=apptainer-worker
#       Slurm GPU nodes that run the vLLM+Ray Apptainer container.
#       Checks: NVIDIA GPU/driver, Apptainer/Singularity, NVIDIA Container
#               Toolkit, SELinux booleans, shared filesystem, FUSE kernel
#               modules, /tmp space, Slurm commands.
#
#   --target=compose-host
#       Any host that runs Keycloak or OpenWebUI via Podman Compose.
#       Checks: Podman, podman-compose availability, kernel userns support,
#               /etc/subuid + /etc/subgid (rootless), port availability,
#               Python 3.10+ (for secret generation helpers), curl.
#
#   --target=build-host
#       Internet-connected machine used to build the Apptainer SIF image.
#       Checks: Apptainer, available disk space, /tmp space, FUSE modules,
#               network connectivity to NVIDIA NGC and GitHub.
#
# Usage:
#   sudo ./install/container-preflight.sh --target=apptainer-worker
#        ./install/container-preflight.sh --target=compose-host
#        ./install/container-preflight.sh --target=build-host
#        ./install/container-preflight.sh --target=apptainer-worker --install
#        ./install/container-preflight.sh --target=all
#
# Flags:
#   --target=TARGET   Node target (required). Use "all" to run every target.
#   --install         After checks, install any missing dependencies.
#   --dry-run         Print what would be installed without making changes.
#   --yes             Non-interactive: auto-confirm all install prompts.
#   -h, --help        Show this help and exit.
#
# Exit codes:
#   0  All checks passed (warnings count as pass).
#   1  One or more blocking failures detected.
# =============================================================================

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=install/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=install/lib/detect.sh
source "${SCRIPT_DIR}/lib/detect.sh"
# shellcheck source=install/lib/packages.sh
source "${SCRIPT_DIR}/lib/packages.sh"
# shellcheck source=install/lib/apptainer.sh
source "${SCRIPT_DIR}/lib/apptainer.sh"
# shellcheck source=install/lib/nvidia.sh
source "${SCRIPT_DIR}/lib/nvidia.sh"
# shellcheck source=install/lib/selinux.sh
source "${SCRIPT_DIR}/lib/selinux.sh"

# ---------------------------------------------------------------------------
# Usage
# ---------------------------------------------------------------------------
_show_usage() {
    cat <<EOF
Usage: $0 --target=TARGET [OPTIONS]

Targets:
  apptainer-worker  Slurm GPU node running vLLM via Apptainer
  compose-host      Host running Keycloak/OpenWebUI via Podman Compose
  build-host        Internet-connected machine that builds the SIF image
  all               Run all three targets in sequence

Options:
  --install         Install any missing dependencies after checks
  --dry-run         Show install commands without executing them
  --yes             Non-interactive (auto-confirm all prompts)
  -h, --help        Show this help and exit

Examples:
  sudo ./install/container-preflight.sh --target=apptainer-worker
  sudo ./install/container-preflight.sh --target=apptainer-worker --install
       ./install/container-preflight.sh --target=compose-host
       ./install/container-preflight.sh --target=build-host --install
EOF
}

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
TARGET=""
DO_INSTALL=0

for _arg in "$@"; do
    case "${_arg}" in
        --target=*)  TARGET="${_arg#--target=}" ;;
        --install)   DO_INSTALL=1 ;;
        --dry-run)   export STROMA_DRY_RUN=1 ;;
        --yes)       export STROMA_YES=1 ;;
        -h|--help)   _show_usage; exit 0 ;;
        *) die "Unknown argument: ${_arg}. Use --help for usage." ;;
    esac
done
unset _arg

[[ -n "${TARGET}" ]] || { _show_usage; die "Missing required flag: --target"; }

# ---------------------------------------------------------------------------
# Check-tracking counters
# ---------------------------------------------------------------------------
PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0

# Track items that --install should fix
NEEDS_INSTALL=()

check_pass() { log_ok   "$1"; (( PASS_COUNT++ )) || true; }
check_warn() { log_warn "$1"; (( WARN_COUNT++ )) || true; }
check_fail() { log_error "$1"; (( FAIL_COUNT++ )) || true; }

# Register a fix to apply during --install phase
need() {
    local label="$1"
    NEEDS_INSTALL+=("${label}")
}

# ---------------------------------------------------------------------------
# Shared helpers
# ---------------------------------------------------------------------------

# Minimum free space check: check_disk PATH MIN_GB LABEL
check_disk() {
    local path="$1" min_gb="$2" label="$3"
    if [[ ! -e "${path}" ]]; then
        check_warn "${label}: ${path} does not exist — skipping disk check"
        return
    fi
    local free_gb
    free_gb=$(df -BG "${path}" 2>/dev/null | awk 'NR==2 {gsub(/G/,""); print $4}')
    if [[ "${free_gb:-0}" -ge "${min_gb}" ]]; then
        check_pass "${label}: ${free_gb} GB free on ${path}"
    else
        check_fail "${label}: only ${free_gb} GB free on ${path} (need ${min_gb}+ GB)"
    fi
}

# Kernel module check
check_kmod() {
    local mod="$1"
    if lsmod 2>/dev/null | grep -q "^${mod} " || modinfo "${mod}" &>/dev/null; then
        check_pass "Kernel module: ${mod} available"
    else
        check_warn "Kernel module ${mod} not loaded — run: modprobe ${mod}"
    fi
}

# Port availability check
check_port_free() {
    local port="$1" label="$2"
    if ss -tlnp 2>/dev/null | grep -q ":${port} "; then
        check_warn "Port ${port} (${label}) is already in use"
    else
        check_pass "Port ${port} (${label}) is available"
    fi
}

# Network reachability check (warn-only — may be air-gapped)
check_url() {
    local url="$1" label="$2"
    if curl -fsS --max-time 8 "${url}" &>/dev/null; then
        check_pass "Network: ${label} reachable"
    else
        check_warn "Network: cannot reach ${label} (${url}) — check connectivity or proxy settings"
    fi
}

# =============================================================================
# TARGET: apptainer-worker
# =============================================================================
check_apptainer_worker() {
    log_step "Apptainer Worker Node — Container Runtime Prerequisites"

    # Root
    if [[ ${EUID} -eq 0 ]]; then
        check_pass "Running as root (required for SELinux + toolkit install)"
    else
        check_warn "Not running as root — re-run with sudo for --install to work"
    fi

    # OS detection
    detect_os
    check_pass "OS: ${OS_PRETTY} (family: ${OS_FAMILY})"

    # ---- NVIDIA GPU ----
    log_step "  GPU and Driver"
    if command -v nvidia-smi &>/dev/null; then
        local driver_ver gpu_name gpu_count
        driver_ver=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1)
        gpu_name=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)
        gpu_count=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | wc -l)
        check_pass "NVIDIA GPU(s) detected: ${gpu_count}× ${gpu_name}"
        local driver_major="${driver_ver%%.*}"
        if [[ "${driver_major:-0}" -ge 525 ]]; then
            check_pass "NVIDIA driver: ${driver_ver} (≥525, CUDA 12.x capable)"
        else
            check_fail "NVIDIA driver ${driver_ver} < 525 — FP8 KV cache and CUDA 12.x require ≥525.85"
        fi
    else
        check_fail "nvidia-smi not found — NVIDIA driver not installed or not in PATH"
        check_warn "Driver installation is HPC site-specific; contact your sysadmin."
    fi

    # ---- Apptainer / Singularity ----
    log_step "  Container Runtime (Apptainer/Singularity)"
    if command -v apptainer &>/dev/null; then
        local ap_ver
        ap_ver=$(apptainer version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
        check_pass "Apptainer ${ap_ver} found: $(command -v apptainer)"
        if [[ "$(printf '%s\n' "1.1.0" "${ap_ver}" | sort -V | head -1)" != "1.1.0" ]]; then
            check_warn "Apptainer ${ap_ver} < 1.1 — upgrade recommended; 1.3+ adds CDI support"
        fi
    elif command -v singularity &>/dev/null; then
        local sg_ver
        sg_ver=$(singularity version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
        check_warn "Singularity ${sg_ver} found (acceptable fallback) — Apptainer preferred"
    else
        check_fail "Neither Apptainer nor Singularity found in PATH"
        need "apptainer"
    fi

    # ---- NVIDIA Container Toolkit ----
    log_step "  NVIDIA Container Toolkit (for --nv / --nvccli GPU passthrough)"
    if command -v nvidia-ctk &>/dev/null; then
        local nct_ver
        nct_ver=$(nvidia-ctk version --short 2>/dev/null || echo "unknown")
        check_pass "NVIDIA Container Toolkit: ${nct_ver}"
    else
        check_warn "nvidia-ctk not found — GPU passthrough into containers may be limited"
        check_warn "Install with: dnf install nvidia-container-toolkit  (after adding NVIDIA repo)"
        check_warn "Note: CUDA Toolkit modules (cuda/toolkit) are NOT the same as NVIDIA Container Toolkit"
        need "nvidia-container-toolkit"
    fi

    # CDI config
    if [[ -f /etc/cdi/nvidia.yaml ]]; then
        check_pass "CDI config: /etc/cdi/nvidia.yaml present (enables --nvccli)"
    else
        check_warn "CDI config /etc/cdi/nvidia.yaml missing — run: nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml"
    fi

    # ---- FUSE kernel modules ----
    log_step "  FUSE kernel modules (required by Apptainer OverlayFS)"
    check_kmod fuse
    check_kmod overlay

    # ---- Slurm commands ----
    log_step "  Slurm"
    for cmd in sbatch squeue scancel sinfo; do
        if command -v "${cmd}" &>/dev/null; then
            check_pass "Slurm command available: ${cmd}"
        else
            check_fail "Slurm command not in PATH: ${cmd}"
        fi
    done

    # ---- Shared filesystem mount ----
    log_step "  Shared Filesystem"
    local shared_root="${STROMA_SHARED_ROOT:-/share}"
    if mountpoint -q "${shared_root}" 2>/dev/null || [[ -d "${shared_root}" ]]; then
        local sif_path="${STROMA_CONTAINER:-${shared_root}/containers/stroma-ai-vllm.sif}"
        local model_path="${STROMA_MODEL_PATH:-${shared_root}/models}"
        check_pass "Shared root accessible: ${shared_root}"
        if [[ -f "${sif_path}" ]]; then
            local sif_gb
            sif_gb=$(du -BG "${sif_path}" 2>/dev/null | awk '{gsub(/G/,""); print $1}')
            check_pass "SIF image found: ${sif_path} (${sif_gb} GB)"
        else
            check_warn "SIF image not found at ${sif_path} — build it with: apptainer build stroma-ai-vllm.sif deploy/containers/stroma-ai-vllm.def"
        fi
        if [[ -d "${model_path}" ]]; then
            check_pass "Model path exists: ${model_path}"
        else
            check_warn "Model path not found: ${model_path} — download model weights before first use"
        fi
    else
        check_fail "Shared root ${shared_root} not mounted — NFS/GPFS must be mounted before workers can start"
    fi

    # ---- /tmp space ----
    check_disk /tmp 20 "/tmp space (Apptainer overlay builds)"

    # ---- SELinux booleans (RHEL-family only) ----
    if command -v getenforce &>/dev/null && [[ "$(getenforce 2>/dev/null)" == "Enforcing" ]]; then
        log_step "  SELinux Booleans"
        local all_set=1
        for bool in container_use_cgroups container_manage_cgroup container_use_devices; do
            if getsebool "${bool}" 2>/dev/null | grep -q "on$"; then
                check_pass "SELinux boolean: ${bool}=on"
            else
                if [[ "${bool}" == "container_use_devices" ]]; then
                    check_warn "SELinux boolean ${bool} is off — required for --nvccli CDI mode; set with: setsebool -P ${bool} 1"
                else
                    check_fail "SELinux boolean ${bool} is off — Apptainer GPU jobs will fail; fix with: setsebool -P ${bool} 1"
                fi
                need "selinux:${bool}"
                all_set=0
            fi
        done
        [[ "${all_set}" -eq 1 ]] && check_pass "All required SELinux booleans are set"
    fi

    # ---- RAM ----
    detect_ram 2>/dev/null || true
    local ram_gb="${TOTAL_RAM_GB:-0}"
    if [[ "${ram_gb}" -ge 512 ]]; then
        check_pass "System RAM: ${ram_gb} GB (good for CPU KV cache offload)"
    elif [[ "${ram_gb}" -ge 64 ]]; then
        check_warn "System RAM: ${ram_gb} GB — 512+ GB recommended for --cpu-offload-gb 200"
    else
        check_warn "System RAM: ${ram_gb} GB — may be insufficient for KV cache workloads"
    fi
}

install_apptainer_worker() {
    log_step "Installing missing apptainer-worker dependencies"

    for item in "${NEEDS_INSTALL[@]}"; do
        case "${item}" in
            apptainer)
                log_info "Installing Apptainer..."
                install_apptainer
                configure_apptainer
                verify_apptainer
                ;;
            nvidia-container-toolkit)
                log_info "Installing NVIDIA Container Toolkit..."
                install_nvidia_container_toolkit
                ;;
            selinux:*)
                local bool="${item#selinux:}"
                log_info "Setting SELinux boolean: ${bool}"
                run_cmd setsebool -P "${bool}" 1
                ;;
        esac
    done

    # Generate CDI config if nvidia-ctk is now present and no config exists
    if command -v nvidia-ctk &>/dev/null && [[ ! -f /etc/cdi/nvidia.yaml ]]; then
        log_info "Generating CDI configuration..."
        run_cmd nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml
    fi
}

# =============================================================================
# TARGET: compose-host
# =============================================================================
check_compose_host() {
    log_step "Compose Host — Podman + Rootless Container Prerequisites"

    # Does NOT require root — Podman is designed for rootless operation
    detect_os

    # ---- Podman ----
    log_step "  Podman"
    if command -v podman &>/dev/null; then
        local podman_ver
        podman_ver=$(podman version --format '{{.Version}}' 2>/dev/null || podman version 2>/dev/null | awk '/^Version:/{print $2}')
        check_pass "Podman ${podman_ver} found: $(command -v podman)"
        local podman_major
        podman_major=$(echo "${podman_ver}" | cut -d. -f1)
        if [[ "${podman_major:-0}" -ge 4 ]]; then
            check_pass "Podman ≥4 — 'podman compose' subcommand may be available"
        else
            check_warn "Podman ${podman_ver} < 4 — upgrade for built-in compose support"
        fi
    else
        check_fail "Podman not found"
        need "podman"
    fi

    # ---- Podman Compose ----
    log_step "  Podman Compose"
    if podman compose version &>/dev/null 2>&1; then
        check_pass "Podman compose subcommand (built-in) works"
    elif command -v podman-compose &>/dev/null; then
        local pc_ver
        pc_ver=$(podman-compose version 2>/dev/null | head -1 || echo "unknown")
        check_pass "podman-compose (standalone) found: ${pc_ver}"
    else
        check_fail "No Podman Compose implementation found"
        check_warn "Install with: dnf install podman-compose  OR  pip3 install podman-compose"
        need "podman-compose"
    fi

    # ---- Rootless prerequisites (/etc/subuid + /etc/subgid) ----
    log_step "  Rootless User Namespace Mapping"
    local running_user="${SUDO_USER:-$(whoami)}"
    if grep -q "^${running_user}:" /etc/subuid 2>/dev/null; then
        local subuid_range
        subuid_range=$(grep "^${running_user}:" /etc/subuid | cut -d: -f3)
        check_pass "/etc/subuid entry for ${running_user} (${subuid_range} UIDs)"
    else
        check_warn "/etc/subuid entry missing for ${running_user} — rootless Podman may fail"
        check_warn "Fix with: usermod --add-subuids 100000-165535 ${running_user}"
        need "subuid:${running_user}"
    fi
    if grep -q "^${running_user}:" /etc/subgid 2>/dev/null; then
        local subgid_range
        subgid_range=$(grep "^${running_user}:" /etc/subgid | cut -d: -f3)
        check_pass "/etc/subgid entry for ${running_user} (${subgid_range} GIDs)"
    else
        check_warn "/etc/subgid entry missing for ${running_user}"
        check_warn "Fix with: usermod --add-subgids 100000-165535 ${running_user}"
        need "subgid:${running_user}"
    fi

    # ---- Kernel: user namespaces enabled ----
    log_step "  Kernel Capabilities"
    local max_userns
    max_userns=$(sysctl -n user.max_user_namespaces 2>/dev/null || echo "0")
    if [[ "${max_userns}" -gt 0 ]]; then
        check_pass "user.max_user_namespaces=${max_userns} (user namespaces enabled)"
    else
        check_fail "user.max_user_namespaces=0 — rootless Podman requires user namespace support"
        check_warn "Fix with: echo 'user.max_user_namespaces=15000' >> /etc/sysctl.d/99-userns.conf && sysctl --system"
        need "userns"
    fi

    # ---- Port availability ----
    log_step "  Port Availability"
    check_port_free "${KC_PORT:-8080}"      "Keycloak HTTP"
    check_port_free "${OPENWEBUI_PORT:-3000}" "OpenWebUI"
    check_port_free "${GATEWAY_PORT:-9000}" "StromaAI OIDC Gateway"

    # ---- Python (used by setup scripts) ----
    log_step "  Python (setup script dependency)"
    if python3 --version &>/dev/null; then
        local py_ver
        py_ver=$(python3 -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')" 2>/dev/null)
        local py_major py_minor
        py_major=$(echo "${py_ver}" | cut -d. -f1)
        py_minor=$(echo "${py_ver}" | cut -d. -f2)
        if [[ "${py_major}" -ge 3 && "${py_minor}" -ge 10 ]]; then
            check_pass "Python ${py_ver} found"
        else
            check_warn "Python ${py_ver} — Python 3.10+ recommended for setup scripts"
        fi
    else
        check_fail "python3 not found — required by setup scripts"
        need "python3"
    fi

    # ---- curl (used by health-check loops) ----
    if command -v curl &>/dev/null; then
        check_pass "curl found: $(command -v curl)"
    else
        check_fail "curl not found — required by setup scripts and health checks"
        need "curl"
    fi

    # ---- Disk space ----
    log_step "  Disk Space"
    check_disk /var/lib/containers 20 "Podman storage (/var/lib/containers)"
    # Podman rootless stores under $HOME
    local home_dir
    home_dir=$(eval echo "~${SUDO_USER:-$(whoami)}")
    if [[ -d "${home_dir}" ]]; then
        check_disk "${home_dir}" 10 "Home directory (rootless Podman storage)"
    fi

    # ---- SELinux: container_t can connect to host network ----
    if command -v getenforce &>/dev/null && [[ "$(getenforce 2>/dev/null)" == "Enforcing" ]]; then
        log_step "  SELinux (Podman + network)"
        if getsebool container_manage_cgroup 2>/dev/null | grep -q "on$"; then
            check_pass "SELinux boolean: container_manage_cgroup=on"
        else
            check_warn "SELinux boolean container_manage_cgroup is off — Podman systemd containers may fail"
            need "selinux:container_manage_cgroup"
        fi
    fi
}

install_compose_host() {
    log_step "Installing missing compose-host dependencies"

    for item in "${NEEDS_INSTALL[@]}"; do
        case "${item}" in
            podman)
                log_info "Installing Podman..."
                case "${OS_FAMILY:-}" in
                    rhel)
                        enable_epel
                        pkg_install podman
                        ;;
                    debian)
                        pkg_install podman
                        ;;
                    *)
                        die "Auto-install of Podman not supported on this OS. Install manually."
                        ;;
                esac
                ;;
            podman-compose)
                log_info "Installing podman-compose..."
                if command -v dnf &>/dev/null; then
                    enable_epel
                    pkg_install podman-compose || \
                        run_cmd pip3 install podman-compose
                else
                    pkg_install python3-pip 2>/dev/null || true
                    run_cmd pip3 install podman-compose
                fi
                ;;
            subuid:*)
                local uname="${item#subuid:}"
                log_info "Adding subuid mapping for ${uname}..."
                run_cmd usermod --add-subuids 100000-165535 "${uname}" || \
                    { echo "${uname}:100000:65536" >> /etc/subuid; }
                ;;
            subgid:*)
                local gname="${item#subgid:}"
                log_info "Adding subgid mapping for ${gname}..."
                run_cmd usermod --add-subgids 100000-165535 "${gname}" || \
                    { echo "${gname}:100000:65536" >> /etc/subgid; }
                ;;
            userns)
                log_info "Enabling user namespaces..."
                echo 'user.max_user_namespaces=15000' > /etc/sysctl.d/99-userns.conf
                run_cmd sysctl --system
                ;;
            python3)
                case "${OS_FAMILY:-}" in
                    rhel)   pkg_install python3 ;;
                    debian) pkg_install python3 ;;
                    *)      die "Cannot auto-install python3 on this OS." ;;
                esac
                ;;
            curl)
                case "${OS_FAMILY:-}" in
                    rhel)   pkg_install curl ;;
                    debian) pkg_install curl ;;
                esac
                ;;
            selinux:*)
                local bool="${item#selinux:}"
                run_cmd setsebool -P "${bool}" 1
                ;;
        esac
    done
}

# =============================================================================
# TARGET: build-host
# =============================================================================
check_build_host() {
    log_step "Build Host — Apptainer SIF Image Build Prerequisites"

    detect_os

    # ---- Apptainer (build requires local Apptainer, not just worker) ----
    log_step "  Apptainer Build Toolchain"
    if command -v apptainer &>/dev/null; then
        local ap_ver
        ap_ver=$(apptainer version 2>/dev/null | grep -oE '[0-9]+\.[0-9]+\.[0-9]+' | head -1)
        check_pass "Apptainer ${ap_ver} found"
        # 1.1+ ships squashfs-tools-ng for SIF building
        if [[ "$(printf '%s\n' "1.1.0" "${ap_ver}" | sort -V | head -1)" != "1.1.0" ]]; then
            check_warn "Apptainer ${ap_ver} < 1.1 — upgrade for reliable SIF builds"
        fi
    else
        check_fail "Apptainer not found — required to build SIF images"
        need "apptainer"
    fi

    # ---- Build tooling ----
    for cmd in curl wget git squashfs-tools mksquashfs; do
        # squashfs-tools and mksquashfs are checked as one item
        if [[ "${cmd}" == "squashfs-tools" ]]; then
            if command -v mksquashfs &>/dev/null; then
                check_pass "squashfs-tools: mksquashfs found"
            else
                check_warn "mksquashfs not found — Apptainer may provide its own squashfs but installing is safer"
                need "squashfs-tools"
            fi
            continue
        fi
        [[ "${cmd}" == "mksquashfs" ]] && continue
        if command -v "${cmd}" &>/dev/null; then
            check_pass "Build tool found: ${cmd}"
        else
            check_fail "Build tool missing: ${cmd}"
            need "${cmd}"
        fi
    done

    # ---- FUSE / OverlayFS (required for unprivileged builds) ----
    log_step "  FUSE and OverlayFS kernel modules"
    check_kmod fuse
    check_kmod overlay
    check_kmod squashfs

    # User namespace support
    local max_userns
    max_userns=$(sysctl -n user.max_user_namespaces 2>/dev/null || echo "0")
    if [[ "${max_userns}" -gt 0 ]]; then
        check_pass "user.max_user_namespaces=${max_userns}"
    else
        check_fail "user.max_user_namespaces=0 — unprivileged Apptainer builds require user namespaces"
        need "userns"
    fi

    # ---- Disk space (SIF build requires large /tmp and output space) ----
    log_step "  Disk Space"
    check_disk /tmp 50 "/tmp (Apptainer build sandbox — needs 50+ GB)"
    local build_dest="${STROMA_SHARED_ROOT:-/share}"
    if [[ -d "${build_dest}" ]]; then
        check_disk "${build_dest}" 30 "${build_dest} (SIF output destination)"
    else
        check_warn "${build_dest} not found — SIF output directory; set STROMA_SHARED_ROOT or ensure target has space"
    fi
    check_disk / 10 "Root filesystem (build metadata)"

    # ---- Network connectivity to required registries ----
    log_step "  Network Connectivity (container image sources)"
    check_url "https://nvcr.io"  "NVIDIA NGC container registry (nvcr.io)"
    check_url "https://ghcr.io"  "GitHub Container Registry (ghcr.io)"
    check_url "https://github.com" "GitHub (Apptainer releases)"
    check_url "https://pypi.org/simple/" "PyPI (Python package index)"

    # ---- Python (for realm-json and config patches in build pipelines) ----
    log_step "  Python"
    if python3 --version &>/dev/null; then
        local py_ver
        py_ver=$(python3 -c "import sys; print(f'{sys.version_info.major}.{sys.version_info.minor}')")
        check_pass "Python ${py_ver} found"
    else
        check_warn "python3 not found — some build helper scripts require it"
        need "python3"
    fi
}

install_build_host() {
    log_step "Installing missing build-host dependencies"

    for item in "${NEEDS_INSTALL[@]}"; do
        case "${item}" in
            apptainer)
                install_apptainer
                configure_apptainer
                ;;
            squashfs-tools)
                case "${OS_FAMILY:-}" in
                    rhel)   pkg_install squashfs-tools ;;
                    debian) pkg_install squashfs-tools ;;
                esac
                ;;
            curl)
                case "${OS_FAMILY:-}" in
                    rhel)   pkg_install curl ;;
                    debian) pkg_install curl ;;
                esac
                ;;
            wget)
                case "${OS_FAMILY:-}" in
                    rhel)   pkg_install wget ;;
                    debian) pkg_install wget ;;
                esac
                ;;
            git)
                case "${OS_FAMILY:-}" in
                    rhel)   pkg_install git ;;
                    debian) pkg_install git ;;
                esac
                ;;
            userns)
                echo 'user.max_user_namespaces=15000' > /etc/sysctl.d/99-userns.conf
                run_cmd sysctl --system
                ;;
            python3)
                case "${OS_FAMILY:-}" in
                    rhel)   pkg_install python3 ;;
                    debian) pkg_install python3 ;;
                esac
                ;;
        esac
    done
}

# =============================================================================
# Summary printer
# =============================================================================
print_summary() {
    local target="$1"
    echo ""
    echo -e "${BOLD}──────────────────────────────────────────────────────${RESET}"
    echo -e "${BOLD}Container Preflight Summary — target: ${target}${RESET}"
    echo -e "${BOLD}──────────────────────────────────────────────────────${RESET}"
    echo -e "  ${GREEN}Passed  : ${PASS_COUNT}${RESET}"
    echo -e "  ${YELLOW}Warnings: ${WARN_COUNT}${RESET}"
    echo -e "  ${RED}Failures: ${FAIL_COUNT}${RESET}"
    echo ""

    if [[ "${#NEEDS_INSTALL[@]}" -gt 0 ]] && [[ "${DO_INSTALL}" -eq 0 ]]; then
        echo -e "${YELLOW}Missing dependencies detected. Re-run with --install to fix them automatically:${RESET}"
        for item in "${NEEDS_INSTALL[@]}"; do
            echo -e "  ${YELLOW}→${RESET} ${item}"
        done
        echo ""
    fi
}

# =============================================================================
# Run a single target
# =============================================================================
run_target() {
    local t="$1"
    PASS_COUNT=0; WARN_COUNT=0; FAIL_COUNT=0; NEEDS_INSTALL=()

    echo ""
    echo -e "${BOLD}╔══════════════════════════════════════════════════════╗${RESET}"
    printf "${BOLD}║  StromaAI Container Preflight — %-20s ║${RESET}\n" "${t}"
    echo -e "${BOLD}╚══════════════════════════════════════════════════════╝${RESET}"

    case "${t}" in
        apptainer-worker) check_apptainer_worker ;;
        compose-host)     check_compose_host ;;
        build-host)       check_build_host ;;
        *) die "Unknown target: ${t}. Valid targets: apptainer-worker, compose-host, build-host, all" ;;
    esac

    print_summary "${t}"

    if [[ "${DO_INSTALL}" -eq 1 && "${#NEEDS_INSTALL[@]}" -gt 0 ]]; then
        if [[ "${FAIL_COUNT}" -eq 0 && "${#NEEDS_INSTALL[@]}" -eq 0 ]]; then
            log_ok "Nothing to install."
        else
            confirm "Install ${#NEEDS_INSTALL[@]} missing dependencies for ${t}?" || {
                log_warn "Skipping install for ${t} (user declined)."
                return 0
            }
            # Refresh OS detection for installers
            detect_os 2>/dev/null || true
            pkg_update
            case "${t}" in
                apptainer-worker) install_apptainer_worker ;;
                compose-host)     install_compose_host ;;
                build-host)       install_build_host ;;
            esac
            log_ok "Install phase complete for ${t}."
        fi
    fi

    if [[ "${FAIL_COUNT}" -gt 0 ]]; then
        return 1
    fi
    return 0
}

# =============================================================================
# Main
# =============================================================================
main() {
    local overall_rc=0

    if [[ "${TARGET}" == "all" ]]; then
        for t in apptainer-worker compose-host build-host; do
            run_target "${t}" || overall_rc=1
        done
    else
        run_target "${TARGET}" || overall_rc=1
    fi

    if [[ "${overall_rc}" -ne 0 ]]; then
        echo ""
        log_error "One or more blocking failures found. Resolve them and re-run."
        exit 1
    else
        echo ""
        log_ok "Container preflight complete. All checks passed or warnings only."
        exit 0
    fi
}

main
