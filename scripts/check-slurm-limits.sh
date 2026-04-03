#!/usr/bin/env bash
# =============================================================================
# Check Slurm QOS and Partition Limits
# =============================================================================
# Helps diagnose QOSMaxWallDurationPerJobLimit errors by showing actual limits

set -euo pipefail

echo "=== Checking QOS Limits ==="
sacctmgr show qos format=Name,MaxWall -p 2>/dev/null || echo "Warning: Cannot query QOS (may need admin privileges)"

echo ""
echo "=== Your QOS Assignment (CRITICAL - this limit applies to you) ==="
sacctmgr show user $USER format=User,Account,QOS -p 2>/dev/null || echo "Warning: Cannot query user (may need admin privileges)"
echo "Note: If QOS is blank, you're using the default QOS (usually 'normal')"

echo ""
echo "=== Checking Partition Limits ==="
scontrol show partition | grep -E "PartitionName|MaxTime|QOS"

echo ""
echo "=== Your Current Job Defaults ==="
echo "Partition: ${STROMA_SLURM_PARTITION:-red}"
echo "Account:   ${STROMA_SLURM_ACCOUNT:-stroma-ai-service}"
echo "Walltime:  ${STROMA_SLURM_WALLTIME:-12:00:00}"

echo ""
echo "=== Recommended Actions ==="
echo "1. Check your assigned QOS above (blank = default 'normal' QOS)"
echo "2. Set STROMA_SLURM_WALLTIME in config.env BELOW your QOS MaxWall limit"
echo "3. Default 'normal' QOS typically allows 12:00:00 (12 hours)"
echo "4. For longer jobs, ask admin to assign a higher QOS (e.g., 'medium', 'large')"
echo "5. Restart services after changing config.env: sudo systemctl restart stroma-ai-watcher"
