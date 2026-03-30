#!/usr/bin/env bash
# =============================================================================
# StromaAI — Grafana Dashboard Generator
# =============================================================================
# Generates a Grafana dashboard JSON pre-populated with site-specific values
# from config.env. Import the output file into Grafana via:
#
#   Dashboards → New → Import → Upload JSON file
#   (Select your Prometheus datasource when prompted)
#
# Usage:
#   scripts/generate-grafana-dashboard.sh [OPTIONS]
#
# Options:
#   --config FILE        Path to config.env (default: /opt/stroma-ai/config.env)
#   --output FILE        Write JSON to FILE instead of stdout
#   --datasource NAME    Label for the Prometheus datasource shown during import
#                        (default: Prometheus)
#   -h, --help           Show this help
#
# Panels generated:
#   • vLLM service health (Online / Offline stat)
#   • Active, waiting, and GPU→CPU-swapped request counts (stat)
#   • GPU and CPU KV cache utilization (gauge)
#   • Request traffic over time — active / waiting / swapped (time series)
#   • KV cache utilization over time — GPU + CPU (time series)
#   • End-to-end request latency p50 / p95 / p99 (time series)
#   • Time to first token p50 / p95 / p99 (time series)
#
# Thresholds are derived from your config:
#   • Waiting requests  — warn at STROMA_SCALE_UP_THRESHOLD, crit at 2×
#   • GPU KV cache      — warn at 70%, crit just above STROMA_GPU_MEM_UTIL
#   • CPU KV cache      — warn at 60%, crit at 80%
#
# Requirements:
#   bash 4+, awk, sed
#   jq is optional — if present the output is pretty-printed; if absent the
#   JSON is still valid and can be imported directly into Grafana.
# =============================================================================

set -euo pipefail

# ---------------------------------------------------------------------------
# Defaults
# ---------------------------------------------------------------------------
CONFIG_FILE="${STROMA_CONFIG:-/opt/stroma-ai/config.env}"
OUTPUT_FILE=""
DATASOURCE_NAME="Prometheus"

# ---------------------------------------------------------------------------
# Argument parsing
# ---------------------------------------------------------------------------
while [[ $# -gt 0 ]]; do
    case "$1" in
        --config)     CONFIG_FILE="$2";     shift 2 ;;
        --output)     OUTPUT_FILE="$2";     shift 2 ;;
        --datasource) DATASOURCE_NAME="$2"; shift 2 ;;
        -h|--help)
            head -45 "$0" | grep '^#' | sed 's/^# \{0,1\}//'
            exit 0
            ;;
        *) echo "ERROR: Unknown argument: $1" >&2; exit 1 ;;
    esac
done

# ---------------------------------------------------------------------------
# Load config
# ---------------------------------------------------------------------------
if [[ ! -f "${CONFIG_FILE}" ]]; then
    echo "ERROR: Config file not found: ${CONFIG_FILE}" >&2
    echo "       Use --config to specify a path, or copy config/config.example.env first." >&2
    exit 2
fi

# shellcheck source=/dev/null
source "${CONFIG_FILE}"

# Apply platform defaults for any variables not set in config
STROMA_HEAD_HOST="${STROMA_HEAD_HOST:-stroma-ai.your-cluster.example}"
STROMA_MODEL_NAME="${STROMA_MODEL_NAME:-stroma-ai-coder}"
STROMA_SLURM_PARTITION="${STROMA_SLURM_PARTITION:-stroma-ai-gpu}"
STROMA_MAX_BURST_WORKERS="${STROMA_MAX_BURST_WORKERS:-5}"
STROMA_SCALE_UP_THRESHOLD="${STROMA_SCALE_UP_THRESHOLD:-2}"
STROMA_GPU_MEM_UTIL="${STROMA_GPU_MEM_UTIL:-0.85}"
STROMA_MAX_NUM_SEQS="${STROMA_MAX_NUM_SEQS:-64}"

# ---------------------------------------------------------------------------
# Derived values
# ---------------------------------------------------------------------------

# Stable import-safe UID: Grafana allows [a-z0-9-], max 40 chars
DASH_UID="stroma-$(printf '%s' "${STROMA_HEAD_HOST}" \
    | tr '[:upper:]' '[:lower:]' \
    | tr -cs 'a-z0-9' '-' \
    | sed 's/-\+/-/g; s/^-//; s/-$//' \
    | cut -c1-34)"

DASH_TITLE="StromaAI — ${STROMA_HEAD_HOST}"
GENERATED_AT="$(date -u '+%Y-%m-%dT%H:%M:%SZ')"

# GPU thresholds as integer percentages
GPU_UTIL_PCT=$(awk "BEGIN { printf \"%d\", ${STROMA_GPU_MEM_UTIL} * 100 }")
GPU_CRIT_PCT=$(awk "BEGIN { v = (${STROMA_GPU_MEM_UTIL} + 0.05) * 100; printf \"%d\", (v > 100 ? 100 : v) }")

# Waiting-request thresholds: warn at scale-up trigger, crit at 2x
SCALE_WARN=${STROMA_SCALE_UP_THRESHOLD}
SCALE_CRIT=$(( STROMA_SCALE_UP_THRESHOLD * 2 ))

# ---------------------------------------------------------------------------
# Dashboard JSON
#
# Escaping notes (bash unquoted heredoc):
#   ${STROMA_...}          — bash variable, substituted at generation time
#   \${DS_PROMETHEUS}      — Grafana datasource variable, literal $ in output
#   \$__rate_interval      — Grafana time variable, literal $ in output
#   \"                     — backslash passes through unchanged; produces \"
#                            in JSON output (correct JSON string escaping)
# ---------------------------------------------------------------------------
generate_dashboard() {
cat << 'ENDJSON_HEADER'
{
  "__inputs": [
ENDJSON_HEADER
cat << ENDJSON_INPUT
    {
      "description": "Prometheus scraping the StromaAI vLLM /metrics endpoint on ${STROMA_HEAD_HOST}",
      "label": "${DATASOURCE_NAME}",
      "name": "DS_PROMETHEUS",
      "pluginId": "prometheus",
      "pluginName": "Prometheus",
      "type": "datasource"
    }
  ],
  "__requires": [
    {"id": "grafana",    "name": "Grafana",     "type": "grafana",    "version": "10.0.0"},
    {"id": "prometheus", "name": "Prometheus",  "type": "datasource", "version": "1.0.0"},
    {"id": "gauge",      "name": "Gauge",       "type": "panel",      "version": ""},
    {"id": "stat",       "name": "Stat",        "type": "panel",      "version": ""},
    {"id": "timeseries", "name": "Time series", "type": "panel",      "version": ""}
  ],
  "annotations": {"list": []},
  "description": "StromaAI HPC burst inference | host: ${STROMA_HEAD_HOST} | model: ${STROMA_MODEL_NAME} | partition: ${STROMA_SLURM_PARTITION} | generated: ${GENERATED_AT}",
  "editable": true,
  "graphTooltip": 1,
  "id": null,
  "links": [],
  "panels": [

    {
      "collapsed": false,
      "gridPos": {"h": 1, "w": 24, "x": 0, "y": 0},
      "id": 30,
      "title": "Request Traffic  |  ${STROMA_HEAD_HOST}  |  model: ${STROMA_MODEL_NAME}",
      "type": "row"
    },

    {
      "datasource": {"type": "prometheus", "uid": "\${DS_PROMETHEUS}"},
      "description": "1 = vLLM process is reachable and serving metrics; 0 = unreachable. Check: systemctl status stroma-ai-vllm",
      "fieldConfig": {
        "defaults": {
          "color": {"mode": "thresholds"},
          "mappings": [
            {
              "options": {
                "0": {"color": "red",   "index": 1, "text": "Offline"},
                "1": {"color": "green", "index": 0, "text": "Online"}
              },
              "type": "value"
            }
          ],
          "thresholds": {
            "mode": "absolute",
            "steps": [{"color": "red", "value": null}, {"color": "green", "value": 1}]
          }
        }
      },
      "gridPos": {"h": 4, "w": 4, "x": 0, "y": 1},
      "id": 1,
      "options": {
        "colorMode": "background",
        "graphMode": "none",
        "justifyMode": "center",
        "orientation": "auto",
        "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": false},
        "textMode": "value_and_name"
      },
      "targets": [
        {
          "datasource": {"type": "prometheus", "uid": "\${DS_PROMETHEUS}"},
          "expr": "up{job=\"stroma-ai-vllm\"}",
          "legendFormat": "vLLM",
          "refId": "A"
        }
      ],
      "title": "vLLM Status",
      "type": "stat"
    },

    {
      "datasource": {"type": "prometheus", "uid": "\${DS_PROMETHEUS}"},
      "description": "Requests currently being processed by GPU workers. Turns yellow when approaching STROMA_MAX_NUM_SEQS (${STROMA_MAX_NUM_SEQS}).",
      "fieldConfig": {
        "defaults": {
          "color": {"mode": "thresholds"},
          "thresholds": {
            "mode": "absolute",
            "steps": [
              {"color": "green",  "value": null},
              {"color": "yellow", "value": ${STROMA_MAX_NUM_SEQS}}
            ]
          },
          "unit": "short"
        }
      },
      "gridPos": {"h": 4, "w": 4, "x": 4, "y": 1},
      "id": 2,
      "options": {
        "colorMode": "value",
        "graphMode": "area",
        "justifyMode": "auto",
        "orientation": "auto",
        "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": false},
        "textMode": "auto"
      },
      "targets": [
        {
          "datasource": {"type": "prometheus", "uid": "\${DS_PROMETHEUS}"},
          "expr": "vllm:num_requests_running{model_name=\"${STROMA_MODEL_NAME}\"}",
          "legendFormat": "active",
          "refId": "A"
        }
      ],
      "title": "Active Requests",
      "type": "stat"
    },

    {
      "datasource": {"type": "prometheus", "uid": "\${DS_PROMETHEUS}"},
      "description": "Requests queued with no available GPU slot. The watcher submits a burst worker when this reaches ${SCALE_WARN} (STROMA_SCALE_UP_THRESHOLD). Red at ${SCALE_CRIT} (2x threshold).",
      "fieldConfig": {
        "defaults": {
          "color": {"mode": "thresholds"},
          "thresholds": {
            "mode": "absolute",
            "steps": [
              {"color": "green",  "value": null},
              {"color": "yellow", "value": ${SCALE_WARN}},
              {"color": "red",    "value": ${SCALE_CRIT}}
            ]
          },
          "unit": "short"
        }
      },
      "gridPos": {"h": 4, "w": 4, "x": 8, "y": 1},
      "id": 3,
      "options": {
        "colorMode": "background",
        "graphMode": "area",
        "justifyMode": "auto",
        "orientation": "auto",
        "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": false},
        "textMode": "auto"
      },
      "targets": [
        {
          "datasource": {"type": "prometheus", "uid": "\${DS_PROMETHEUS}"},
          "expr": "vllm:num_requests_waiting{model_name=\"${STROMA_MODEL_NAME}\"}",
          "legendFormat": "waiting",
          "refId": "A"
        }
      ],
      "title": "Waiting (burst fires >= ${SCALE_WARN})",
      "type": "stat"
    },

    {
      "datasource": {"type": "prometheus", "uid": "\${DS_PROMETHEUS}"},
      "description": "Requests evicted from GPU VRAM to CPU KV cache (STROMA_CPU_OFFLOAD_GB). Non-zero values indicate VRAM pressure; performance degrades versus on-GPU serving.",
      "fieldConfig": {
        "defaults": {
          "color": {"mode": "thresholds"},
          "thresholds": {
            "mode": "absolute",
            "steps": [
              {"color": "green",  "value": null},
              {"color": "yellow", "value": 1},
              {"color": "red",    "value": 5}
            ]
          },
          "unit": "short"
        }
      },
      "gridPos": {"h": 4, "w": 4, "x": 12, "y": 1},
      "id": 4,
      "options": {
        "colorMode": "value",
        "graphMode": "area",
        "justifyMode": "auto",
        "orientation": "auto",
        "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": false},
        "textMode": "auto"
      },
      "targets": [
        {
          "datasource": {"type": "prometheus", "uid": "\${DS_PROMETHEUS}"},
          "expr": "vllm:num_requests_swapped{model_name=\"${STROMA_MODEL_NAME}\"}",
          "legendFormat": "swapped",
          "refId": "A"
        }
      ],
      "title": "Swapped to CPU",
      "type": "stat"
    },

    {
      "datasource": {"type": "prometheus", "uid": "\${DS_PROMETHEUS}"},
      "description": "GPU VRAM used for KV cache as a fraction of the total reserved by vLLM (STROMA_GPU_MEM_UTIL=${STROMA_GPU_MEM_UTIL}). Warn at 70%; crit at ${GPU_CRIT_PCT}% — add burst workers or reduce max-model-len.",
      "fieldConfig": {
        "defaults": {
          "color": {"mode": "thresholds"},
          "max": 100,
          "min": 0,
          "thresholds": {
            "mode": "absolute",
            "steps": [
              {"color": "green",  "value": null},
              {"color": "yellow", "value": 70},
              {"color": "red",    "value": ${GPU_CRIT_PCT}}
            ]
          },
          "unit": "percent"
        }
      },
      "gridPos": {"h": 4, "w": 4, "x": 16, "y": 1},
      "id": 5,
      "options": {
        "minVizHeight": 75,
        "minVizWidth": 75,
        "orientation": "auto",
        "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": false},
        "showThresholdLabels": false,
        "showThresholdMarkers": true
      },
      "targets": [
        {
          "datasource": {"type": "prometheus", "uid": "\${DS_PROMETHEUS}"},
          "expr": "vllm:gpu_cache_usage_perc{model_name=\"${STROMA_MODEL_NAME}\"} * 100",
          "legendFormat": "GPU KV cache",
          "refId": "A"
        }
      ],
      "title": "GPU KV Cache (limit ${GPU_UTIL_PCT}%)",
      "type": "gauge"
    },

    {
      "datasource": {"type": "prometheus", "uid": "\${DS_PROMETHEUS}"},
      "description": "CPU RAM used for KV cache overflow (STROMA_CPU_OFFLOAD_GB). Sustained high values mean even the CPU KV cache is under pressure — consider adding burst workers.",
      "fieldConfig": {
        "defaults": {
          "color": {"mode": "thresholds"},
          "max": 100,
          "min": 0,
          "thresholds": {
            "mode": "absolute",
            "steps": [
              {"color": "green",  "value": null},
              {"color": "yellow", "value": 60},
              {"color": "red",    "value": 80}
            ]
          },
          "unit": "percent"
        }
      },
      "gridPos": {"h": 4, "w": 4, "x": 20, "y": 1},
      "id": 6,
      "options": {
        "minVizHeight": 75,
        "minVizWidth": 75,
        "orientation": "auto",
        "reduceOptions": {"calcs": ["lastNotNull"], "fields": "", "values": false},
        "showThresholdLabels": false,
        "showThresholdMarkers": true
      },
      "targets": [
        {
          "datasource": {"type": "prometheus", "uid": "\${DS_PROMETHEUS}"},
          "expr": "vllm:cpu_cache_usage_perc{model_name=\"${STROMA_MODEL_NAME}\"} * 100",
          "legendFormat": "CPU KV cache",
          "refId": "A"
        }
      ],
      "title": "CPU KV Cache",
      "type": "gauge"
    },

    {
      "datasource": {"type": "prometheus", "uid": "\${DS_PROMETHEUS}"},
      "description": "Request counts over time. A sustained non-zero 'waiting' line means demand is outpacing current burst worker capacity.",
      "fieldConfig": {
        "defaults": {
          "color": {"mode": "palette-classic"},
          "custom": {"fillOpacity": 10, "lineWidth": 2, "showPoints": "never"},
          "unit": "short"
        },
        "overrides": [
          {
            "matcher": {"id": "byName", "options": "waiting"},
            "properties": [
              {"id": "color",              "value": {"fixedColor": "yellow", "mode": "fixed"}},
              {"id": "custom.fillOpacity", "value": 25}
            ]
          },
          {
            "matcher": {"id": "byName", "options": "active"},
            "properties": [{"id": "color", "value": {"fixedColor": "green", "mode": "fixed"}}]
          },
          {
            "matcher": {"id": "byName", "options": "swapped"},
            "properties": [{"id": "color", "value": {"fixedColor": "orange", "mode": "fixed"}}]
          }
        ]
      },
      "gridPos": {"h": 8, "w": 12, "x": 0, "y": 5},
      "id": 7,
      "options": {
        "legend": {"calcs": ["max", "mean", "lastNotNull"], "displayMode": "table", "placement": "bottom"},
        "tooltip": {"mode": "multi", "sort": "desc"}
      },
      "targets": [
        {
          "datasource": {"type": "prometheus", "uid": "\${DS_PROMETHEUS}"},
          "expr": "vllm:num_requests_running{model_name=\"${STROMA_MODEL_NAME}\"}",
          "legendFormat": "active",
          "refId": "A"
        },
        {
          "datasource": {"type": "prometheus", "uid": "\${DS_PROMETHEUS}"},
          "expr": "vllm:num_requests_waiting{model_name=\"${STROMA_MODEL_NAME}\"}",
          "legendFormat": "waiting",
          "refId": "B"
        },
        {
          "datasource": {"type": "prometheus", "uid": "\${DS_PROMETHEUS}"},
          "expr": "vllm:num_requests_swapped{model_name=\"${STROMA_MODEL_NAME}\"}",
          "legendFormat": "swapped",
          "refId": "C"
        }
      ],
      "title": "Request Traffic",
      "type": "timeseries"
    },

    {
      "datasource": {"type": "prometheus", "uid": "\${DS_PROMETHEUS}"},
      "description": "KV cache pressure over time. GPU cache consistently near ${GPU_UTIL_PCT}% means model weights and active KV are filling GPU VRAM — scale up or reduce STROMA_GPU_MEM_UTIL.",
      "fieldConfig": {
        "defaults": {
          "color": {"mode": "palette-classic"},
          "custom": {"fillOpacity": 15, "lineWidth": 2, "showPoints": "never"},
          "max": 100,
          "min": 0,
          "unit": "percent"
        },
        "overrides": [
          {
            "matcher": {"id": "byName", "options": "GPU KV cache"},
            "properties": [{"id": "color", "value": {"fixedColor": "semi-dark-blue",   "mode": "fixed"}}]
          },
          {
            "matcher": {"id": "byName", "options": "CPU KV cache"},
            "properties": [{"id": "color", "value": {"fixedColor": "semi-dark-purple", "mode": "fixed"}}]
          }
        ]
      },
      "gridPos": {"h": 8, "w": 12, "x": 12, "y": 5},
      "id": 8,
      "options": {
        "legend": {"calcs": ["max", "mean", "lastNotNull"], "displayMode": "table", "placement": "bottom"},
        "tooltip": {"mode": "multi", "sort": "desc"}
      },
      "targets": [
        {
          "datasource": {"type": "prometheus", "uid": "\${DS_PROMETHEUS}"},
          "expr": "vllm:gpu_cache_usage_perc{model_name=\"${STROMA_MODEL_NAME}\"} * 100",
          "legendFormat": "GPU KV cache",
          "refId": "A"
        },
        {
          "datasource": {"type": "prometheus", "uid": "\${DS_PROMETHEUS}"},
          "expr": "vllm:cpu_cache_usage_perc{model_name=\"${STROMA_MODEL_NAME}\"} * 100",
          "legendFormat": "CPU KV cache",
          "refId": "B"
        }
      ],
      "title": "KV Cache Utilization",
      "type": "timeseries"
    },

    {
      "collapsed": false,
      "gridPos": {"h": 1, "w": 24, "x": 0, "y": 13},
      "id": 31,
      "title": "Latency",
      "type": "row"
    },

    {
      "datasource": {"type": "prometheus", "uid": "\${DS_PROMETHEUS}"},
      "description": "Total wall-clock time from request receipt to last response token. Spikes here (especially p99) indicate queue wait time, not just GPU processing time.",
      "fieldConfig": {
        "defaults": {
          "color": {"mode": "palette-classic"},
          "custom": {"fillOpacity": 5, "lineWidth": 2, "showPoints": "never"},
          "unit": "s"
        }
      },
      "gridPos": {"h": 8, "w": 12, "x": 0, "y": 14},
      "id": 9,
      "options": {
        "legend": {"calcs": ["max", "mean", "lastNotNull"], "displayMode": "table", "placement": "bottom"},
        "tooltip": {"mode": "multi", "sort": "desc"}
      },
      "targets": [
        {
          "datasource": {"type": "prometheus", "uid": "\${DS_PROMETHEUS}"},
          "expr": "histogram_quantile(0.50, sum(rate(vllm:e2e_request_latency_seconds_bucket{model_name=\"${STROMA_MODEL_NAME}\"}[\$__rate_interval])) by (le))",
          "legendFormat": "p50",
          "refId": "A"
        },
        {
          "datasource": {"type": "prometheus", "uid": "\${DS_PROMETHEUS}"},
          "expr": "histogram_quantile(0.95, sum(rate(vllm:e2e_request_latency_seconds_bucket{model_name=\"${STROMA_MODEL_NAME}\"}[\$__rate_interval])) by (le))",
          "legendFormat": "p95",
          "refId": "B"
        },
        {
          "datasource": {"type": "prometheus", "uid": "\${DS_PROMETHEUS}"},
          "expr": "histogram_quantile(0.99, sum(rate(vllm:e2e_request_latency_seconds_bucket{model_name=\"${STROMA_MODEL_NAME}\"}[\$__rate_interval])) by (le))",
          "legendFormat": "p99",
          "refId": "C"
        }
      ],
      "title": "End-to-End Request Latency",
      "type": "timeseries"
    },

    {
      "datasource": {"type": "prometheus", "uid": "\${DS_PROMETHEUS}"},
      "description": "Time from request receipt to the first response token. This isolates scheduling and prefill latency from total generation time. High TTFT with low e2e latency indicates short outputs; high both indicates queue depth or prefill contention.",
      "fieldConfig": {
        "defaults": {
          "color": {"mode": "palette-classic"},
          "custom": {"fillOpacity": 5, "lineWidth": 2, "showPoints": "never"},
          "unit": "s"
        }
      },
      "gridPos": {"h": 8, "w": 12, "x": 12, "y": 14},
      "id": 10,
      "options": {
        "legend": {"calcs": ["max", "mean", "lastNotNull"], "displayMode": "table", "placement": "bottom"},
        "tooltip": {"mode": "multi", "sort": "desc"}
      },
      "targets": [
        {
          "datasource": {"type": "prometheus", "uid": "\${DS_PROMETHEUS}"},
          "expr": "histogram_quantile(0.50, sum(rate(vllm:time_to_first_token_seconds_bucket{model_name=\"${STROMA_MODEL_NAME}\"}[\$__rate_interval])) by (le))",
          "legendFormat": "p50",
          "refId": "A"
        },
        {
          "datasource": {"type": "prometheus", "uid": "\${DS_PROMETHEUS}"},
          "expr": "histogram_quantile(0.95, sum(rate(vllm:time_to_first_token_seconds_bucket{model_name=\"${STROMA_MODEL_NAME}\"}[\$__rate_interval])) by (le))",
          "legendFormat": "p95",
          "refId": "B"
        },
        {
          "datasource": {"type": "prometheus", "uid": "\${DS_PROMETHEUS}"},
          "expr": "histogram_quantile(0.99, sum(rate(vllm:time_to_first_token_seconds_bucket{model_name=\"${STROMA_MODEL_NAME}\"}[\$__rate_interval])) by (le))",
          "legendFormat": "p99",
          "refId": "C"
        }
      ],
      "title": "Time to First Token (TTFT)",
      "type": "timeseries"
    }

  ],
  "refresh": "30s",
  "schemaVersion": 38,
  "tags": ["stroma-ai", "vllm", "hpc", "${STROMA_SLURM_PARTITION}"],
  "templating": {"list": []},
  "time": {"from": "now-1h", "to": "now"},
  "timepicker": {},
  "timezone": "browser",
  "title": "${DASH_TITLE}",
  "uid": "${DASH_UID}",
  "version": 1
}
ENDJSON_INPUT
}

# ---------------------------------------------------------------------------
# Format and write
# ---------------------------------------------------------------------------
if command -v jq &>/dev/null; then
    DASHBOARD_JSON=$(generate_dashboard | jq .)
else
    DASHBOARD_JSON=$(generate_dashboard)
fi

if [[ -n "${OUTPUT_FILE}" ]]; then
    printf '%s\n' "${DASHBOARD_JSON}" > "${OUTPUT_FILE}"
    echo "Grafana dashboard written to: ${OUTPUT_FILE}" >&2
    echo "" >&2
    echo "  Title       : ${DASH_TITLE}" >&2
    echo "  UID         : ${DASH_UID}" >&2
    echo "  Model       : ${STROMA_MODEL_NAME}" >&2
    echo "  Host        : ${STROMA_HEAD_HOST}" >&2
    echo "  Partition   : ${STROMA_SLURM_PARTITION}" >&2
    echo "  Max workers : ${STROMA_MAX_BURST_WORKERS}" >&2
    echo "" >&2
    echo "  Thresholds:" >&2
    echo "    GPU KV cache   — warn 70%, crit ${GPU_CRIT_PCT}%  (STROMA_GPU_MEM_UTIL=${STROMA_GPU_MEM_UTIL})" >&2
    echo "    Waiting reqs   — warn ${SCALE_WARN}, crit ${SCALE_CRIT}  (STROMA_SCALE_UP_THRESHOLD=${STROMA_SCALE_UP_THRESHOLD})" >&2
    echo "" >&2
    echo "Import: Grafana => Dashboards => New => Import => Upload JSON file" >&2
else
    printf '%s\n' "${DASHBOARD_JSON}"
fi
