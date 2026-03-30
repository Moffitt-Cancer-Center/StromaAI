#!/usr/bin/env bash
# =============================================================================
# StromaAI — Operator Status Dashboard
# =============================================================================
# Prints a quick-glance status of all StromaAI components:
#   • systemd service states
#   • Active Slurm burst jobs in the ai-flux partition
#   • Head-node GPU utilization (nvidia-smi)
#   • Watcher state summary (job count, last scale-up, idle timer)
#   • Recent watcher log lines from the journal
#
# Usage:
#   scripts/status.sh
#
# Environment overrides:
#   STROMA_CONFIG             path to config.env (default: /opt/ai-flux/config.env)
#   STROMA_STATUS_LOG_LINES   number of watcher log lines to show (default: 20)
# =============================================================================

set -euo pipefail

CONFIG_FILE="${STROMA_CONFIG:-/opt/ai-flux/config.env}"
STATE_FILE="${STROMA_STATE_FILE:-/opt/ai-flux/watcher_state.json}"
SLURM_PARTITION="${STROMA_SLURM_PARTITION:-ai-flux-gpu}"
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
for svc in ray-head ai-flux-vllm ai-flux-watcher; do
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
    journalctl -u ai-flux-watcher -n "${LOG_LINES}" --no-pager --output=short-iso \
        2>/dev/null || echo "  (no journal output — service may not have started yet)"
else
    echo "  journalctl not available"
fi
echo
