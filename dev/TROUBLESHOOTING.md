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

### 2. Fixed vLLM Command Syntax Issue

**Problem**: vLLM container failed with `api_server.py: error: unrecognized arguments: vllm serve`

**Solution**:
- Removed incorrect `vllm serve` command prefix
- vLLM container expects direct API server arguments (starts with `--model`)
- Added auto-detection of model directory (uses first model found if only one exists)
- Added comprehensive model validation before starting vLLM

**Files modified**:
- `dev/docker-compose.yml` - Fixed vLLM command syntax
- `dev/dev.sh` - Auto-detect model path, validate model files before starting

### 3. Fixed vLLM GPU Out of Memory Issue

**Problem**: vLLM loaded model successfully but crashed with `CUDA out of memory` when allocating KV cache

**Solution**:
- Added `--gpu-memory-utilization 0.75` flag (down from default 0.9) to leave more headroom
- Added `--max-model-len 4096` flag to limit KV cache size
- Added `PYTORCH_CUDA_ALLOC_CONF=expandable_segments:True` environment variable
- Both configurable via `.env`: `STROMA_VLLM_GPU_MEMORY` and `STROMA_VLLM_MAX_MODEL_LEN`

**Files modified**:
- `dev/docker-compose.yml` - Added memory management flags and environment variable
- `dev/TROUBLESHOOTING.md` - Documented OOM troubleshooting and tuning options

---

## Quick Start (on your Linux system)

### Model Setup (Required for --inference)

vLLM needs a valid model directory with:
- `config.json`
- Tokenizer files
- Model weights (`*.safetensors` or `*.bin`)

**If you have one model** (e.g., Qwen):
```bash
# dev.sh will auto-detect it
cd /path/to/StromaAI/dev
./dev.sh up --inference
```

**If you have multiple models**:
```bash
# Specify which one to use
cd /path/to/StromaAI/dev
DEV_MODEL_PATH=$PWD/dev-data/models/Qwen ./dev.sh up --inference
# Or set in .env:
echo "DEV_MODEL_PATH=$PWD/dev-data/models/Qwen" >> .env
./dev.sh up --inference
```

**If you don't have a model yet**:
```bash
# Download one (requires internet)
cd /path/to/StromaAI/dev
source ../../venv/bin/activate  # If you have StromaAI venv
hfw download Qwen/Qwen2.5-7B-Instruct --local-dir ./dev-data/models/Qwen

# Or symlink from elsewhere
ln -s /share/models/my-model ./dev-data/models/my-model
echo "DEV_MODEL_PATH=$PWD/dev-data/models/my-model" >> .env
```

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

## Common vLLM Issues

### vLLM Container Exits Immediately

**Symptom**: `podman ps` shows vLLM missing, `podman ps -a` shows it exited

**Check logs**: `podman logs dev-stroma-vllm`

**Common causes**:

1. **Model path not set correctly**
   ```bash
   # Check what path is configured
   grep DEV_MODEL_PATH dev/.env
   
   # Make sure it points to the MODEL directory, not just models/
   # WRONG: DEV_MODEL_PATH=/home/user/StromaAI/dev/dev-data/models
   # RIGHT: DEV_MODEL_PATH=/home/user/StromaAI/dev/dev-data/models/Qwen
   ```

2. **Model directory empty or invalid**
   ```bash
   # Check model contents
   ls -la /path/from/DEV_MODEL_PATH/
   
   # Should see: config.json, tokenizer files, *.safetensors or *.bin files
   ```

3. **No GPU available** (and trying to use quantization that requires GPU)
   ```bash
   # Check GPU
   nvidia-smi
   
   # If no GPU, remove quantization flag or use CPU-compatible model
   ```

4. **Ray backend not ready**
   ```bash
   # Check ray-head is running
   podman ps | grep ray-head
   
   # Check ray status
   podman exec dev-stroma-ray-head ray status
   ```

### vLLM API Server Error: "unrecognized arguments"

**Symptom**: Logs show `api_server.py: error: unrecognized arguments: vllm serve`

**Cause**: Old command syntax in docker-compose.yml (pre-v0.7.2 format)

**Fix**: Already fixed in latest version. If you still see this:
```bash
cd /path/to/StromaAI
git pull origin main
./dev.sh clean
./dev.sh up --inference
```

### vLLM CUDA Out of Memory (OOM)

**Symptom**: vLLM loads model successfully but crashes with:
```
ERROR CUDA out of memory. Tried to allocate X.XX GiB. GPU 0 has a total capacity of XX.XX GiB
torch.OutOfMemoryError: CUDA out of memory
```

**Cause**: Model weights + KV cache + activation memory exceeds available GPU VRAM

**Solutions** (in order of preference):

1. **Reduce GPU memory utilization** (most common fix):
   ```bash
   # Add to dev/.env
   echo "STROMA_VLLM_GPU_MEMORY=0.75" >> dev/.env  # Default is 0.9
   
   # Restart vLLM
   cd dev
   ./dev.sh down
   ./dev.sh up --inference
   ```

2. **Limit maximum context length**:
   ```bash
   # Add to dev/.env
   echo "STROMA_VLLM_MAX_MODEL_LEN=4096" >> dev/.env  # Or 2048 for smaller memory footprint
   
   # Restart
   cd dev
   ./dev.sh down
   ./dev.sh up --inference
   ```

3. **Verify quantization is working** (if model should be quantized):
   ```bash
   # Check if model has quantization config
   cat /path/to/model/config.json | grep -i quant
   
   # If no quantization config, remove the flag:
   echo "STROMA_VLLM_QUANTIZATION=" >> dev/.env  # Empty disables quantization
   
   # Or use a smaller/quantized model
   ```

4. **Combine multiple fixes**:
   ```bash
   # For 24GB GPUs with large models
   echo "STROMA_VLLM_GPU_MEMORY=0.70" >> dev/.env
   echo "STROMA_VLLM_MAX_MODEL_LEN=2048" >> dev/.env
   
   cd dev
   ./dev.sh down
   ./dev.sh up --inference
   ```

5. **Use tensor parallelism** (if you have multiple GPUs):
   ```bash
   # Spread model across 2 GPUs
   # Edit docker-compose.yml and change:
   # --tensor-parallel-size 1  →  --tensor-parallel-size 2
   ```

**Memory requirements by model size** (approximate):
- 7B parameters: ~14-18 GB VRAM (fp16), ~4-6 GB (AWQ/GPTQ)
- 13B parameters: ~26-32 GB VRAM (fp16), ~7-10 GB (AWQ/GPTQ)
- 70B parameters: 140+ GB VRAM (fp16), ~35-50 GB (AWQ/GPTQ)

**Verify fix worked**:
```bash
podman logs dev-stroma-vllm | grep -i "available blocks"
# Should see: "# GPU blocks: XXXX" instead of crash
```

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
