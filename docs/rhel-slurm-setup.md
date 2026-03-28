# AI_Flux — RHEL Slurm Node Pre-flight Checklist

This guide covers everything that must be verified or configured on **RHEL-family Slurm worker nodes** (Rocky Linux, AlmaLinux, CentOS Stream, RHEL) before running AI_Flux burst workers.

The head node (Proxmox VM) runs Debian and does NOT need this checklist.

---

## 1. SELinux — most common Apptainer failure

SELinux on RHEL 8/9 blocks several container operations by default. The following booleans must be set before any Apptainer/Singularity container will run correctly with GPUs:

```bash
# Enable container cgroup access (required for Apptainer GPU binding):
setsebool -P container_use_cgroups 1
setsebool -P container_manage_cgroup 1

# If using NVIDIA container CDI (Apptainer 1.3+):
setsebool -P container_use_devices 1

# Verify:
getsebool container_use_cgroups container_manage_cgroup
```

For persistent configuration across reboots, the `-P` flag is required.

If containers still fail with AVC denials, check the audit log:
```bash
ausearch -m avc -ts recent | audit2why
# Or:
journalctl -k | grep avc | tail -20
```

---

## 2. Apptainer / Singularity installation

Many HPC clusters load Apptainer via modules. The worker script auto-detects both:
```bash
# Check which is available:
module avail apptainer singularity 2>&1 | grep -E "apptainer|singularity"
module load apptainer

# Verify version (1.1+ recommended; 1.3+ for CDI/nvccli):
apptainer version
```

If neither is available as a module, install from the EPEL or official repo:
```bash
# RHEL 8:
dnf install -y epel-release
dnf install -y apptainer

# RHEL 9:
dnf install -y epel-release
dnf install -y apptainer
```

### --nv vs --nvccli

- `--nv`: Legacy GPU binding. Works with all Apptainer/Singularity versions.
- `--nvccli`: CDI-based binding. Requires Apptainer 1.3+ and NVIDIA CDI config.

The worker script defaults to `--nv`. Override with:
```bash
# In /opt/ai-flux/config.env (on head node, passed via --export):
AI_FLUX_CONTAINER_GPU_FLAG=--nvccli
```

---

## 3. NVIDIA drivers and container toolkit

The L30 requires driver 520+ for CUDA 12.x support. The NGC PyTorch container used as the build base requires CUDA 12.6 (driver 525.85+).

```bash
# Check driver version:
nvidia-smi --query-gpu=driver_version --format=csv,noheader

# Minimum required: 525.85 for CUDA 12.x
# Recommended: latest stable for your RHEL version
```

### NVIDIA container toolkit on RHEL

```bash
# Add NVIDIA repo:
dnf config-manager --add-repo https://nvidia.github.io/libnvidia-container/stable/rpm/nvidia-container-toolkit.repo
dnf install -y nvidia-container-toolkit

# Configure for use with Apptainer (CDI mode):
nvidia-ctk cdi generate --output=/etc/cdi/nvidia.yaml
nvidia-ctk config --set accept-nvidia-visible-devices-envvar-when-unprivileged=false
```

**Note**: In most HPC environments, the NVIDIA driver is installed and maintained by the HPC team at the cluster level. Verify before attempting to install or upgrade.

---

## 4. Python version

RHEL 9 ships Python 3.9 by default. vLLM requires Python 3.10+. Resolve inside the container (preferred):

- The Apptainer container uses the Python version from the NGC PyTorch base (`24.10-py3` ships Python 3.10+)
- Worker scripts run inside the container (`apptainer exec ... ray start`) — they use the container's Python, not the host's

No host Python upgrade is required. Do not assume the host Python version.

---

## 5. Shared filesystem mount

The Slurm worker nodes must mount `/shared` with the same path as the head node:

```bash
# Verify the mount exists and model weights are visible:
mount | grep shared
ls /shared/models/Qwen2.5-Coder-32B-Instruct-AWQ/
ls /shared/containers/ai-flux-vllm.sif
ls /shared/slurm/ai_flux_worker.slurm
```

If the mount is missing, contact your HPC storage admin — this is a cluster-level configuration, not a per-node setting.

---

## 6. Network connectivity to head node

```bash
# Test Ray GCS port from a Slurm node:
nc -z -w 5 ai-flux.your-cluster.example 6380 && echo "Port 6380: OPEN" || echo "Port 6380: BLOCKED"

# Test HTTPS:
curl -k --max-time 5 https://ai-flux.your-cluster.example/health

# If ports are blocked, contact HPC network admin to open:
#   TCP 6380 (Ray GCS)
#   TCP 10001-19999 (Ray ephemeral worker range)
```

---

## 7. Slurm account verification

```bash
# Verify the ai-flux-service account exists:
sacctmgr show account ai-flux-service

# Test submitting a job under the account (from the head node or compute node):
sbatch --partition=ai-flux-gpu --account=ai-flux-service \
  --wrap="echo 'Account test OK'; hostname" \
  --output=/shared/logs/ai-flux/test-%j.out

squeue -u $USER
```

---

## 8. Quick worker smoke test

Run this complete test before enabling the watcher for production use:

```bash
# Step 1: Manually submit a burst worker (from the head node):
sbatch \
  --partition=ai-flux-gpu \
  --account=ai-flux-service \
  --time=00:20:00 \
  --export=ALL,AI_FLUX_HEAD_HOST=ai-flux.your-cluster.example,AI_FLUX_RAY_PORT=6380 \
  /shared/slurm/ai_flux_worker.slurm

# Step 2: Watch the job reach RUNNING:
watch -n 5 squeue -j <job_id>

# Step 3: Verify the worker joined Ray (from the head node):
ray status --address localhost:6380
# Expected: "1 node(s) with resources" showing 1 GPU

# Step 4: Verify vLLM can use the worker (send a request):
API_KEY=$(grep AI_FLUX_API_KEY /opt/ai-flux/config.env | cut -d= -f2)
curl -k -X POST https://ai-flux.your-cluster.example/v1/chat/completions \
  -H "Authorization: Bearer ${API_KEY}" \
  -H "Content-Type: application/json" \
  -d '{"model":"ai-flux-coder","messages":[{"role":"user","content":"print hello world in python"}],"max_tokens":50}'

# Step 5: Cancel the test job:
scancel <job_id>
```

---

## Common errors and fixes

| Error | Cause | Fix |
|---|---|---|
| `AVC denied { write } on cgroup` | SELinux blocking container cgroup | `setsebool -P container_use_cgroups 1` |
| `Failed to initialize NVML` | NVIDIA driver not visible inside container | Use `--nv` flag; verify driver version |
| `Container file not found` | `/shared` not mounted, or different path | Verify shared filesystem mount path |
| `Connection refused` to Ray GCS port | Firewall blocking port 6380 | Open TCP 6380 from nodes to head |
| `sbatch: error: Invalid account` | Account not in Slurm DB | `sacctmgr add account ai-flux-service` |
| `ray: command not found` | Ray not in PATH inside container | Check container was built correctly; run `apptainer test ai-flux-vllm.sif` |
| `No module named vllm` | Wrong container or container not found | Verify `AI_FLUX_CONTAINER` path in config |
