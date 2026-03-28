#!/usr/bin/env bash
# =============================================================================
# AI_Flux — Pre-flight checks
# =============================================================================
# Run this BEFORE install.sh to verify the system meets requirements.
# Safe to run on head nodes, worker nodes, or OOD nodes.
#
# Usage:
#   sudo ./install/preflight.sh [--mode=head|worker|ood]
#
# Exit codes:
#   0 — all checks passed (or warnings only)
#   1 — one or more blocking failures
# =============================================================================

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=install/lib/common.sh
source "${SCRIPT_DIR}/lib/common.sh"
# shellcheck source=install/lib/detect.sh
source "${SCRIPT_DIR}/lib/detect.sh"

# ---------------------------------------------------------------------------
# Parse arguments
# ---------------------------------------------------------------------------
MODE="all"
for arg in "$@"; do
    case "${arg}" in
        --mode=*) MODE="${arg#*=}" ;;
        --help|-h) _show_usage; exit 0 ;;
        *) log_warn "Unknown argument: ${arg}" ;;
    esac
done

_show_usage() {
    cat <<EOF
Usage: sudo $0 [--mode=head|worker|ood]

Modes:
  head    Check head node prerequisites (Python, nginx, ports, TLS)
  worker  Check Slurm worker prerequisites (GPU, Apptainer, shared FS)
  ood     Check Open OnDemand node prerequisites
  all     Run all checks (default)
EOF
}

# ---------------------------------------------------------------------------
# Check tracking
# ---------------------------------------------------------------------------
PASS_COUNT=0
WARN_COUNT=0
FAIL_COUNT=0

check_pass() { log_ok   "$1"; (( PASS_COUNT++ )) || true; }
check_warn() { log_warn "$1"; (( WARN_COUNT++ )) || true; }
check_fail() { log_error "$1"; (( FAIL_COUNT++ )) || true; }

# ---------------------------------------------------------------------------
# Common checks (all modes)
# ---------------------------------------------------------------------------
check_common() {
    log_step "Common checks"

    # Root
    if [[ ${EUID} -eq 0 ]]; then
        check_pass "Running as root"
    else
        check_fail "Not running as root — run with sudo"
    fi

    # OS detection
    detect_os 2>/dev/null && check_pass "OS: ${OS_PRETTY}" \
        || check_fail "Could not detect OS from /etc/os-release"

    # systemd
    if systemctl is-system-running &>/dev/null || systemctl status &>/dev/null; then
        check_pass "systemd is running"
    else
        check_warn "systemd may not be running (container environment?)"
    fi

    # Internet connectivity (warn only — may be air-gapped)
    if curl -fsS --max-time 5 https://pypi.org/simple/ &>/dev/null; then
        check_pass "Internet connectivity: reachable"
    else
        check_warn "No internet connectivity — ensure packages are available via local mirror or pre-downloaded."
    fi

    # Disk space on /opt
    local opt_free_gb
    opt_free_gb=$(df -BG /opt 2>/dev/null | awk 'NR==2 {gsub(/G/,""); print $4}')
    if [[ "${opt_free_gb:-0}" -ge 50 ]]; then
        check_pass "/opt free space: ${opt_free_gb} GB"
    elif [[ "${opt_free_gb:-0}" -ge 20 ]]; then
        check_warn "/opt free space: ${opt_free_gb} GB (recommend 50+ GB for vLLM venv)"
    else
        check_fail "/opt free space: ${opt_free_gb} GB — vLLM install may fail (need 50+ GB)"
    fi
}

# ---------------------------------------------------------------------------
# Head node checks
# ---------------------------------------------------------------------------
check_head() {
    log_step "Head node checks"

    # Python 3.11+
    if detect_python311 2>/dev/null && [[ -n "${PYTHON311:-}" ]]; then
        check_pass "Python 3.11+ found: ${PYTHON311}"
    else
        check_warn "Python 3.11+ not found — installer will install it"
    fi

    # nginx
    if check_cmd nginx; then
        check_pass "nginx found: $(nginx -v 2>&1)"
    else
        check_warn "nginx not found — installer will install it"
    fi

    # Port 443 availability
    if ! ss -tlnp 2>/dev/null | grep -q ':443 '; then
        check_pass "Port 443 is available"
    else
        check_warn "Port 443 is already in use — check for existing web server"
    fi

    # Port for Ray GCS
    local ray_port="${AI_FLUX_RAY_PORT:-6380}"
    if ! ss -tlnp 2>/dev/null | grep -q ":${ray_port} "; then
        check_pass "Port ${ray_port} (Ray GCS) is available"
    else
        check_warn "Port ${ray_port} is already in use"
    fi

    # TLS certificate path
    if [[ -f /etc/ssl/ai-flux/server.crt && -f /etc/ssl/ai-flux/server.key ]]; then
        local expiry
        expiry=$(openssl x509 -enddate -noout -in /etc/ssl/ai-flux/server.crt 2>/dev/null | cut -d= -f2)
        check_pass "TLS certificate found (expires: ${expiry})"
    else
        check_warn "TLS certificate not found at /etc/ssl/ai-flux/ — installer will generate a self-signed cert"
    fi

    # Shared filesystem (for model weights)
    if detect_shared_fs "/shared" 2>/dev/null; then
        check_pass "Shared filesystem mounted at /shared"
    else
        check_warn "No filesystem mounted at /shared — update AI_FLUX_MODEL_PATH in config"
    fi

    # RAM recommendation (head node needs RAM for CPU KV cache offload)
    detect_ram 2>/dev/null
    if [[ "${TOTAL_RAM_GB:-0}" -ge 128 ]]; then
        check_pass "Total RAM: ${TOTAL_RAM_GB} GB"
    else
        check_warn "Total RAM: ${TOTAL_RAM_GB} GB (recommend 256+ GB for CPU KV cache offload)"
    fi

    # aiflux user
    if id aiflux &>/dev/null; then
        check_pass "System user 'aiflux' exists"
    else
        check_warn "System user 'aiflux' not found — installer will create it"
    fi

    # /opt/ai-flux directory
    if [[ -d /opt/ai-flux ]]; then
        check_pass "/opt/ai-flux directory exists"
    else
        check_warn "/opt/ai-flux not found — installer will create it"
    fi
}

# ---------------------------------------------------------------------------
# Worker node checks
# ---------------------------------------------------------------------------
check_worker() {
    log_step "Worker node checks"

    # GPU
    detect_gpu 2>/dev/null
    if [[ "${HAS_GPU:-0}" -eq 1 ]]; then
        check_pass "GPU detected: ${GPU_COUNT}× ${GPU_MODEL}"
    else
        check_fail "No NVIDIA GPU detected (nvidia-smi not found or no GPUs)"
    fi

    # NVIDIA driver
    if check_cmd nvidia-smi; then
        local driver_ver
        driver_ver=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1)
        local major="${driver_ver%%.*}"
        if [[ "${major:-0}" -ge 525 ]]; then
            check_pass "NVIDIA driver: ${driver_ver}"
        else
            check_warn "NVIDIA driver ${driver_ver} is below 525 — FP8 KV cache requires 525+"
        fi
    fi

    # Container runtime
    detect_container_runtime 2>/dev/null || true
    if [[ -n "${CONTAINER_RUNTIME:-}" ]]; then
        check_pass "Container runtime: ${CONTAINER_RUNTIME}"
    else
        check_warn "Apptainer/Singularity not found — installer will install Apptainer"
    fi

    # Slurm
    if detect_slurm 2>/dev/null; then
        check_pass "Slurm commands available (sbatch, squeue)"
    else
        check_fail "Slurm not found — sbatch and squeue must be in PATH on worker nodes"
    fi

    # Shared filesystem
    if detect_shared_fs "/shared" 2>/dev/null; then
        local shared_free_gb
        shared_free_gb=$(df -BG /shared 2>/dev/null | awk 'NR==2 {gsub(/G/,""); print $4}')
        check_pass "Shared filesystem mounted at /shared (${shared_free_gb} GB free)"
    else
        check_fail "No filesystem mounted at /shared — worker nodes require access to shared storage"
    fi

    # Container image
    local sif_path="${AI_FLUX_CONTAINER:-/shared/containers/ai-flux-vllm.sif}"
    if [[ -f "${sif_path}" ]]; then
        local sif_size_gb
        sif_size_gb=$(du -BG "${sif_path}" 2>/dev/null | awk '{gsub(/G/,""); print $1}')
        check_pass "Container image found: ${sif_path} (${sif_size_gb} GB)"
    else
        check_warn "Container image not found at ${sif_path} — build it before first use"
    fi

    # Model weights
    local model_path="${AI_FLUX_MODEL_PATH:-/shared/models/Qwen2.5-Coder-32B-Instruct-AWQ}"
    if [[ -d "${model_path}" ]]; then
        check_pass "Model directory found: ${model_path}"
    else
        check_warn "Model directory not found at ${model_path} — download before first use"
    fi

    # SELinux
    detect_selinux 2>/dev/null || true
    if [[ "${SELINUX_STATUS:-}" == "Enforcing" ]]; then
        local bool_ok=1
        for b in container_use_cgroups container_manage_cgroup; do
            if ! getsebool "${b}" 2>/dev/null | grep -q "on$"; then
                check_warn "SELinux boolean ${b} is NOT set — Apptainer may fail to start"
                bool_ok=0
            fi
        done
        [[ "${bool_ok}" -eq 1 ]] && check_pass "SELinux booleans for Apptainer are set"
    fi

    # RAM
    detect_ram 2>/dev/null
    if [[ "${TOTAL_RAM_GB:-0}" -ge 512 ]]; then
        check_pass "Total RAM: ${TOTAL_RAM_GB} GB (good for CPU KV cache offload)"
    else
        check_warn "Total RAM: ${TOTAL_RAM_GB} GB (recommend 512+ GB for --cpu-offload-gb 200)"
    fi
}

# ---------------------------------------------------------------------------
# OOD node checks
# ---------------------------------------------------------------------------
check_ood() {
    log_step "OOD node checks"

    # OOD installation
    if [[ -d /etc/ood ]]; then
        check_pass "OOD configuration directory /etc/ood found"
    else
        check_fail "/etc/ood not found — is Open OnDemand installed?"
    fi

    # code-server in PATH or OOD bundled
    if check_cmd code-server; then
        check_pass "code-server found: $(code-server --version 2>/dev/null | head -1)"
    else
        check_warn "code-server not in PATH — may be launched by OOD"
    fi

    # AI_Flux OOD config
    if [[ -f /etc/ood/ai-flux.conf ]]; then
        check_pass "AI_Flux OOD config found: /etc/ood/ai-flux.conf"
    else
        check_warn "AI_Flux OOD config not found — installer will create it"
    fi

    # Connectivity to head node
    local head="${AI_FLUX_HEAD_HOST:-ai-flux.your-cluster.example}"
    local port="${AI_FLUX_HTTPS_PORT:-443}"
    if [[ "${head}" != *"example"* ]]; then
        if curl -fsS --max-time 5 --insecure "https://${head}:${port}/health" &>/dev/null; then
            check_pass "AI_Flux API reachable at https://${head}:${port}"
        else
            check_warn "Cannot reach AI_Flux API at https://${head}:${port} — check hostname and firewall"
        fi
    else
        check_warn "AI_FLUX_HEAD_HOST not set — skipping API connectivity test"
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    echo ""
    echo -e "${BOLD}AI_Flux Pre-flight Check${RESET}"
    echo -e "${BOLD}========================${RESET}"
    echo "Mode: ${MODE}"
    echo ""

    check_common

    case "${MODE}" in
        head)   check_head ;;
        worker) check_worker ;;
        ood)    check_ood ;;
        all)
            check_head
            check_worker
            check_ood
            ;;
        *)
            log_error "Unknown mode: ${MODE}. Use --mode=head|worker|ood|all"
            exit 1
            ;;
    esac

    echo ""
    echo -e "${BOLD}Results: ${GREEN}${PASS_COUNT} passed${RESET} | ${YELLOW}${WARN_COUNT} warnings${RESET} | ${RED}${FAIL_COUNT} failures${RESET}"
    echo ""

    if [[ "${FAIL_COUNT}" -gt 0 ]]; then
        log_error "Pre-flight check found ${FAIL_COUNT} blocking issue(s). Resolve before running install.sh."
        exit 1
    elif [[ "${WARN_COUNT}" -gt 0 ]]; then
        log_warn "Pre-flight check passed with ${WARN_COUNT} warning(s). Review before proceeding."
        exit 0
    else
        log_ok "All pre-flight checks passed. Ready to install."
        exit 0
    fi
}

main "$@"
