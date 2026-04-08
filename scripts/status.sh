#!/usr/bin/env bash
# =============================================================================
# StromaAI — Operator Status Dashboard
# =============================================================================
# Prints a quick-glance status of all StromaAI components:
#   • systemd service states
#   • Active Slurm burst jobs in the stroma-ai partition
#   • Head-node GPU utilization (nvidia-smi)
#   • Watcher state summary (job count, last scale-up, idle timer)
#   • Recent watcher log lines from the journal
#
# Usage:
#   scripts/status.sh
#
# Environment overrides:
#   STROMA_CONFIG             path to config.env (default: /opt/stroma-ai/config.env)
#   STROMA_STATUS_LOG_LINES   number of watcher log lines to show (default: 20)
# =============================================================================

set -euo pipefail

_resolve_config_file() {
    [[ -n "${CONFIG_FILE:-}" ]] && return 0
    local _paths=(
        "${STROMA_INSTALL_DIR:+${STROMA_INSTALL_DIR}/config.env}"
        "/cm/shared/apps/stroma-ai/config.env"
        "/opt/stroma-ai/config.env"
        "/opt/apps/stroma-ai/config.env"
        "/usr/local/stroma-ai/config.env"
        "${HOME}/stroma-ai/config.env"
    )
    local _p
    for _p in "${_paths[@]}"; do
        [[ -z "${_p}" ]] && continue
        if [[ -f "${_p}" ]]; then CONFIG_FILE="${_p}"; return 0; fi
    done
}

CONFIG_FILE="${STROMA_CONFIG:-}"
_resolve_config_file
STATE_FILE="${STROMA_STATE_FILE:-$(dirname "${CONFIG_FILE:-/opt/stroma-ai/config.env}")/state/watcher_state.json}"
SLURM_PARTITION="${STROMA_SLURM_PARTITION:-stroma-ai-gpu}"
LOG_LINES="${STROMA_STATUS_LOG_LINES:-20}"

# Load config if present (non-fatal if missing)
# shellcheck source=/dev/null
[[ -f "${CONFIG_FILE}" ]] && source "${CONFIG_FILE}" || true

STATE_FILE="${STROMA_STATE_FILE:-${STATE_FILE}}"
SLURM_PARTITION="${STROMA_SLURM_PARTITION:-${SLURM_PARTITION}}"

hr() { printf '%.0s─' {1..62}; echo; }

echo
echo "╔════════════════════════════════════════════════════════════╗"
printf  "║   StromaAI Status  —  %-37s║\n" "$(date '+%Y-%m-%d %H:%M:%S %Z')"
echo "╚════════════════════════════════════════════════════════════╝"
echo

# ---------------------------------------------------------------------------
# Systemd services
# ---------------------------------------------------------------------------
hr
echo "  SERVICES"
hr
for svc in ray-head stroma-ai-vllm stroma-ai-watcher stroma-ai-model-watcher; do
    if systemctl list-unit-files "${svc}.service" &>/dev/null 2>&1; then
        active=$(systemctl is-active "${svc}" 2>/dev/null || echo "inactive")
        if [[ "${active}" == "active" ]]; then
            since=$(systemctl show "${svc}" -p ActiveEnterTimestamp --value 2>/dev/null \
                | awk '{print $1, $2}' || echo "?")
            printf "  %-24s  \e[32m▲ %-10s\e[0m  since %s\n" "${svc}" "${active}" "${since}"
        else
            printf "  %-24s  \e[31m▼ %-10s\e[0m\n" "${svc}" "${active}"
        fi
    else
        printf "  %-24s  not installed\n" "${svc}"
    fi
done
echo

# ---------------------------------------------------------------------------
# Slurm burst jobs
# ---------------------------------------------------------------------------
hr
echo "  SLURM BURST JOBS  (partition: ${SLURM_PARTITION})"
hr
if command -v squeue &>/dev/null; then
    jobs=$(squeue -p "${SLURM_PARTITION}" \
        -o "  %-12i %-10u %-12T %-10M %-20R" 2>/dev/null || true)
    if [[ -n "${jobs}" ]]; then
        printf "  %-12s %-10s %-12s %-10s %s\n" "JOBID" "USER" "STATE" "TIME" "REASON"
        echo "${jobs}"
    else
        echo "  (no jobs in partition ${SLURM_PARTITION})"
    fi
else
    echo "  squeue not found — not running on a Slurm head node"
fi
echo

# ---------------------------------------------------------------------------
# GPU utilization (head node)
# ---------------------------------------------------------------------------
hr
echo "  HEAD NODE GPU"
hr
if command -v nvidia-smi &>/dev/null; then
    nvidia-smi \
        --query-gpu=index,name,utilization.gpu,memory.used,memory.total,temperature.gpu \
        --format=csv,noheader,nounits 2>/dev/null \
    | awk -F', ' '{
        printf "  GPU%-2s  %-30s  %3s%% util  %6s/%6s MiB  %s°C\n",
            $1, $2, $3, $4, $5, $6
    }' || echo "  (nvidia-smi failed)"
else
    echo "  nvidia-smi not found (the Slurm workers, not this host, hold the GPUs)"
fi
echo

# ---------------------------------------------------------------------------
# Watcher state file summary
# ---------------------------------------------------------------------------
hr
echo "  WATCHER STATE"
hr
if [[ -f "${STATE_FILE}" ]]; then
    if command -v python3 &>/dev/null; then
        python3 - "${STATE_FILE}" <<'PYEOF'
import json, sys
from datetime import datetime, timezone

def _age(ts):
    if not ts:
        return "—"
    try:
        d = datetime.fromisoformat(ts)
        s = int((datetime.now(timezone.utc) - d).total_seconds())
        if s < 60:   return f"{s}s ago"
        if s < 3600: return f"{s//60}m ago"
        return f"{s//3600}h {(s%3600)//60}m ago"
    except Exception:
        return str(ts)

data = json.loads(open(sys.argv[1]).read())
jobs = data.get("jobs", {})
print(f"  Tracked jobs   : {len(jobs)}")
for jid, rec in jobs.items():
    print(f"    {jid}  state={rec.get('state','?'):8s}  "
          f"submitted={_age(rec.get('submitted_at'))}")
print(f"  Last scale-up  : {_age(data.get('last_scale_up'))}")
print(f"  Idle since     : {_age(data.get('idle_since'))}")
print(f"  Lifetime subs  : {data.get('total_submitted', 0)}")
print(f"  Lifetime cancels: {data.get('total_cancelled', 0)}")
PYEOF
    else
        cat "${STATE_FILE}"
    fi
else
    echo "  State file not found: ${STATE_FILE}"
    echo "  (watcher has not yet run, or STROMA_STATE_FILE is not set)"
fi
echo

# ---------------------------------------------------------------------------
# Recent watcher log lines
# ---------------------------------------------------------------------------
hr
echo "  RECENT WATCHER LOGS  (last ${LOG_LINES} lines)"
hr
if command -v journalctl &>/dev/null; then
    journalctl -u stroma-ai-watcher -n "${LOG_LINES}" --no-pager --output=short-iso \
        2>/dev/null || echo "  (no journal output — service may not have started yet)"
else
    echo "  journalctl not available"
fi
echo

# ---------------------------------------------------------------------------
# Model watcher state (multi-model lifecycle)
# ---------------------------------------------------------------------------
MODEL_STATE_FILE="${STROMA_MODEL_STATE_FILE:-$(dirname "${CONFIG_FILE:-/opt/stroma-ai/config.env}")/state/model_watcher_state.json}"
WATCHER_PORT="${STROMA_WATCHER_PORT:-9100}"

hr
echo "  MODEL WATCHER STATE"
hr
if [[ -f "${MODEL_STATE_FILE}" ]]; then
    if command -v python3 &>/dev/null; then
        python3 - "${MODEL_STATE_FILE}" <<'PYEOF'
import json, sys, time
from datetime import datetime, timezone

def _age(ts):
    if not ts:
        return "—"
    try:
        if isinstance(ts, (int, float)):
            s = int(time.time() - ts)
        else:
            d = datetime.fromisoformat(ts)
            s = int((datetime.now(timezone.utc) - d).total_seconds())
        if s < 0:    return "in future?"
        if s < 60:   return f"{s}s ago"
        if s < 3600: return f"{s//60}m ago"
        return f"{s//3600}h {(s%3600)//60}m ago"
    except Exception:
        return str(ts)

STATUS_COLORS = {
    "serving":      "\033[32m",
    "provisioning": "\033[33m",
    "requested":    "\033[36m",
    "draining":     "\033[33m",
    "error":        "\033[31m",
    "available":    "\033[2m",
}
RESET = "\033[0m"

data = json.loads(open(sys.argv[1]).read())
models = data.get("models", {})
if not models:
    print("  (no per-model state recorded)")
else:
    print(f"  {'MODEL':<40s}  {'STATUS':<14s}  {'PORT':<6s}  {'SLURM JOBS':<12s}  IDLE SINCE")
    for mid, rec in sorted(models.items()):
        status = rec.get("status", "?")
        color = STATUS_COLORS.get(status, "")
        port = str(rec.get("vllm_port", "—")) if rec.get("vllm_port") else "—"
        jobs = ",".join(rec.get("slurm_job_ids", [])) or "—"
        idle = _age(rec.get("idle_since"))
        err = rec.get("error_message", "")
        print(f"  {mid:<40s}  {color}{status:<14s}{RESET}  {port:<6s}  {jobs:<12s}  {idle}")
        if err:
            print(f"    \033[31m↳ error: {err}{RESET}")
print(f"\n  Total provisioned : {data.get('total_provisioned', 0)}")
print(f"  Total drained     : {data.get('total_drained', 0)}")
PYEOF
    else
        cat "${MODEL_STATE_FILE}"
    fi
else
    echo "  State file not found: ${MODEL_STATE_FILE}"
fi

# Model watcher HTTP API (if running)
if curl -sf -m 2 "http://localhost:${WATCHER_PORT}/status" &>/dev/null; then
    echo
    echo "  Model watcher API (http://localhost:${WATCHER_PORT}/status):"
    curl -sf -m 5 "http://localhost:${WATCHER_PORT}/status" 2>/dev/null \
        | python3 -m json.tool 2>/dev/null \
        | sed 's/^/  /' \
        || echo "  (could not parse response)"
fi
echo

# ---------------------------------------------------------------------------
# Recent model watcher log lines
# ---------------------------------------------------------------------------
hr
echo "  RECENT MODEL WATCHER LOGS  (last ${LOG_LINES} lines)"
hr
if command -v journalctl &>/dev/null; then
    journalctl -u stroma-ai-model-watcher -n "${LOG_LINES}" --no-pager --output=short-iso \
        2>/dev/null || echo "  (no journal output — service may not have started yet)"
else
    echo "  journalctl not available"
fi
echo
