#!/usr/bin/env bash
# =============================================================================
# StromaAI — Common utilities for installer scripts
# =============================================================================
# Source this file from top-level installer scripts:
#   source "$(dirname "${BASH_SOURCE[0]}")/lib/common.sh"
# =============================================================================

# Guard against double-sourcing
[[ -n "${_STROMA_COMMON_LOADED:-}" ]] && return 0
readonly _STROMA_COMMON_LOADED=1

# ---------------------------------------------------------------------------
# Terminal colors (disabled if stdout is not a TTY)
# ---------------------------------------------------------------------------
if [[ -t 1 ]]; then
    RED='\033[0;31m'
    YELLOW='\033[1;33m'
    GREEN='\033[0;32m'
    CYAN='\033[0;36m'
    BOLD='\033[1m'
    RESET='\033[0m'
else
    RED='' YELLOW='' GREEN='' CYAN='' BOLD='' RESET=''
fi
readonly RED YELLOW GREEN CYAN BOLD RESET

# ---------------------------------------------------------------------------
# Logging helpers
# ---------------------------------------------------------------------------
log_info()    { echo -e "${CYAN}[INFO]${RESET}  $*"; }
log_ok()      { echo -e "${GREEN}[OK]${RESET}    $*"; }
log_warn()    { echo -e "${YELLOW}[WARN]${RESET}  $*" >&2; }
log_error()   { echo -e "${RED}[ERROR]${RESET} $*" >&2; }
log_step()    { echo -e "\n${BOLD}==> $*${RESET}"; }
log_dry()     { echo -e "${YELLOW}[DRY-RUN]${RESET} $*"; }

# ---------------------------------------------------------------------------
# die — print error message and exit
# ---------------------------------------------------------------------------
die() {
    log_error "$*"
    exit 1
}

# ---------------------------------------------------------------------------
# require_root — exit if not running as root
# ---------------------------------------------------------------------------
require_root() {
    [[ ${EUID} -eq 0 ]] || die "This script must be run as root (use sudo)."
}

# ---------------------------------------------------------------------------
# confirm — prompt user for yes/no; respects STROMA_YES=1 for automation
# ---------------------------------------------------------------------------
confirm() {
    local prompt="${1:-Continue?}"
    if [[ "${STROMA_YES:-0}" == "1" ]]; then
        log_info "Auto-confirming: ${prompt}"
        return 0
    fi
    echo -en "${BOLD}${prompt} [y/N]: ${RESET}"
    local reply
    read -r reply
    [[ "${reply,,}" == "y" || "${reply,,}" == "yes" ]]
}

# ---------------------------------------------------------------------------
# run_cmd — print and run a command; in dry-run mode, print only
# ---------------------------------------------------------------------------
run_cmd() {
    if [[ "${STROMA_DRY_RUN:-0}" == "1" ]]; then
        log_dry "$*"
        return 0
    fi
    log_info "Running: $*"
    "$@"
}

# ---------------------------------------------------------------------------
# check_cmd — verify a command exists on PATH
# ---------------------------------------------------------------------------
check_cmd() {
    command -v "$1" &>/dev/null
}

# ---------------------------------------------------------------------------
# require_cmd — die if a command is missing
# ---------------------------------------------------------------------------
require_cmd() {
    check_cmd "$1" || die "Required command not found: $1"
}

# ---------------------------------------------------------------------------
# version_ge — compare semantic versions (major.minor)
# Returns 0 if $1 >= $2
# ---------------------------------------------------------------------------
version_ge() {
    # Usage: version_ge "3.11" "3.8"
    printf '%s\n%s\n' "$2" "$1" | sort -V -C
}

# ---------------------------------------------------------------------------
# backup_file — copy file to .bak before modifying
# ---------------------------------------------------------------------------
backup_file() {
    local file="$1"
    if [[ -f "${file}" ]]; then
        cp -p "${file}" "${file}.bak.$(date +%Y%m%d%H%M%S)"
        log_info "Backed up ${file}"
    fi
}

# ---------------------------------------------------------------------------
# installed_version — return installed package version or empty string
# ---------------------------------------------------------------------------
installed_version() {
    local pkg="$1"
    case "${OS_FAMILY:-}" in
        rhel) rpm -q --queryformat '%{VERSION}' "${pkg}" 2>/dev/null || true ;;
        debian) dpkg-query -W -f='${Version}' "${pkg}" 2>/dev/null || true ;;
        *) echo "" ;;
    esac
}

# ---------------------------------------------------------------------------
# ai_flux_venv — path to the Python virtual environment
# ---------------------------------------------------------------------------
readonly STROMA_VENV="/opt/ai-flux/venv"
readonly STROMA_PYTHON="${STROMA_VENV}/bin/python3"
readonly STROMA_PIP="${STROMA_VENV}/bin/pip"

# ---------------------------------------------------------------------------
# AI_FLUX installation directories
# ---------------------------------------------------------------------------
readonly STROMA_INSTALL_DIR="/opt/ai-flux"
# STROMA_LOG_DIR must NOT be readonly — it is overridden by STROMA_SHARED_ROOT
# or STROMA_LOG_DIR from config.env. The value here is the fallback only.
STROMA_LOG_DIR="${STROMA_LOG_DIR:-${STROMA_SHARED_ROOT:-/share}/logs/ai-flux}"
readonly STROMA_STATE_DIR="/opt/ai-flux/state"
readonly STROMA_SYSTEMD_DIR="/etc/systemd/system"
