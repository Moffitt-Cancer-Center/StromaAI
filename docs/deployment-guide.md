# StromaAI — Deployment Guide

This guide walks through a full StromaAI deployment from a bare cluster to a running, verified system. Follow the phases in order — each phase is a prerequisite for the next.

---

## Phase 1: Foundation — Networking, Storage, and Slurm

### 1.1 Hostname and DNS

Assign a static, DNS-resolvable hostname to the Proxmox VM. All downstream components reference this hostname, not a raw IP.

```bash
# On the Proxmox VM:
hostnamectl set-hostname stroma-ai.your-cluster.example

# Register in your internal DNS (example bind zone entry):
# stroma-ai    IN A    10.x.x.x
```

Verify resolution from a Slurm compute node:
```bash
nslookup stroma-ai.your-cluster.example
```

### 1.2 Firewall rules

On the **Proxmox VM** (Debian — use `ufw` or `iptables`):
```bash
# Allow inbound from users / OOD
ufw allow 443/tcp    # HTTPS (nginx → vLLM)

# Allow inbound from Slurm workers
ufw allow 6380/tcp   # Ray GCS
ufw allow 10001:19999/tcp  # Ray ephemeral worker ports
ufw allow 8265/tcp   # Ray dashboard (restrict to admin CIDR in production)
```

On **Slurm compute nodes** (RHEL — use `firewall-cmd`):
```bash
# Workers initiate outbound connections to the head node; typically no
# inbound rules needed on worker nodes. Verify your cluster's policy.
# If using firewalld:
firewall-cmd --permanent --add-port=10001-19999/tcp
firewall-cmd --reload
```

### 1.3 Shared filesystem mount on Proxmox VM

The Proxmox VM must mount your HPC shared filesystem at the same path used on Slurm nodes. Model weights and container images must be visible at identical paths on both sides.

The shared root path is configurable via `STROMA_SHARED_ROOT` (default: `/share`). The installer will prompt for this value as its first question. If your cluster mounts shared storage at a different path (e.g., `/gpfs/ai`, `/mnt/nfs`), set `STROMA_SHARED_ROOT` accordingly.

```bash
# Example NFS mount (add to /etc/fstab — adjust mount path as appropriate):
nfs-server.your-cluster.example:/hpc/shared  /share  nfs  defaults,_netdev  0  0

# Mount and verify:
mount -a
ls /share/models/   # or ls /<your-shared-root>/models/
```

### 1.4 Pre-stage model weights (air-gapped)

StromaAI includes the `hfmodel-check` utility (`hfw`) on the head node for hardware-aware model selection. Use it on any internet-connected machine that has the StromaAI venv active, or install it standalone:

```bash
pip install "git+https://git@github.com/Moffitt-Cancer-Center/hfmodel-check"
```

#### Step 1: Check hardware and find a compatible model

```bash
# Show detected GPU, VRAM, and available memory:
hfw hardware

# Search for text-generation models that fit your hardware.
# Green = fits natively. Yellow = fits with quantization (recommended level shown).
# Red = too large even with Q2.
hfw search "Qwen coder" --task text-generation

# Narrow to AWQ pre-quantized variants:
hfw search "Qwen2.5-Coder-32B AWQ" --task text-generation
```

The search output shows a fit status for each result based on your actual GPU and VRAM. Models marked yellow come with a specific quantization recommendation (e.g., `~ AWQ (18.2 GB)`).

#### Step 2: Download to shared storage

`hfw download` checks hardware compatibility first, then downloads directly to `$STROMA_SHARED_ROOT/models/<repo>` if `STROMA_SHARED_ROOT` is set in the environment:

```bash
# Set your shared root so the download goes to the right place:
export STROMA_SHARED_ROOT=/share   # adjust to your mount path

# Download — hardware check runs first, quantization advice shown if needed:
hfw download Qwen/Qwen2.5-Coder-32B-Instruct-AWQ

# Or download to an explicit path:
hfw download Qwen/Qwen2.5-Coder-32B-Instruct-AWQ \
  --local-dir /share/models/Qwen2.5-Coder-32B-Instruct-AWQ
```

If the model doesn't fit natively, `hfw download` lists compatible quantization levels and asks for confirmation before proceeding.

#### Step 3: Transfer to the cluster (if downloading off-cluster)

```bash
# Verify checksum of every file:
sha256sum ~/models/Qwen2.5-Coder-32B-Instruct-AWQ/* > checksums.sha256

# Transfer to shared storage (replace /share with your STROMA_SHARED_ROOT):
rsync -avz --progress ~/models/Qwen2.5-Coder-32B-Instruct-AWQ/ \
  cluster:/share/models/Qwen2.5-Coder-32B-Instruct-AWQ/
rsync -avz checksums.sha256 cluster:/share/models/

# On the cluster, verify (replace /share with your STROMA_SHARED_ROOT):
cd /share/models && sha256sum -c checksums.sha256
```

> **Note:** If downloading directly on the head node with `STROMA_SHARED_ROOT` set, Step 3 is skipped — `hfw download` already placed the weights in the right location.
```

### 1.5 Slurm partition and account

```bash
# Create dedicated partition (adjust Nodes list for your cluster):
scontrol create partition Name=ai-flux-gpu \
  Nodes=node[001-070] \
  MaxNodes=10 \
  State=UP \
  Default=NO

# Create service account for billing:
sacctmgr add account ai-flux-service Description="StromaAI burst workers" Organization=hpc

# Create always-warm node reservation (1 permanently allocated L30):
scontrol create Reservation=ai-flux-warm \
  StartTime=now \
  Duration=UNLIMITED \
  Nodes=node001 \
  Accounts=ai-flux-service \
  Flags=MAINT,IGNORE_JOBS

# Verify:
sinfo -p ai-flux-gpu
scontrol show reservation ai-flux-warm
```

### 1.6 Log directory

```bash
# Replace /share/hpc_shared with your STROMA_SHARED_ROOT if different:
mkdir -p /share/hpc_shared/logs/stroma-ai
chmod 775 /share/hpc_shared/logs/stroma-ai
chown stromaai:stromaai /share/hpc_shared/logs/stroma-ai  # or appropriate service user
```

The installer creates this directory automatically using the `STROMA_LOG_DIR` variable (which defaults to `${STROMA_SHARED_ROOT}/logs/stroma-ai`).

---

## Phase 1.5: Pre-flight Checks

Before running the installer, use `install/preflight.sh` to verify that each node meets StromaAI requirements. The script is non-destructive and safe to re-run.

```bash
# Head node pre-flight:
sudo ./install/preflight.sh --mode=head

# Slurm worker node pre-flight (run on a representative worker):
sudo ./install/preflight.sh --mode=worker

# OOD node pre-flight:
sudo ./install/preflight.sh --mode=ood
```

**Flags:**

| Flag | Description |
|------|-------------|
| `--mode=head\|worker\|ood` | Limit checks to the specified node role (default: all) |
| `--config=FILE` | Pre-load a config.env to check paths and partitions defined there |
| `--help` | Show usage |

**Exit codes:** `0` = pass (or warnings only); `1` = one or more blocking failures.

**Head node checks:**
- OS compatibility (RHEL 8, Rocky 9, Ubuntu 22.04)
- Python 3.11+ (warning if missing — installer will install it)
- nginx (warning if missing — installer will install it)
- Ports 443 and 6380 availability
- TLS certificate at `/etc/ssl/stroma-ai/` (warning if missing — installer will generate a self-signed cert)
- Shared filesystem mounted at `STROMA_SHARED_ROOT`
- RAM ≥ 256 GB recommended (for CPU KV cache offload)
- `stromaai` system user and `/opt/stroma-ai/` directory (warning if missing — installer will create them)

**Worker node checks:**
- NVIDIA GPU detected via `nvidia-smi`
- NVIDIA driver ≥ 525 (required for FP8 KV cache)
- Apptainer or Singularity available as module or binary (warning if missing)
- Slurm commands (`sbatch`, `squeue`) in PATH
- Shared filesystem mounted and reachable
- Container SIF image present at `STROMA_CONTAINER`
- Model weights directory present at `STROMA_MODEL_PATH`
- SELinux booleans `container_use_cgroups` and `container_manage_cgroup` set
- RAM ≥ 512 GB recommended (for GPU KV cache workers)

**OOD node checks:**
- `/etc/ood/` directory present (Open OnDemand installed)
- `code-server` availability
- StromaAI OOD config at `/etc/ood/stroma-ai.conf`
- HTTPS connectivity to the head node

Address all **FAIL** items before running the installer. **WARN** items are informational — the installer can resolve many of them automatically.

---

## Phase 2 (Automated): Running the Installer

`install/install.sh` automates the steps covered in Phases 3–5. Run it after completing Phase 1 on each node type.

```bash
# Head node (Ray + vLLM + nginx + systemd):
sudo ./install/install.sh --mode=head

# Slurm worker nodes (Apptainer + NVIDIA Container Toolkit):
sudo ./install/install.sh --mode=worker

# OOD node (OOD config patching):
sudo ./install/install.sh --mode=ood
```

**Flags:**

| Flag | Description |
|------|-------------|
| `--mode=head\|worker\|ood` | **Required.** Selects the installation mode |
| `--config=FILE` | Load a pre-filled config.env; skips interactive prompts entirely |
| `--dry-run` | Print all actions without making any changes |
| `--yes` | Non-interactive: auto-confirm all prompts (API key auto-generated if not set) |
| `--help` | Show usage |

**Supported OS:** RHEL 8.x, Rocky Linux 9.x, Ubuntu 22.04.

### Interactive configuration (head mode)

On the first run, the installer prompts for site-specific values. Press Enter to accept the bracketed default:

```
Shared filesystem root [/share]:
Head node hostname [stroma-ai.your-cluster.example]:
Shared model weight path [/share/models/Qwen2.5-Coder-32B-Instruct-AWQ]:
Shared container SIF path [/share/containers/stroma-ai-vllm.sif]:
Slurm GPU partition [ai-flux-gpu]:
Slurm account [ai-flux-service]:
Max concurrent burst workers [5]:
Enter STROMA_API_KEY (or press Enter to generate one):
```

> **Important:** The **shared filesystem root** is the first prompt. Enter the actual mount path for your cluster (e.g., `/gpfs/ai`, `/mnt/nfs`). All subsequent path defaults derive from this value.
>
> If you generate an API key, the installer displays it once. Save it — you will need it for OOD configuration.

The installer writes the final configuration to `/opt/stroma-ai/config.env` and sets `chmod 640 / chown stromaai:stromaai`.

### What head mode installs

1. Creates `stromaai` system user (home: `/opt/stroma-ai`, no shell)
2. Creates directories: `/opt/stroma-ai/{src,state}`, `/etc/ssl/stroma-ai/`, `${STROMA_LOG_DIR}`
3. Installs system packages (Python 3.11, pip, nginx) for the detected OS
4. Creates a Python virtualenv in `/opt/stroma-ai/venv` and installs Ray and vLLM
5. Writes `/opt/stroma-ai/config.env` with all configuration values
6. Deploys `src/vllm_watcher.py` to `/opt/stroma-ai/src/` with execute permissions
7. Deploys `deploy/slurm/stroma_ai_worker.slurm` to `${STROMA_SHARED_ROOT}/slurm/`
8. Deploys and enables nginx with TLS termination; generates a self-signed certificate if none exists
9. Installs systemd service units (`ray-head`, `stroma-ai-vllm`, `stroma-ai-watcher`)
10. Patches `ReadWritePaths` in systemd units to include `STROMA_SHARED_ROOT`
11. Configures SELinux booleans (RHEL) or AppArmor (Ubuntu) for container and cgroup access
12. Opens firewall ports (6380, 443) via `firewall-cmd` (RHEL) or `ufw` (Ubuntu)
13. Enables and starts `ray-head`, waits for GCS, then starts `stroma-ai-vllm` and `stroma-ai-watcher`
14. Installs `deploy/logrotate/stroma-ai` to `/etc/logrotate.d/stroma-ai`

### What worker mode installs

1. Updates system packages
2. Installs Apptainer from EPEL (RHEL) or official PPA (Ubuntu), if not already present
3. Configures Apptainer for rootless use and GPU binding
4. Installs NVIDIA Container Toolkit and runs `nvidia-ctk cdi generate`
5. Configures SELinux booleans for Apptainer + GPU (`container_use_cgroups`, `container_manage_cgroup`, `container_use_devices`)
6. Opens Ray ephemeral ports (10001–19999) in the firewall
7. Creates the shared log directory (`${STROMA_LOG_DIR}`) on the worker

### Using a pre-filled config file

To automate deployment across multiple nodes without interactive prompts:

```bash
# Copy and fill in config template from the repo:
cp config/config.example.env /tmp/site.env
nano /tmp/site.env   # Set all CHANGEME values

# Run installer non-interactively on each node type:
sudo ./install/install.sh --mode=head   --config=/tmp/site.env --yes
sudo ./install/install.sh --mode=worker --config=/tmp/site.env --yes
sudo ./install/install.sh --mode=ood    --config=/tmp/site.env --yes
```

Build on an internet-connected machine with Apptainer installed. This step CANNOT run on the air-gapped cluster.

```bash
# Build (takes 10–20 minutes):
apptainer build stroma-ai-vllm.sif deploy/containers/stroma-ai-vllm.def

# Run the built-in test:
apptainer test stroma-ai-vllm.sif

# Copy to shared storage (replace /share with your STROMA_SHARED_ROOT):
rsync -avz --progress stroma-ai-vllm.sif cluster:/share/containers/
```

### RHEL node smoke test

Before committing to deployment, verify the container works on a RHEL Slurm GPU node:

```bash
# Run as yourself on an interactive Slurm allocation:
srun --partition=ai-flux-gpu --gpus=1 --nodes=1 --pty bash

# Inside the allocation (replace /share with your STROMA_SHARED_ROOT):
apptainer exec --nv /share/containers/stroma-ai-vllm.sif \
  python3 -c "
import torch, vllm
print('CUDA available:', torch.cuda.is_available())
print('GPU name:', torch.cuda.get_device_name(0))
print('vLLM version:', vllm.__version__)
"
exit
```

See [rhel-slurm-setup.md](rhel-slurm-setup.md) if this step fails with SELinux or NVIDIA errors.

---

## Phase 3: Proxmox VM — Ray Head and vLLM Services

### 3.1 Create system user

```bash
useradd -r -s /sbin/nologin -d /opt/stroma-ai stromaai
mkdir -p /opt/stroma-ai
chown stromaai:stromaai /opt/stroma-ai
```

### 3.2 Configure

> **Note:** If you used the automated installer (`install/install.sh --mode=head`), this step was performed automatically. The config is at `/opt/stroma-ai/config.env` and the installer already set `STROMA_SHARED_ROOT` as the first interactive prompt.

```bash
cp config/config.example.env /opt/stroma-ai/config.env
# Edit ALL CHANGEME values:
#   STROMA_SHARED_ROOT — your shared filesystem root (e.g., /share, /gpfs/ai)
#   STROMA_HEAD_HOST  — your actual hostname
#   STROMA_API_KEY    — generate with: openssl rand -hex 32
#   STROMA_MODEL_PATH — path to staged model weights
nano /opt/stroma-ai/config.env
chmod 640 /opt/stroma-ai/config.env
chown stromaai:stromaai /opt/stroma-ai/config.env
```

**Key configuration variables:**

| Variable | Default | Description |
|----------|---------|-------------|
| `STROMA_SHARED_ROOT` | `/share` | Shared filesystem root — all shared path defaults derive from this |
| `STROMA_HEAD_HOST` | *(required)* | FQDN or hostname of the head node |
| `STROMA_API_KEY` | *(required)* | Bearer token for API authentication |
| `STROMA_MODEL_PATH` | `${SHARED_ROOT}/models/Qwen2.5-Coder-32B-Instruct-AWQ` | Path to model weights |
| `STROMA_MODEL_NAME` | `stroma-ai-coder` | Model alias served by vLLM |
| `STROMA_CONTAINER` | `${SHARED_ROOT}/containers/stroma-ai-vllm.sif` | Apptainer SIF image path |
| `STROMA_SLURM_PARTITION` | `ai-flux-gpu` | Slurm GPU partition for burst workers |
| `STROMA_SLURM_ACCOUNT` | `ai-flux-service` | Slurm account for burst jobs |
| `STROMA_MAX_BURST_WORKERS` | `5` | Maximum concurrent burst Slurm jobs |
| `STROMA_SLURM_CPUS` | `64` | CPUs per burst worker job (`--cpus-per-task`) |
| `STROMA_SLURM_MEM` | `900G` | Memory per burst worker job (`--mem`) |
| `STROMA_NUMA_BIND` | *(unset)* | Optional NUMA node binding (e.g., `0`) — leave unset to disable |
| `STROMA_VLLM_QUANTIZATION` | `awq` | vLLM quantization method (`awq`, `fp8`, `none`) |
| `STROMA_KV_CACHE_DTYPE` | `auto` | KV cache dtype — use `fp8` for L30 / H100, `auto` for A100 |
| `STROMA_GPU_MEM_UTIL` | `0.85` | GPU memory utilization fraction for vLLM |
| `STROMA_CPU_OFFLOAD_GB` | `200` | CPU memory to use for KV cache offload (GB) |
| `STROMA_SCALE_UP_THRESHOLD` | `5` | Queued requests before a burst worker is submitted |
| `STROMA_SCALE_DOWN_IDLE_SECONDS` | `300` | Idle seconds before a burst worker is cancelled |
| `STROMA_LOG_DIR` | `${SHARED_ROOT}/logs/stroma-ai` | Slurm job output log directory |

Use `scripts/check-config.sh` to validate config before starting services (see [Operational Scripts](#operational-scripts)).

### 3.3 Install Ray on the Proxmox VM

The VM needs Ray (to run the watcher and connect to the cluster) but does NOT need vLLM or CUDA.

```bash
apt-get install -y python3 python3-pip
pip3 install ray==2.40.0 requests==2.32.3

# Verify Ray can be invoked:
ray --version
```

### 3.4 Install vLLM on the Proxmox VM

vLLM is needed to start the API server process on the head node. Even though inference runs on GPU workers, the head node runs the scheduler and API layer.

```bash
pip3 install vllm==0.7.3
```

> **Alternative**: Run vLLM inside the Apptainer container on the head node too:
> ```bash
> apptainer exec /share/containers/stroma-ai-vllm.sif vllm serve ...   # replace /share with STROMA_SHARED_ROOT
> ```
> If using container-launch on the head node, update `ExecStart` in  
> `deploy/systemd/stroma-ai-vllm.service` accordingly.

### 3.5 Install systemd services

```bash
# Copy service units:
cp deploy/systemd/ray-head.service        /etc/systemd/system/
cp deploy/systemd/stroma-ai-vllm.service    /etc/systemd/system/
cp deploy/systemd/stroma-ai-watcher.service /etc/systemd/system/

# Copy watcher script:
cp src/vllm_watcher.py /opt/stroma-ai/
chmod +x /opt/stroma-ai/vllm_watcher.py
chown stromaai:stromaai /opt/stroma-ai/vllm_watcher.py

# Enable services (start in order):
systemctl daemon-reload
systemctl enable --now ray-head
sleep 5  # give Ray GCS time to initialize

systemctl enable --now stroma-ai-vllm
# Wait for vLLM to load model (can take 2–5 minutes):
journalctl -u stroma-ai-vllm -f --no-tail &
sleep 180
fg  # Ctrl+C when you see "Application startup complete"

systemctl enable --now stroma-ai-watcher
```

### 3.6 Verify Ray and vLLM

```bash
# Check Ray cluster:
ray status --address localhost:6380

# Check vLLM API (no GPU workers yet — model list should still respond):
curl http://localhost:8000/health
curl http://localhost:8000/v1/models \
  -H "Authorization: Bearer $(grep STROMA_API_KEY /opt/stroma-ai/config.env | cut -d= -f2)"

# Service status:
systemctl status ray-head stroma-ai-vllm stroma-ai-watcher
```

### 3.7 Set up log rotation

```bash
# Install the included logrotate config:
cp deploy/logrotate/stroma-ai /etc/logrotate.d/stroma-ai
chmod 644 /etc/logrotate.d/stroma-ai

# Verify (dry run):
logrotate --debug /etc/logrotate.d/stroma-ai
```

The included config rotates Slurm job logs daily, retains 30 days, and uses `copytruncate` to avoid service restarts. If you used the automated installer, this step was performed automatically.

---

## Phase 4: nginx TLS Reverse Proxy

```bash
# Install nginx:
apt-get install -y nginx

# Generate self-signed TLS certificate (valid 10 years for air-gapped use):
mkdir -p /etc/ssl/stroma-ai
openssl req -x509 -nodes -days 3650 -newkey rsa:4096 \
  -keyout /etc/ssl/stroma-ai/server.key \
  -out    /etc/ssl/stroma-ai/server.crt \
  -subj "/CN=stroma-ai.your-cluster.example" \
  -addext "subjectAltName=DNS:stroma-ai.your-cluster.example"
chmod 600 /etc/ssl/stroma-ai/server.key

# Deploy nginx config:
cp deploy/nginx/stroma-ai.conf /etc/nginx/sites-available/stroma-ai
ln -s /etc/nginx/sites-available/stroma-ai /etc/nginx/sites-enabled/stroma-ai
rm -f /etc/nginx/sites-enabled/default

# Verify and reload:
nginx -t
systemctl enable --now nginx

# Test HTTPS:
curl -k https://localhost/health
```

---

## Phase 5 (Manual Reference): Slurm Worker Template

> **Note:** If you used the automated installer (`install/install.sh --mode=head`), the Slurm script was deployed to `${STROMA_SHARED_ROOT}/slurm/stroma_ai_worker.slurm` automatically.

```bash
# Copy to shared storage so all Slurm nodes can find it:
mkdir -p /share/slurm    # replace /share with your STROMA_SHARED_ROOT
cp deploy/slurm/stroma_ai_worker.slurm /share/slurm/
chmod 755 /share/slurm/stroma_ai_worker.slurm

# Test manual burst worker submission:
sbatch \
  --partition=ai-flux-gpu \
  --account=ai-flux-service \
  --time=01:00:00 \
  --export=ALL,STROMA_HEAD_HOST=stroma-ai.your-cluster.example,STROMA_RAY_PORT=6380 \
  /share/slurm/stroma_ai_worker.slurm

# Wait for RUNNING state and verify Ray sees the new node:
squeue -j <job_id>
ray status --address localhost:6380
```

---

## Phase 6: OOD Integration

### 6.1 Deploy OOD configuration

```bash
cp deploy/ood/stroma-ai.conf /etc/ood/stroma-ai.conf

# Edit: set STROMA_API_KEY to EXACTLY the same value as /opt/stroma-ai/config.env
# Mismatch = HTTP 401 for every user. Double-check with:
#   diff <(grep STROMA_API_KEY /opt/stroma-ai/config.env) \
#        <(grep STROMA_API_KEY /etc/ood/stroma-ai.conf)
nano /etc/ood/stroma-ai.conf
chmod 640 /etc/ood/stroma-ai.conf
```

### 6.2 Integrate script.sh.erb

Merge the StromaAI block from `deploy/ood/script.sh.erb` into your existing code-server OOD app template, typically at:
```
/var/www/ood/apps/sys/code-server/template/script.sh.erb
```

The script installs the Kilo Code extension and injects the provider settings on each new session.

### 6.3 Verify Kilo Code settings keys

After running a test session, verify the injected settings are correct:
```bash
# SSH into the OOD compute node during an active session, then:
cat ~/.local/share/code-server/User/settings.json | python3 -c "
import json, sys
s = json.load(sys.stdin)
kilo_keys = {k: v for k, v in s.items() if 'kilocode' in k.lower()}
print(json.dumps(kilo_keys, indent=2))
"
```

If Kilo Code doesn't connect to the endpoint, inspect the extension's actual settings key names:
```bash
cat ~/.local/share/code-server/extensions/kilocode.kilo-code-*/package.json | \
  python3 -c "
import json, sys
d = json.load(sys.stdin)
props = d.get('contributes', {}).get('configuration', {})
if isinstance(props, list):
    props = props[0]
keys = props.get('properties', {})
for k in keys:
    if any(x in k.lower() for x in ['provider', 'baseurl', 'apikey', 'model']):
        print(k)
"
```

Update the settings dict in `deploy/ood/script.sh.erb` if the keys differ from `kilocode.*`.

---

## Phase 7: Monitoring

```bash
# Add Prometheus scrape config:
cp monitoring/prometheus.yml /etc/prometheus/conf.d/stroma-ai.yml

# Edit target hostname:
sed -i 's/stroma-ai.your-cluster.example/stroma-ai.YOURDOMAIN/g' \
  /etc/prometheus/conf.d/stroma-ai.yml

systemctl reload prometheus
```

Verify metrics are scraping:
```
http://prometheus.your-cluster.example:9090/targets
```

---

## Phase 8: End-to-End Verification

### API test
```bash
API_KEY=$(grep STROMA_API_KEY /opt/stroma-ai/config.env | cut -d= -f2)

curl -k -X POST https://stroma-ai.your-cluster.example/v1/chat/completions \
  -H "Authorization: Bearer ${API_KEY}" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "stroma-ai-coder",
    "messages": [{"role": "user", "content": "Write hello world in Python"}],
    "max_tokens": 100
  }'
```

### Watcher scale-up test
```bash
# Submit multiple parallel requests to trigger scale-up:
for i in {1..5}; do
  curl -k -s -o /dev/null -X POST https://stroma-ai.your-cluster.example/v1/chat/completions \
    -H "Authorization: Bearer ${API_KEY}" \
    -H "Content-Type: application/json" \
    -d '{"model":"stroma-ai-coder","messages":[{"role":"user","content":"Explain Slurm in 500 words"}],"max_tokens":500}' &
done

# Watch watcher logs for scale-up activity:
journalctl -u stroma-ai-watcher -f
# Expected: "Scale-up triggered", "Submitted burst worker job NNNNN"

# Verify new Slurm job:
squeue -u stromaai
```

### Scale-down test
```bash
# After load test completes, wait STROMA_SCALE_DOWN_IDLE_SECONDS (default 300s):
sleep 310

# Verify burst workers were cancelled:
squeue -u stromaai  # should be empty
journalctl -u stroma-ai-watcher | grep -i "cancell"
```

### OOD / Kilo Code integration test
1. Log into Open OnDemand and launch a new code-server session
2. Open the Kilo Code sidebar (extension icon)
3. Verify the provider shows as connected and the model is `stroma-ai-coder`
4. Send a test code completion request

---

## Operations

### Graceful drain (for maintenance or updates)

For planned maintenance use `scripts/drain-and-restart.sh`, which automates the full drain sequence with request-count polling and health-check gating:

```bash
scripts/drain-and-restart.sh
scripts/drain-and-restart.sh --drain-timeout 300 --start-timeout 600
```

For manual control:

```bash
# 1. Stop the watcher so no new burst jobs are submitted:
systemctl stop stroma-ai-watcher

# 2. Wait for all active requests to complete (check vLLM metrics):
watch -n 5 'curl -sk https://stroma-ai.your-cluster.example/metrics | grep "vllm:num_requests"'

# 3. Cancel all active burst jobs:
squeue -u stromaai -h -o "%i" | xargs -r scancel

# 4. Stop vLLM and Ray:
systemctl stop stroma-ai-vllm
systemctl stop ray-head

# 5. Perform updates, then restart in order:
systemctl start ray-head
sleep 5
systemctl start stroma-ai-vllm
# Wait for vLLM to load model...
systemctl start stroma-ai-watcher
```

### Updating the model

1. Stage new model weights to `${STROMA_SHARED_ROOT}/models/<new-model>/` (default: `/share/models/<new-model>/`)
2. Update `STROMA_MODEL_PATH` and `STROMA_MODEL_NAME` in `/opt/stroma-ai/config.env`
3. Update `STROMA_MODEL_NAME` in `/etc/ood/stroma-ai.conf`
4. Follow the graceful drain procedure below (or use `scripts/drain-and-restart.sh`)
5. Restart services

### Useful logs

```bash
# All StromaAI service logs together:
journalctl -u ray-head -u stroma-ai-vllm -u stroma-ai-watcher -f

# Last 50 lines from watcher:
journalctl -u stroma-ai-watcher -n 50 --no-pager

# Slurm worker stdout for job NNNNN:
cat /share/logs/stroma-ai/slurm-NNNNN.out   # replace /share with STROMA_SHARED_ROOT

# Watcher state (current tracked burst jobs):
cat /opt/stroma-ai/watcher_state.json | python3 -m json.tool
```

> **Tip:** Use `scripts/status.sh` for an at-a-glance dashboard showing service states, active Slurm jobs, GPU utilization, and recent logs. Use `scripts/debug-bundle.sh` to generate a redacted support tarball. See [Operational Scripts](#operational-scripts).

---

## Operational Scripts

Five helper scripts are included in `scripts/` for day-to-day operations. All scripts read `/opt/stroma-ai/config.env` by default.

### `scripts/status.sh` — System dashboard

Displays a combined view of systemd service states, active Slurm burst jobs, GPU utilization, watcher state file summary, and recent journal entries.

```bash
scripts/status.sh
```

### `scripts/check-config.sh` — Config validation

Validates `/opt/stroma-ai/config.env` before starting or restarting services. Checks required variables, detects CHANGEME placeholders, validates hostname format, port ranges, and path existence. Verifies the Slurm partition exists.

```bash
scripts/check-config.sh
scripts/check-config.sh --config /path/to/other-config.env
```

Exit codes: `0` = pass; `1` = errors found; `2` = config file not found.

### `scripts/rotate-api-key.sh` — Zero-downtime key rotation

Generates a new API key, updates both `/opt/stroma-ai/config.env` and `/etc/ood/stroma-ai.conf`, and performs a rolling restart (vLLM first, then watcher) with health-check gating. Creates a timestamped backup of the old config.

```bash
scripts/rotate-api-key.sh              # interactive
scripts/rotate-api-key.sh --dry-run   # preview without changes
scripts/rotate-api-key.sh --config /opt/stroma-ai/config.env
```

> **Important:** After rotation, update any external clients or CI systems that hold the old API key.

### `scripts/debug-bundle.sh` — Support tarball

Collects journals (500 lines each), watcher state, redacted config, `squeue` output, `nvidia-smi`, Ray status, and vLLM endpoint responses into a single `.tar.gz` for support escalation.

```bash
scripts/debug-bundle.sh                       # output to /tmp/stroma-ai-debug-<timestamp>.tar.gz
scripts/debug-bundle.sh /path/to/output.tar.gz
```

> **Warning:** Review the tarball before sharing — API keys may appear in journal log lines even after config redaction.

### `scripts/drain-and-restart.sh` — Planned maintenance restart

Performs a zero-dropped-request restart for planned maintenance:
1. Stops the watcher (no new burst jobs submitted)
2. Polls `/metrics` until in-flight request count reaches zero
3. Stops vLLM and Ray
4. Starts Ray, waits for GCS
5. Starts vLLM with a health-check gate
6. Restarts the watcher

```bash
scripts/drain-and-restart.sh
scripts/drain-and-restart.sh --drain-timeout 300 --start-timeout 600
```

Use this instead of a raw `systemctl restart` during business hours.

---

## Uninstallation

`install/uninstall.sh` removes StromaAI from a head node. It does **not** remove system packages (nginx, Python, NVIDIA toolkit) that may be used by other services.

```bash
sudo ./install/uninstall.sh         # interactive, prompts before each destructive step
sudo ./install/uninstall.sh --yes   # non-interactive
```

**What is removed:**
- systemd service units: `ray-head`, `stroma-ai-vllm`, `stroma-ai-watcher`
- `/opt/stroma-ai/` — source files, Python venv, config, state
- `/etc/nginx/conf.d/stroma-ai.conf` (RHEL/Rocky) or `/etc/nginx/sites-*/stroma-ai` (Ubuntu)
- `/etc/ood/stroma-ai.conf`
- `/etc/ssl/stroma-ai/` (TLS keys — confirmed interactively)
- `stromaai` system user (confirmed interactively)
- Firewall rules (port 6380, 80, 443) — best-effort, non-fatal if rules are absent

**What is NOT removed (intentionally):**
- `${STROMA_SHARED_ROOT}/containers/` — container images are your data
- `${STROMA_SHARED_ROOT}/models/` — model weights are your data
- `${STROMA_SHARED_ROOT}/logs/stroma-ai/` — preserved as audit trail
- System packages: nginx, Python 3.11, NVIDIA Container Toolkit

To fully clean up shared storage after uninstallation, remove those directories manually when you are certain they are no longer needed.
