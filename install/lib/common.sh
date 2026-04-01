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

set -euo pipefail

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
# write_env_var — safely write KEY=VALUE to a .env file
# ---------------------------------------------------------------------------
# Uses Python instead of sed to avoid breakage when VALUE contains sed
# special characters (|, &, \, newlines, etc.).  Python 3 is a hard
# prerequisite for StromaAI so this function is always available.
# Creates the file if it does not already exist.
# ---------------------------------------------------------------------------
write_env_var() {
    local key="$1" value="$2" file="$3"
    python3 - "${key}" "${value}" "${file}" <<'PYEOF'
import sys, re, os

key, value, path = sys.argv[1], sys.argv[2], sys.argv[3]
entry = key + "=" + value + "\n"

if os.path.exists(path):
    with open(path, "r") as fh:
        lines = fh.readlines()
    updated = False
    for i, line in enumerate(lines):
        if re.match(r"^" + re.escape(key) + r"=", line):
            lines[i] = entry
            updated = True
            break
    if not updated:
        lines.append(entry)
    with open(path, "w") as fh:
        fh.writelines(lines)
else:
    with open(path, "w") as fh:
        fh.write(entry)
PYEOF
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
# StromaAI installation directories
# STROMA_INSTALL_DIR may be set by the caller before sourcing this file to
# install into a non-default location (e.g. /opt/stroma-ai-dev).
# ---------------------------------------------------------------------------
STROMA_INSTALL_DIR="${STROMA_INSTALL_DIR:-/opt/stroma-ai}"
# STROMA_LOG_DIR must NOT be readonly — it is overridden by STROMA_SHARED_ROOT
# or STROMA_LOG_DIR from config.env. The value here is the fallback only.
STROMA_LOG_DIR="${STROMA_LOG_DIR:-${STROMA_INSTALL_DIR}/logs}"
# shellcheck disable=SC2034  # used by install.sh (sourced at runtime)
readonly STROMA_STATE_DIR="${STROMA_INSTALL_DIR}/state"
# shellcheck disable=SC2034  # used by install.sh (sourced at runtime)
readonly STROMA_SYSTEMD_DIR="/etc/systemd/system"

# ---------------------------------------------------------------------------
# stroma_ai_venv — path to the Python virtual environment
# (computed after STROMA_INSTALL_DIR is finalised)
# ---------------------------------------------------------------------------
# shellcheck disable=SC2034  # used by packages.sh (sourced at runtime)
readonly STROMA_VENV="${STROMA_INSTALL_DIR}/venv"
# shellcheck disable=SC2034  # unused directly; kept for external sourcing
readonly STROMA_PYTHON="${STROMA_VENV}/bin/python3"
# shellcheck disable=SC2034  # used by packages.sh (sourced at runtime)
readonly STROMA_PIP="${STROMA_VENV}/bin/pip"

# ---------------------------------------------------------------------------
# open_firewall_port PORT/PROTO [ZONE]
# ---------------------------------------------------------------------------
# Opens a TCP/UDP port in firewalld permanently and reloads the firewall.
# Falls back to a warning if firewalld is not active.
#
# Usage:
#   open_firewall_port 8080/tcp
#   open_firewall_port 3000/tcp public
# ---------------------------------------------------------------------------
open_firewall_port() {
    local port_proto="$1"
    local zone="${2:-}"

    if [[ "${STROMA_DRY_RUN:-0}" == "1" ]]; then
        log_dry "firewall-cmd --permanent ${zone:+--zone=${zone} }--add-port=${port_proto} && firewall-cmd --reload"
        return 0
    fi

    if ! command -v firewall-cmd &>/dev/null; then
        log_warn "firewall-cmd not found — skipping firewall rule for ${port_proto}"
        return 0
    fi

    if ! systemctl is-active --quiet firewalld 2>/dev/null; then
        log_warn "firewalld is not running — skipping firewall rule for ${port_proto}"
        return 0
    fi

    local zone_arg=""
    if [[ -n "${zone}" ]]; then
        zone_arg="--zone=${zone}"
    fi

    if firewall-cmd --permanent ${zone_arg} --query-port="${port_proto}" &>/dev/null; then
        log_info "Firewall: port ${port_proto} already open${zone:+ in zone ${zone}}"
        return 0
    fi

    log_info "Firewall: opening ${port_proto}${zone:+ in zone ${zone}} ..."
    firewall-cmd --permanent ${zone_arg} --add-port="${port_proto}"
    firewall-cmd --reload
    log_ok "Firewall: ${port_proto} is open"
}

# ---------------------------------------------------------------------------
# install_systemd_service SRC_FILE SERVICE_NAME
# ---------------------------------------------------------------------------
# Copies a systemd unit file to /etc/systemd/system/, reloads the daemon,
# enables the service for boot, and starts it immediately.
#
# Usage:
#   install_systemd_service /path/to/foo.service stroma-ai-foo
# ---------------------------------------------------------------------------
install_systemd_service() {
    local src="$1"
    local name="$2"
    local dest="${STROMA_SYSTEMD_DIR}/${name}.service"

    if [[ "${STROMA_DRY_RUN:-0}" == "1" ]]; then
        log_dry "install systemd unit: ${src} → ${dest}"
        log_dry "systemctl daemon-reload && systemctl enable --now ${name}"
        return 0
    fi

    if [[ ! -f "${src}" ]]; then
        die "Systemd unit file not found: ${src}"
    fi

    log_info "Installing systemd unit: ${dest}"
    cp -p "${src}" "${dest}"
    chmod 644 "${dest}"
    systemctl daemon-reload
    systemctl enable --now "${name}"
    log_ok "Service ${name} enabled and started"
}

