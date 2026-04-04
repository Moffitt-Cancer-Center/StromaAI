#!/usr/bin/env bash
# =============================================================================
# StromaAI — Pre-flight checks
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
_show_usage() {
    cat <<EOF
Usage: sudo $0 [--mode=head|worker|ood] [--check-permissions] [--fix]

Modes:
  head    Check head node prerequisites (Python, nginx, ports, TLS)
  worker  Check Slurm worker prerequisites (GPU, Apptainer, shared FS)
  ood     Check Open OnDemand node prerequisites
  all     Run all checks (default)

Options:
  --check-permissions  Verify file ownership and permissions for all StromaAI components
  --fix                Automatically fix permission issues (implies --check-permissions)
EOF
}

MODE="all"
CHECK_PERMS=0
FIX_PERMS=0
for arg in "$@"; do
    case "${arg}" in
        --mode=*) MODE="${arg#*=}" ;;
        --check-permissions) CHECK_PERMS=1 ;;
        --fix) CHECK_PERMS=1; FIX_PERMS=1 ;;
        --help|-h) _show_usage; exit 0 ;;
        *) log_warn "Unknown argument: ${arg}" ;;
    esac
done

# ---------------------------------------------------------------------------
# Detect installation directory
# ---------------------------------------------------------------------------
REPO_DIR="$(cd "${SCRIPT_DIR}/.." && pwd)"

# Delegates to _resolve_install_dir from install/lib/common.sh.
# Sets STROMA_INSTALL_DIR, STROMA_VENV, STROMA_LOG_DIR, etc.
_resolve_install_dir

# Show what was detected (helps with debugging)
if [[ -f "${STROMA_INSTALL_DIR}/config.env" ]]; then
    log_info "Detected installation: ${STROMA_INSTALL_DIR}"
else
    log_info "Installation directory (default): ${STROMA_INSTALL_DIR}"
fi

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

    # Root — required for --fix and full system checks; optional for read-only
    # permission verification (--check-permissions without --fix) which can be
    # run as the 'stromaai' service account itself.
    if [[ ${EUID} -eq 0 ]]; then
        check_pass "Running as root"
    elif [[ "${FIX_PERMS}" -eq 1 ]]; then
        check_fail "Not running as root — --fix requires sudo"
    elif [[ "${CHECK_PERMS}" -eq 1 && "$(id -un)" == "stromaai" ]]; then
        check_pass "Running as stromaai (read-only permission check)"
    else
        check_warn "Not running as root — some checks may be limited (use sudo for full verification)"
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

    # Disk space on installation parent directory (not hardcoded /opt)
    local install_parent=$(dirname "${STROMA_INSTALL_DIR}")
    local parent_free_gb
    parent_free_gb=$(df -BG "${install_parent}" 2>/dev/null | awk 'NR==2 {gsub(/G/,""); print $4}')
    if [[ "${parent_free_gb:-0}" -ge 50 ]]; then
        check_pass "${install_parent} free space: ${parent_free_gb} GB"
    elif [[ "${parent_free_gb:-0}" -ge 20 ]]; then
        check_warn "${install_parent} free space: ${parent_free_gb} GB (recommend 50+ GB for vLLM venv)"
    else
        check_fail "${install_parent} free space: ${parent_free_gb} GB — vLLM install may fail (need 50+ GB)"
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
    local ray_port="${STROMA_RAY_PORT:-6380}"
    if ! ss -tlnp 2>/dev/null | grep -q ":${ray_port} "; then
        check_pass "Port ${ray_port} (Ray GCS) is available"
    else
        check_warn "Port ${ray_port} is already in use"
    fi

    # TLS certificate path
    if [[ -f /etc/ssl/stroma-ai/server.crt && -f /etc/ssl/stroma-ai/server.key ]]; then
        local expiry
        expiry=$(openssl x509 -enddate -noout -in /etc/ssl/stroma-ai/server.crt 2>/dev/null | cut -d= -f2)
        check_pass "TLS certificate found (expires: ${expiry})"
    else
        check_warn "TLS certificate not found at /etc/ssl/stroma-ai/ — installer will generate a self-signed cert"
    fi

    # Shared filesystem (for model weights)
    local shared_root="${STROMA_SHARED_ROOT:-/share}"
    if detect_shared_fs "${shared_root}" 2>/dev/null; then
        check_pass "Shared filesystem mounted at ${shared_root}"
    else
        check_warn "No filesystem mounted at ${shared_root} — set STROMA_SHARED_ROOT in config and verify mount"
    fi

    # RAM recommendation (head node needs RAM for CPU KV cache offload)
    detect_ram 2>/dev/null
    if [[ "${TOTAL_RAM_GB:-0}" -ge 128 ]]; then
        check_pass "Total RAM: ${TOTAL_RAM_GB} GB"
    else
        check_warn "Total RAM: ${TOTAL_RAM_GB} GB (recommend 256+ GB for CPU KV cache offload)"
    fi

    # stromaai user
    if id stromaai &>/dev/null; then
        check_pass "System user 'stromaai' exists"
    else
        check_warn "System user 'stromaai' not found — installer will create it"
    fi

    # Install directory
    local install_dir="${STROMA_INSTALL_DIR}"
    if [[ -d "${install_dir}" ]]; then
        check_pass "${install_dir} directory exists"
    else
        check_warn "${install_dir} not found — installer will create it"
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
    local shared_root="${STROMA_SHARED_ROOT:-/share}"
    if detect_shared_fs "${shared_root}" 2>/dev/null; then
        local shared_free_gb
        shared_free_gb=$(df -BG "${shared_root}" 2>/dev/null | awk 'NR==2 {gsub(/G/,""); print $4}')
        check_pass "Shared filesystem mounted at ${shared_root} (${shared_free_gb} GB free)"
    else
        check_fail "No filesystem mounted at ${shared_root} — set STROMA_SHARED_ROOT and verify NFS/GPFS mount"
    fi

    # Container image
    local sif_path="${STROMA_CONTAINER:-/share/containers/stroma-ai-vllm.sif}"
    if [[ -f "${sif_path}" ]]; then
        local sif_size_gb
        sif_size_gb=$(du -BG "${sif_path}" 2>/dev/null | awk '{gsub(/G/,""); print $1}')
        check_pass "Container image found: ${sif_path} (${sif_size_gb} GB)"
    else
        check_warn "Container image not found at ${sif_path} — build it before first use"
    fi

    # Model weights
    local model_path="${STROMA_MODEL_PATH:-/share/models/Qwen2.5-Coder-32B-Instruct-AWQ}"
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

    # StromaAI OOD config
    if [[ -f /etc/ood/stroma-ai.conf ]]; then
        check_pass "StromaAI OOD config found: /etc/ood/stroma-ai.conf"
    else
        check_warn "StromaAI OOD config not found — installer will create it"
    fi

    # Connectivity to head node
    local head="${STROMA_HEAD_HOST:-stroma-ai.your-cluster.example}"
    local port="${STROMA_HTTPS_PORT:-443}"
    if [[ "${head}" != *"example"* ]]; then
        if curl -fsS --max-time 5 --insecure "https://${head}:${port}/health" &>/dev/null; then
            check_pass "StromaAI API reachable at https://${head}:${port}"
        else
            check_warn "Cannot reach StromaAI API at https://${head}:${port} — check hostname and firewall"
        fi
    else
        check_warn "STROMA_HEAD_HOST not set — skipping API connectivity test"
    fi
}

# ---------------------------------------------------------------------------
# _stromaai_test FLAG PATH
# Test a file/directory attribute as the stromaai user without requiring
# stromaai to be in sudoers.
#   - Running as root        → sudo -u stromaai test FLAG PATH
#   - Running as stromaai    → test FLAG PATH  (no sudo needed)
#   - Running as other user  → su -s /bin/sh stromaai -c "test FLAG PATH"
# ---------------------------------------------------------------------------
_stromaai_test() {
    local flag="$1" path="$2"
    if [[ "$(id -u)" -eq 0 ]]; then
        sudo -u stromaai test "${flag}" "${path}" 2>/dev/null
    elif [[ "$(id -un)" == "stromaai" ]]; then
        test "${flag}" "${path}"
    else
        su -s /bin/sh stromaai -c "test ${flag} '${path}'" 2>/dev/null
    fi
}

# ---------------------------------------------------------------------------
# Permissions checks (post-install verification)
# ---------------------------------------------------------------------------
check_permissions() {
    log_step "Permissions verification"
    
    if [[ "${FIX_PERMS}" -eq 1 ]]; then
        log_info "Fix mode enabled — will attempt to correct permission issues"
    fi

    local install_dir="${STROMA_INSTALL_DIR}"
    local config_file="${install_dir}/config.env"
    local shared_root="${STROMA_SHARED_ROOT:-/share}"
    local model_path="${STROMA_MODEL_PATH:-${shared_root}/models/Qwen2.5-Coder-32B-Instruct-AWQ}"
    local container_path="${STROMA_CONTAINER:-${shared_root}/containers/stroma-ai-vllm.sif}"
    local log_dir="${STROMA_LOG_DIR:-${install_dir}/logs}"
    local state_dir="${install_dir}/state"
    
    # Check stromaai user exists
    if ! id stromaai &>/dev/null; then
        check_fail "User 'stromaai' does not exist — run install.sh first"
        return
    fi
    
    # 1. Installation directory
    if [[ -d "${install_dir}" ]]; then
        local owner=$(stat -c '%U:%G' "${install_dir}" 2>/dev/null || stat -f '%Su:%Sg' "${install_dir}" 2>/dev/null)
        local perms=$(stat -c '%a' "${install_dir}" 2>/dev/null || stat -f '%A' "${install_dir}" 2>/dev/null | tail -c 4)
        if [[ "${owner}" == "stromaai:stromaai" ]]; then
            check_pass "${install_dir} ownership: ${owner}"
        else
            if [[ "${FIX_PERMS}" -eq 1 ]]; then
                log_info "Fixing ${install_dir} ownership: ${owner} → stromaai:stromaai"
                if _needs_chown "${install_dir}" stromaai stromaai; then
                    chown -R stromaai:stromaai "${install_dir}"
                fi
                check_pass "${install_dir} ownership: FIXED"
            else
                check_fail "${install_dir} ownership: ${owner} (expected stromaai:stromaai)"
            fi
        fi
        check_pass "${install_dir} permissions: ${perms}"
    else
        check_warn "${install_dir} does not exist — run install.sh"
    fi
    
    # 2. Config file (sensitive: 640)
    if [[ -f "${config_file}" ]]; then
        local owner=$(stat -c '%U:%G' "${config_file}" 2>/dev/null || stat -f '%Su:%Sg' "${config_file}" 2>/dev/null)
        local perms=$(stat -c '%a' "${config_file}" 2>/dev/null || stat -f '%A' "${config_file}" 2>/dev/null | tail -c 4)
        if [[ "${owner}" == "stromaai:stromaai" ]]; then
            check_pass "${config_file} ownership: ${owner}"
        else
            if [[ "${FIX_PERMS}" -eq 1 ]]; then
                log_info "Fixing ${config_file} ownership: ${owner} → stromaai:stromaai"
                chown stromaai:stromaai "${config_file}"
                check_pass "${config_file} ownership: FIXED"
            else
                check_fail "${config_file} ownership: ${owner} (expected stromaai:stromaai)"
            fi
        fi
        if [[ "${perms}" == "640" || "${perms}" == "0640" ]]; then
            check_pass "${config_file} permissions: ${perms}"
        else
            if [[ "${FIX_PERMS}" -eq 1 ]]; then
                log_info "Fixing ${config_file} permissions: ${perms} → 640"
                chmod 640 "${config_file}"
                check_pass "${config_file} permissions: FIXED"
            else
                check_fail "${config_file} permissions: ${perms} (expected 640 — contains secrets)"
            fi
        fi
    else
        check_warn "${config_file} does not exist"
    fi
    
    # 3. Systemd service files (must be root-owned, world-readable)
    for svc in ray-head.service stroma-ai-vllm.service stroma-ai-watcher.service; do
        local svc_path="/etc/systemd/system/${svc}"
        if [[ -f "${svc_path}" ]]; then
            local owner=$(stat -c '%U:%G' "${svc_path}" 2>/dev/null || stat -f '%Su:%Sg' "${svc_path}" 2>/dev/null)
            local perms=$(stat -c '%a' "${svc_path}" 2>/dev/null || stat -f '%A' "${svc_path}" 2>/dev/null | tail -c 4)
            if [[ "${owner}" == "root:root" ]]; then
                check_pass "${svc_path} ownership: ${owner}"
            else
                if [[ "${FIX_PERMS}" -eq 1 ]]; then
                    log_info "Fixing ${svc_path} ownership: ${owner} → root:root"
                    chown root:root "${svc_path}"
                    check_pass "${svc_path} ownership: FIXED"
                else
                    check_fail "${svc_path} ownership: ${owner} (expected root:root)"
                fi
            fi
            if [[ "${perms}" == "644" || "${perms}" == "0644" ]]; then
                check_pass "${svc_path} permissions: ${perms}"
            else
                if [[ "${FIX_PERMS}" -eq 1 ]]; then
                    log_info "Fixing ${svc_path} permissions: ${perms} → 644"
                    chmod 644 "${svc_path}"
                    check_pass "${svc_path} permissions: FIXED"
                else
                    check_warn "${svc_path} permissions: ${perms} (expected 644)"
                fi
            fi
        else
            check_warn "${svc_path} not found — service not installed"
        fi
    done
    
    # 4. Venv directory (stromaai needs write access for pip)
    local venv_dir="${install_dir}/venv"
    if [[ -d "${venv_dir}" ]]; then
        local owner=$(stat -c '%U:%G' "${venv_dir}" 2>/dev/null || stat -f '%Su:%Sg' "${venv_dir}" 2>/dev/null)
        if [[ "${owner}" == "stromaai:stromaai" ]]; then
            check_pass "${venv_dir} ownership: ${owner}"
        else
            if [[ "${FIX_PERMS}" -eq 1 ]]; then
                log_info "Fixing ${venv_dir} ownership: ${owner} → stromaai:stromaai"
                if _needs_chown "${venv_dir}" stromaai stromaai; then
                    chown -R stromaai:stromaai "${venv_dir}"
                fi
                check_pass "${venv_dir} ownership: FIXED"
            else
                check_fail "${venv_dir} ownership: ${owner} (expected stromaai:stromaai)"
            fi
        fi
        
        # Test write access by stromaai user
        if _stromaai_test -w "${venv_dir}"; then
            check_pass "${venv_dir} writable by stromaai user"
        else
            if [[ "${FIX_PERMS}" -eq 1 ]]; then
                log_info "Fixing ${venv_dir} write access"
                if _needs_chown "${venv_dir}" stromaai stromaai; then
                    chown -R stromaai:stromaai "${venv_dir}"
                fi
                chmod -R u+w "${venv_dir}"
                check_pass "${venv_dir} write access: FIXED"
            else
                check_fail "${venv_dir} NOT writable by stromaai user"
            fi
        fi
    else
        check_warn "${venv_dir} does not exist"
    fi
    
    # 5. Source files
    for src_file in src/gateway.py src/vllm_watcher.py src/cluster_manager.py src/stroma_cli.py; do
        local file_path="${install_dir}/${src_file}"
        if [[ -f "${file_path}" ]]; then
            if _stromaai_test -r "${file_path}"; then
                check_pass "${file_path} readable by stromaai user"
            else
                if [[ "${FIX_PERMS}" -eq 1 ]]; then
                    log_info "Fixing ${file_path} read access"
                    chown stromaai:stromaai "${file_path}"
                    chmod u+r "${file_path}"
                    check_pass "${file_path} read access: FIXED"
                else
                    check_fail "${file_path} NOT readable by stromaai user"
                fi
            fi
        fi
    done
    
    # 6. Log directory (stromaai needs write access)
    if [[ -d "${log_dir}" ]]; then
        local owner=$(stat -c '%U:%G' "${log_dir}" 2>/dev/null || stat -f '%Su:%Sg' "${log_dir}" 2>/dev/null)
        if [[ "${owner}" == "stromaai:stromaai" || "${owner}" =~ ^stromaai: ]]; then
            check_pass "${log_dir} ownership: ${owner}"
        else
            if [[ "${FIX_PERMS}" -eq 1 ]]; then
                log_info "Fixing ${log_dir} ownership: ${owner} → stromaai:stromaai"
                if _needs_chown "${log_dir}" stromaai stromaai; then
                    chown -R stromaai:stromaai "${log_dir}"
                fi
                check_pass "${log_dir} ownership: FIXED"
            else
                check_warn "${log_dir} ownership: ${owner} (expected stromaai:stromaai)"
            fi
        fi
        
        if _stromaai_test -w "${log_dir}"; then
            check_pass "${log_dir} writable by stromaai user"
        else
            if [[ "${FIX_PERMS}" -eq 1 ]]; then
                log_info "Fixing ${log_dir} write access"
                if _needs_chown "${log_dir}" stromaai stromaai; then
                    chown -R stromaai:stromaai "${log_dir}"
                fi
                chmod -R u+w "${log_dir}"
                check_pass "${log_dir} write access: FIXED"
            else
                check_fail "${log_dir} NOT writable by stromaai user — Slurm job logs will fail"
            fi
        fi
    else
        if [[ "${FIX_PERMS}" -eq 1 ]]; then
            log_info "Creating ${log_dir}"
            mkdir -p "${log_dir}"
            chown stromaai:stromaai "${log_dir}"
            chmod 755 "${log_dir}"
            check_pass "${log_dir}: CREATED"
        else
            check_warn "${log_dir} does not exist — will be created on first Slurm job"
        fi
    fi
    
    # 7. State directory (watcher persistence)
    if [[ -d "${state_dir}" ]]; then
        if _stromaai_test -w "${state_dir}"; then
            check_pass "${state_dir} writable by stromaai user"
        else
            if [[ "${FIX_PERMS}" -eq 1 ]]; then
                log_info "Fixing ${state_dir} write access"
                if _needs_chown "${state_dir}" stromaai stromaai; then
                    chown -R stromaai:stromaai "${state_dir}"
                fi
                chmod -R u+w "${state_dir}"
                check_pass "${state_dir} write access: FIXED"
            else
                check_fail "${state_dir} NOT writable by stromaai user — watcher state persistence will fail"
            fi
        fi
    else
        if [[ "${FIX_PERMS}" -eq 1 ]]; then
            log_info "Creating ${state_dir}"
            mkdir -p "${state_dir}"
            chown stromaai:stromaai "${state_dir}"
            chmod 755 "${state_dir}"
            check_pass "${state_dir}: CREATED"
        else
            check_warn "${state_dir} does not exist — will be created on first watcher run"
        fi
    fi
    
    # 8. Model weights (read access required)
    if [[ -d "${model_path}" ]]; then
        if _stromaai_test -r "${model_path}"; then
            check_pass "${model_path} readable by stromaai user"
        else
            if [[ "${FIX_PERMS}" -eq 1 ]]; then
                log_info "Fixing ${model_path} read access"
                chmod -R o+rX "${model_path}"
                check_pass "${model_path} read access: FIXED"
            else
                check_fail "${model_path} NOT readable by stromaai user — vLLM will fail to load model"
            fi
        fi
        
        # Check specific model files
        local have_config=0
        for cfg in config.json model.safetensors.index.json; do
            if [[ -f "${model_path}/${cfg}" ]]; then
                if _stromaai_test -r "${model_path}/${cfg}"; then
                    have_config=1
                else
                    if [[ "${FIX_PERMS}" -eq 1 ]]; then
                        log_info "Fixing ${model_path}/${cfg} read access"
                        chmod o+r "${model_path}/${cfg}"
                        have_config=1
                    else
                        check_fail "${model_path}/${cfg} NOT readable by stromaai user"
                    fi
                fi
            fi
        done
        [[ "${have_config}" -eq 1 ]] && check_pass "${model_path} contains readable model config files"
    else
        check_warn "${model_path} does not exist — download model before starting vLLM"
    fi
    
    # 9. Container image (read access required)
    if [[ -f "${container_path}" ]]; then
        if _stromaai_test -r "${container_path}"; then
            check_pass "${container_path} readable by stromaai user"
        else
            if [[ "${FIX_PERMS}" -eq 1 ]]; then
                log_info "Fixing ${container_path} read access"
                chmod o+r "${container_path}"
                check_pass "${container_path} read access: FIXED"
            else
                check_fail "${container_path} NOT readable by stromaai user — Slurm jobs will fail"
            fi
        fi
    else
        check_warn "${container_path} does not exist — build container before submitting Slurm jobs"
    fi
    
    # 10. Shared storage mount point (general access)
    if [[ -d "${shared_root}" ]]; then
        if _stromaai_test -r "${shared_root}"; then
            check_pass "${shared_root} readable by stromaai user"
        else
            check_warn "${shared_root} NOT readable by stromaai user — shared storage may not be mounted (cannot fix mount issues)"
        fi
    else
        check_warn "${shared_root} does not exist — verify NFS/GPFS mount"
    fi
    
    # 11. Ray temp directories (/tmp/ray must be writable)
    local ray_tmp="/tmp/ray"
    if [[ -d "${ray_tmp}" ]]; then
        local owner=$(stat -c '%U:%G' "${ray_tmp}" 2>/dev/null || stat -f '%Su:%Sg' "${ray_tmp}" 2>/dev/null)
        if [[ "${owner}" =~ ^stromaai: ]]; then
            check_pass "${ray_tmp} ownership: ${owner}"
        else
            if [[ "${FIX_PERMS}" -eq 1 ]]; then
                log_info "Fixing ${ray_tmp} ownership: ${owner} → stromaai:stromaai"
                if _needs_chown "${ray_tmp}" stromaai stromaai; then
                    chown -R stromaai:stromaai "${ray_tmp}"
                fi
                check_pass "${ray_tmp} ownership: FIXED"
            else
                check_warn "${ray_tmp} ownership: ${owner} (expected stromaai:stromaai)"
            fi
        fi
        
        if _stromaai_test -w "${ray_tmp}"; then
            check_pass "${ray_tmp} writable by stromaai user"
        else
            if [[ "${FIX_PERMS}" -eq 1 ]]; then
                log_info "Fixing ${ray_tmp} write access"
                if _needs_chown "${ray_tmp}" stromaai stromaai; then
                    chown -R stromaai:stromaai "${ray_tmp}"
                fi
                chmod -R u+w "${ray_tmp}"
                check_pass "${ray_tmp} write access: FIXED"
            else
                check_fail "${ray_tmp} NOT writable by stromaai user — Ray will fail to start"
            fi
        fi
    else
        check_warn "${ray_tmp} does not exist — will be created on first Ray start"
    fi
    
    # 12. TLS certificates (nginx needs read access, but runs as root)
    local tls_cert="/etc/ssl/stroma-ai/server.crt"
    local tls_key="/etc/ssl/stroma-ai/server.key"
    if [[ -f "${tls_cert}" && -f "${tls_key}" ]]; then
        local key_perms=$(stat -c '%a' "${tls_key}" 2>/dev/null || stat -f '%A' "${tls_key}" 2>/dev/null | tail -c 4)
        if [[ "${key_perms}" == "600" || "${key_perms}" == "0600" ]]; then
            check_pass "${tls_key} permissions: ${key_perms} (secure)"
        else
            if [[ "${FIX_PERMS}" -eq 1 ]]; then
                log_info "Fixing ${tls_key} permissions: ${key_perms} → 600"
                chmod 600 "${tls_key}"
                check_pass "${tls_key} permissions: FIXED"
            else
                check_warn "${tls_key} permissions: ${key_perms} (recommend 600 for private key)"
            fi
        fi
        check_pass "${tls_cert} exists and readable"
    else
        check_warn "TLS certificate not found at /etc/ssl/stroma-ai/"
    fi
    
    # 13. Docker/Podman socket (for compose on head node)
    if [[ -S /var/run/docker.sock ]]; then
        if groups stromaai 2>/dev/null | grep -q docker; then
            check_pass "stromaai user is in 'docker' group"
        else
            if [[ "${FIX_PERMS}" -eq 1 ]]; then
                log_info "Adding stromaai user to 'docker' group"
                usermod -aG docker stromaai
                check_pass "stromaai user: ADDED to docker group (logout/login required)"
            else
                check_warn "stromaai user NOT in 'docker' group — docker compose may require sudo"
            fi
        fi
    fi
    
    # 14. Slurm batch script
    local slurm_script="${install_dir}/deploy/slurm/stroma_ai_worker.slurm"
    if [[ -f "${slurm_script}" ]]; then
        if _stromaai_test -r "${slurm_script}"; then
            check_pass "${slurm_script} readable by stromaai user"
        else
            if [[ "${FIX_PERMS}" -eq 1 ]]; then
                log_info "Fixing ${slurm_script} read access"
                chmod o+r "${slurm_script}"
                check_pass "${slurm_script} read access: FIXED"
            else
                check_fail "${slurm_script} NOT readable by stromaai user — watcher cannot submit jobs"
            fi
        fi
    else
        check_warn "${slurm_script} does not exist"
    fi
    
    if [[ "${FIX_PERMS}" -eq 1 ]]; then
        log_info "Fixes complete — verify services with: systemctl status ray-head stroma-ai-vllm stroma-ai-watcher"
    fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------
main() {
    echo ""
    echo -e "${BOLD}StromaAI Pre-flight Check${RESET}"
    echo -e "${BOLD}========================${RESET}"
    echo "Mode: ${MODE}"
    echo ""

    # Load remaining config vars (STROMA_INSTALL_DIR already locked in by
    # _resolve_install_dir above and cannot be overwritten by a stale value
    # inside config.env because _resolve_install_dir sets the guard variable
    # _STROMA_INSTALL_DIR_RESOLVED, preventing a second call).
    local config="${STROMA_INSTALL_DIR}/config.env"
    if [[ -f "${config}" ]]; then
        log_info "Loading config from ${config}"
        local _saved_install_dir="${STROMA_INSTALL_DIR}"
        # shellcheck disable=SC1090
        set -a
        source "${config}" 2>/dev/null || true
        set +a
        # Restore: never let config.env clobber the detected install dir
        export STROMA_INSTALL_DIR="${_saved_install_dir}"
    fi

    check_common

    # Permissions check (can run standalone or with mode checks)
    if [[ "${CHECK_PERMS}" -eq 1 ]]; then
        check_permissions
    fi

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
