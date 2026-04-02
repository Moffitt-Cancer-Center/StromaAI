# StromaAI Dev Environment Troubleshooting

## Changes Made (2026-04-01)

### 1. Fixed Slurm Binary Detection Issue

**Problem**: Watcher container failed with `statfs /usr/bin/sinfo: no such file or directory`

**Solution**: 
- Auto-detects Slurm binaries in common locations and via modules
- Creates stub paths if not found so containers can start
- Provides clear warnings if Slurm is unavailable

**Files modified**:
- `dev/dev.sh` - Enhanced `check_slurm_binaries()` function
- `dev/docker-compose.yml` - Updated watcher volume mounts with safe defaults

---

## Quick Start (on your Linux system)

### If you DON'T have Slurm installed:

```bash
cd /path/to/StromaAI/dev
./dev.sh clean          # Clean up old volumes and containers
./dev.sh up --inference # Start without watcher (no Slurm needed)
```

### If you DO have Slurm (via modules):

```bash
cd /path/to/StromaAI/dev
module load slurm       # Load your site's Slurm module first
./dev.sh clean
./dev.sh up --full      # Includes watcher
```

### If Slurm is in a non-standard location:

```bash
cd /path/to/StromaAI/dev
export SLURM_SBATCH_BIN=/custom/path/to/sbatch
export SLURM_SQUEUE_BIN=/custom/path/to/squeue
export SLURM_SCANCEL_BIN=/custom/path/to/scancel
export SLURM_SINFO_BIN=/custom/path/to/sinfo
./dev.sh up --full
```

---

## Debugging Gateway Restarts

If the gateway container keeps restarting:

```bash
cd /path/to/StromaAI/dev

# Run the debug script
bash debug-gateway.sh

# Or manually check:
podman logs dev-stroma-gateway           # See error messages
podman ps -a | grep gateway              # Check status
curl http://localhost:8000/health        # Test vLLM
curl http://localhost:8080/health        # Test Keycloak

# Follow logs in real-time:
podman logs -f dev-stroma-gateway
```

### Common Gateway Issues:

1. **Keycloak not ready yet**
   - Gateway tries to fetch OIDC config before Keycloak is fully started
   - Wait 30-60 seconds after startup, then check if it stabilizes

2. **vLLM backend not reachable**
   - Verify vLLM is running: `podman ps | grep vllm`
   - Check health: `curl http://localhost:8000/v1/models`

3. **Network connectivity**
   - Gateway uses `host.containers.internal` to reach vLLM and Keycloak
   - Test: `podman exec dev-stroma-gateway curl http://host.containers.internal:8080/health`

4. **Missing API key**
   - Check `dev/.env` has `STROMA_API_KEY=<value>`

---

## Viewing Container Status

```bash
# All containers:
podman ps -a

# Specific services:
podman ps -a --filter name=keycloak
podman ps -a --filter name=gateway
podman ps -a --filter name=vllm
podman ps -a --filter name=watcher

# View logs:
./dev.sh logs              # All services
./dev.sh logs keycloak     # Specific service
./dev.sh logs --tail=100   # Last 100 lines from all
```

---

## Clean Restart

If things get messy:

```bash
cd /path/to/StromaAI/dev
./dev.sh clean    # Removes containers AND volumes
./dev.sh up       # Fresh start
```

**Note**: This will delete the Keycloak database (user accounts, realm config). You'll need to reconfigure.

---

## Checking What's in .env

```bash
cd /path/to/StromaAI/dev
cat .env | grep -E "(SLURM|KC_|GATEWAY|VLLM)"
```

Look for:
- `SLURM_SBATCH_BIN=/path/or/stub`
- `KC_DB_PASSWORD=<generated>`
- `STROMA_API_KEY=<generated>`
- `STROMA_VLLM_PORT=8000`
