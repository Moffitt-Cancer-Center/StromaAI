# AI_Flux — Deployment Guide

This guide walks through a full AI_Flux deployment from a bare cluster to a running, verified system. Follow the phases in order — each phase is a prerequisite for the next.

---

## Phase 1: Foundation — Networking, Storage, and Slurm

### 1.1 Hostname and DNS

Assign a static, DNS-resolvable hostname to the Proxmox VM. All downstream components reference this hostname, not a raw IP.

```bash
# On the Proxmox VM:
hostnamectl set-hostname ai-flux.your-cluster.example

# Register in your internal DNS (example bind zone entry):
# ai-flux    IN A    10.x.x.x
```

Verify resolution from a Slurm compute node:
```bash
nslookup ai-flux.your-cluster.example
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

The Proxmox VM must mount your HPC shared filesystem at `/shared` — the **same path** used on Slurm nodes. Model weights and container images must be visible at identical paths on both sides.

```bash
# Example NFS mount (add to /etc/fstab):
nfs-server.your-cluster.example:/hpc/shared  /shared  nfs  defaults,_netdev  0  0

# Mount and verify:
mount -a
ls /shared/models/
```

### 1.4 Pre-stage model weights (air-gapped)

Download on an internet-connected machine, then transfer:
```bash
# On internet-connected machine:
pip install huggingface_hub
huggingface-cli download \
  Qwen/Qwen2.5-Coder-32B-Instruct-AWQ \
  --local-dir ~/models/Qwen2.5-Coder-32B-Instruct-AWQ

# Verify checksum of every file:
sha256sum ~/models/Qwen2.5-Coder-32B-Instruct-AWQ/* > checksums.sha256

# Transfer to shared storage:
rsync -avz --progress ~/models/Qwen2.5-Coder-32B-Instruct-AWQ/ \
  cluster:/shared/models/Qwen2.5-Coder-32B-Instruct-AWQ/
rsync -avz checksums.sha256 cluster:/shared/models/

# On the cluster, verify:
cd /shared/models && sha256sum -c checksums.sha256
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
sacctmgr add account ai-flux-service Description="AI_Flux burst workers" Organization=hpc

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
mkdir -p /shared/logs/ai-flux
chmod 775 /shared/logs/ai-flux
chown aiflux:aiflux /shared/logs/ai-flux  # or appropriate service user
```

---

## Phase 2: Container Image

Build on an internet-connected machine with Apptainer installed. This step CANNOT run on the air-gapped cluster.

```bash
# Build (takes 10–20 minutes):
apptainer build ai-flux-vllm.sif deploy/containers/ai-flux-vllm.def

# Run the built-in test:
apptainer test ai-flux-vllm.sif

# Copy to shared storage:
rsync -avz --progress ai-flux-vllm.sif cluster:/shared/containers/
```

### RHEL node smoke test

Before committing to deployment, verify the container works on a RHEL Slurm GPU node:

```bash
# Run as yourself on an interactive Slurm allocation:
srun --partition=ai-flux-gpu --gpus=1 --nodes=1 --pty bash

# Inside the allocation:
apptainer exec --nv /shared/containers/ai-flux-vllm.sif \
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
useradd -r -s /sbin/nologin -d /opt/ai-flux aiflux
mkdir -p /opt/ai-flux
chown aiflux:aiflux /opt/ai-flux
```

### 3.2 Configure

```bash
cp config/config.example.env /opt/ai-flux/config.env
# Edit ALL CHANGEME values:
#   AI_FLUX_HEAD_HOST  — your actual hostname
#   AI_FLUX_API_KEY    — generate with: openssl rand -hex 32
#   AI_FLUX_MODEL_PATH — path to staged model weights
nano /opt/ai-flux/config.env
chmod 640 /opt/ai-flux/config.env
chown aiflux:aiflux /opt/ai-flux/config.env
```

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
> apptainer exec /shared/containers/ai-flux-vllm.sif vllm serve ...
> ```
> If using container-launch on the head node, update `ExecStart` in  
> `deploy/systemd/ai-flux-vllm.service` accordingly.

### 3.5 Install systemd services

```bash
# Copy service units:
cp deploy/systemd/ray-head.service        /etc/systemd/system/
cp deploy/systemd/ai-flux-vllm.service    /etc/systemd/system/
cp deploy/systemd/ai-flux-watcher.service /etc/systemd/system/

# Copy watcher script:
cp src/vllm_watcher.py /opt/ai-flux/
chmod +x /opt/ai-flux/vllm_watcher.py
chown aiflux:aiflux /opt/ai-flux/vllm_watcher.py

# Enable services (start in order):
systemctl daemon-reload
systemctl enable --now ray-head
sleep 5  # give Ray GCS time to initialize

systemctl enable --now ai-flux-vllm
# Wait for vLLM to load model (can take 2–5 minutes):
journalctl -u ai-flux-vllm -f --no-tail &
sleep 180
fg  # Ctrl+C when you see "Application startup complete"

systemctl enable --now ai-flux-watcher
```

### 3.6 Verify Ray and vLLM

```bash
# Check Ray cluster:
ray status --address localhost:6380

# Check vLLM API (no GPU workers yet — model list should still respond):
curl http://localhost:8000/health
curl http://localhost:8000/v1/models \
  -H "Authorization: Bearer $(grep AI_FLUX_API_KEY /opt/ai-flux/config.env | cut -d= -f2)"

# Service status:
systemctl status ray-head ai-flux-vllm ai-flux-watcher
```

### 3.7 Set up log rotation

```bash
cat > /etc/logrotate.d/ai-flux <<'EOF'
/shared/logs/ai-flux/*.out /shared/logs/ai-flux/*.err {
    daily
    rotate 14
    compress
    delaycompress
    missingok
    notifempty
    sharedscripts
}
EOF
```

---

## Phase 4: nginx TLS Reverse Proxy

```bash
# Install nginx:
apt-get install -y nginx

# Generate self-signed TLS certificate (valid 10 years for air-gapped use):
mkdir -p /etc/ssl/ai-flux
openssl req -x509 -nodes -days 3650 -newkey rsa:4096 \
  -keyout /etc/ssl/ai-flux/server.key \
  -out    /etc/ssl/ai-flux/server.crt \
  -subj "/CN=ai-flux.your-cluster.example" \
  -addext "subjectAltName=DNS:ai-flux.your-cluster.example"
chmod 600 /etc/ssl/ai-flux/server.key

# Deploy nginx config:
cp deploy/nginx/ai-flux.conf /etc/nginx/sites-available/ai-flux
ln -s /etc/nginx/sites-available/ai-flux /etc/nginx/sites-enabled/ai-flux
rm -f /etc/nginx/sites-enabled/default

# Verify and reload:
nginx -t
systemctl enable --now nginx

# Test HTTPS:
curl -k https://localhost/health
```

---

## Phase 5: Slurm Worker Template

```bash
# Copy to shared storage so all Slurm nodes can find it:
mkdir -p /shared/slurm
cp deploy/slurm/ai_flux_worker.slurm /shared/slurm/
chmod 755 /shared/slurm/ai_flux_worker.slurm

# Test manual burst worker submission:
sbatch \
  --partition=ai-flux-gpu \
  --account=ai-flux-service \
  --time=01:00:00 \
  --export=ALL,AI_FLUX_HEAD_HOST=ai-flux.your-cluster.example,AI_FLUX_RAY_PORT=6380 \
  /shared/slurm/ai_flux_worker.slurm

# Wait for RUNNING state and verify Ray sees the new node:
squeue -j <job_id>
ray status --address localhost:6380
```

---

## Phase 6: OOD Integration

### 6.1 Deploy OOD configuration

```bash
cp deploy/ood/ai-flux.conf /etc/ood/ai-flux.conf

# Edit: set AI_FLUX_API_KEY to EXACTLY the same value as /opt/ai-flux/config.env
# Mismatch = HTTP 401 for every user. Double-check with:
#   diff <(grep AI_FLUX_API_KEY /opt/ai-flux/config.env) \
#        <(grep AI_FLUX_API_KEY /etc/ood/ai-flux.conf)
nano /etc/ood/ai-flux.conf
chmod 640 /etc/ood/ai-flux.conf
```

### 6.2 Integrate script.sh.erb

Merge the AI_Flux block from `deploy/ood/script.sh.erb` into your existing code-server OOD app template, typically at:
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
cp monitoring/prometheus.yml /etc/prometheus/conf.d/ai-flux.yml

# Edit target hostname:
sed -i 's/ai-flux.your-cluster.example/ai-flux.YOURDOMAIN/g' \
  /etc/prometheus/conf.d/ai-flux.yml

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
API_KEY=$(grep AI_FLUX_API_KEY /opt/ai-flux/config.env | cut -d= -f2)

curl -k -X POST https://ai-flux.your-cluster.example/v1/chat/completions \
  -H "Authorization: Bearer ${API_KEY}" \
  -H "Content-Type: application/json" \
  -d '{
    "model": "ai-flux-coder",
    "messages": [{"role": "user", "content": "Write hello world in Python"}],
    "max_tokens": 100
  }'
```

### Watcher scale-up test
```bash
# Submit multiple parallel requests to trigger scale-up:
for i in {1..5}; do
  curl -k -s -o /dev/null -X POST https://ai-flux.your-cluster.example/v1/chat/completions \
    -H "Authorization: Bearer ${API_KEY}" \
    -H "Content-Type: application/json" \
    -d '{"model":"ai-flux-coder","messages":[{"role":"user","content":"Explain Slurm in 500 words"}],"max_tokens":500}' &
done

# Watch watcher logs for scale-up activity:
journalctl -u ai-flux-watcher -f
# Expected: "Scale-up triggered", "Submitted burst worker job NNNNN"

# Verify new Slurm job:
squeue -u aiflux
```

### Scale-down test
```bash
# After load test completes, wait AI_FLUX_SCALE_DOWN_IDLE_SECONDS (default 300s):
sleep 310

# Verify burst workers were cancelled:
squeue -u aiflux  # should be empty
journalctl -u ai-flux-watcher | grep -i "cancell"
```

### OOD / Kilo Code integration test
1. Log into Open OnDemand and launch a new code-server session
2. Open the Kilo Code sidebar (extension icon)
3. Verify the provider shows as connected and the model is `ai-flux-coder`
4. Send a test code completion request

---

## Operations

### Graceful drain (for maintenance or updates)

```bash
# 1. Stop the watcher so no new burst jobs are submitted:
systemctl stop ai-flux-watcher

# 2. Wait for all active requests to complete (check vLLM metrics):
watch -n 5 'curl -sk https://ai-flux.your-cluster.example/metrics | grep "vllm:num_requests"'

# 3. Cancel all active burst jobs:
squeue -u aiflux -h -o "%i" | xargs -r scancel

# 4. Stop vLLM and Ray:
systemctl stop ai-flux-vllm
systemctl stop ray-head

# 5. Perform updates, then restart in order:
systemctl start ray-head
sleep 5
systemctl start ai-flux-vllm
# Wait for vLLM to load model...
systemctl start ai-flux-watcher
```

### Updating the model

1. Stage new model weights to `/shared/models/<new-model>/`
2. Update `AI_FLUX_MODEL_PATH` and `AI_FLUX_MODEL_NAME` in `/opt/ai-flux/config.env`
3. Update `AI_FLUX_MODEL_NAME` in `/etc/ood/ai-flux.conf`
4. Follow the graceful drain procedure above
5. Restart services

### Useful logs

```bash
# All AI_Flux service logs together:
journalctl -u ray-head -u ai-flux-vllm -u ai-flux-watcher -f

# Last 50 lines from watcher:
journalctl -u ai-flux-watcher -n 50 --no-pager

# Slurm worker stdout for job NNNNN:
cat /shared/logs/ai-flux/slurm-NNNNN.out

# Watcher state (current tracked burst jobs):
cat /opt/ai-flux/watcher_state.json | python3 -m json.tool
```
