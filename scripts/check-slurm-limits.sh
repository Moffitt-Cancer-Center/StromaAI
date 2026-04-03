#!/usr/bin/env bash
# =============================================================================
# Check Slurm QOS and Partition Limits
# =============================================================================
# Helps diagnose QOSMaxWallDurationPerJobLimit errors by showing actual limits

set -euo pipefail

echo "=== Checking QOS Limits ==="
sacctmgr show qos format=Name,MaxWall -p 2>/dev/null || echo "Warning: Cannot query QOS (may need admin privileges)"

echo ""
echo "=== Checking Partition Limits ==="
scontrol show partition | grep -E "PartitionName|MaxTime|QOS"

echo ""
echo "=== Your Current Job Defaults ==="
echo "Partition: ${STROMA_SLURM_PARTITION:-stroma-ai-gpu}"
echo "Account:   ${STROMA_SLURM_ACCOUNT:-stroma-ai-service}"
echo "Walltime:  ${STROMA_SLURM_WALLTIME:-7-00:00:00}"

echo ""
echo "=== Recommended Actions ==="
echo "1. Set STROMA_SLURM_WALLTIME in config.env to a value BELOW your QOS/partition MaxWall limit"
echo "2. For burst workers, 4-24 hours is typically sufficient (e.g., STROMA_SLURM_WALLTIME=12:00:00)"
echo "3. Restart services after changing config.env"
