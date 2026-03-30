# StromaAI

> *"Be water, my friend."* — Bruce Lee

StromaAI is an open-source **Hybrid AI Orchestration Platform** purpose-built for HPC research computing environments. It bridges a persistent, lightweight control node with dynamically bursting Slurm GPU workers to deliver on-demand, OpenAI-compatible LLM inference — without permanently reserving expensive GPU resources.

Built and reference-deployed at **Moffitt Cancer Center HPC**.

---

## The problem it solves

Research HPC clusters have a fundamental tension: GPU nodes are shared across dozens of research workloads, but AI-assisted development tools (like Kilo Code / GitHub Copilot) need a *always-available* API endpoint. You can't leave GPU nodes permanently allocated — that blocks cancer research. But you can't ask researchers to wait 20 minutes for a Slurm job to start every time they open VS Code.

StromaAI resolves this by:

1. Running a **permanent vLLM API server** on a small Proxmox VM (no GPU needed) — always available at a stable HTTPS endpoint
2. **Watching the request queue** via a watcher daemon that polls vLLM's internal metrics
3. **Bursting GPU workers on demand** via `sbatch` when the queue grows beyond a threshold — workers join a Ray cluster and begin serving inference within ~60s
4. **Returning GPUs to the research pool** automatically when idle — no wasted allocation

---

## Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│  OOD Users (browser-based code-server sessions)                  │
│    Kilo Code Extension ──HTTPS──► nginx TLS proxy                │
└─────────────────────────────┬────────────────────────────────────┘
                              │ :443
             ┌────────────────▼────────────────┐
             │  Head Node — Proxmox VM (Debian) │
             │                                  │
             │  ┌──────────────────────────┐    │
             │  │  nginx (TLS termination) │    │
             │  │  ├─ rate limiting        │    │
             │  │  └─ WebSocket support    │    │
             │  └──────────┬───────────────┘    │
             │             │ :8000 (loopback)   │
             │  ┌──────────▼───────────────┐    │
             │  │  vLLM API Server         │    │
             │  │  (OpenAI-compatible)     │◄───┼── EnvironmentFile config.env
             │  └──────────┬───────────────┘    │
             │             │ Ray GCS :6380       │
             │  ┌──────────▼───────────────┐    │
             │  │  Ray Head Node           │    │
             │  │  --num-cpus=0            │    │
             │  │  --num-gpus=0            │    │
             │  └──────────┬───────────────┘    │
             │             │                    │
             │  ┌──────────▼───────────────┐    │
             │  │  vllm_watcher.py         │    │
             │  │  polls /metrics every Ns │    │
             │  │  submits/cancels sbatch  │    │
             │  └──────────┬───────────────┘    │
             └─────────────┼────────────────────┘
                           │ sbatch (on demand)
             ┌─────────────▼────────────────────┐
             │  Slurm GPU Nodes (RHEL-family)    │
             │                                  │
             │  Worker 0: A30 GPU               │
             │    apptainer exec --nv           │
             │    ray start --address=HEAD:6380 │
             │    vllm serve MODEL_PATH         │
             │                                  │
             │  Worker 1 … Worker N             │
             │    (burst on demand, same setup) │
             └──────────────────────────────────┘
```

---

## Core capabilities

### Dynamic burst scaling
The watcher daemon (`src/vllm_watcher.py`) continuously polls vLLM's `/metrics` endpoint. When the number of waiting requests exceeds `STROMA_SCALE_UP_THRESHOLD`, it submits a new Slurm job. Each job runs the Apptainer container, has Ray join the existing head-node cluster, and begins serving inference. When all burst workers have been idle for `STROMA_SCALE_DOWN_IDLE_SECONDS`, they are cancelled via `scancel` and GPUs return to the pool.

Key behaviors:
- **Cooldown gating** — a configurable delay between scale-up events prevents over-provisioning on bursty traffic
- **Max worker cap** — `STROMA_MAX_BURST_WORKERS` prevents monopolizing the cluster
- **Reconciliation loop** — the watcher reconciles its internal job state against `squeue` output on every tick, recovering cleanly from node failures, job preemption, or missed signals
- **Warm reservation** — an optional always-warm Slurm reservation keeps one node pre-allocated for near-instant first-response

### OpenAI-compatible API
vLLM provides a fully OpenAI-compatible REST API (`/v1/chat/completions`, `/v1/completions`, `/v1/models`). Any tool that supports a custom OpenAI base URL works out of the box: Kilo Code, Continue.dev, GitHub Copilot proxies, curl, LangChain, LlamaIndex, and more.

### Open OnDemand (OOD) integration
`deploy/ood/script.sh.erb` is a drop-in addition to the standard OOD code-server app template. When a researcher launches a VS Code session via OOD, it automatically:
- Reads `STROMA_API_KEY` and `STROMA_HEAD_HOST` from the sourced config
- Writes Kilo Code's settings into the session's VS Code profile
- Sets the base URL to the internal HTTPS endpoint
- Marks the config block so it can be re-applied on session restart without duplicating settings

Researchers get a fully pre-configured AI coding assistant with zero manual setup.

### Production-grade deployment
- **nginx TLS termination** — HTTPS-only, configurable certificate, WebSocket support for streaming responses, per-IP rate limiting
- **systemd service units** — `ray-head`, `stroma-ai-vllm`, and `stroma-ai-watcher` with `Restart=on-failure`, journal logging, and security sandboxing
- **Apptainer/Singularity container** — reproducible, portable GPU environment pinned to specific vLLM, Ray, and CUDA versions; builds once, runs on any HPC node
- **Automated installer** — `install/install.sh` with interactive prompts, dry-run mode (`STROMA_DRY_RUN=1`), and automated mode (`STROMA_YES=1`) for Ansible/Puppet integration
- **Preflight checks** — `install/preflight.sh` validates SELinux, NVIDIA drivers, kernel modules, Slurm accounts, firewall rules, and directory permissions before install
- **Operational scripts** — `scripts/` contains helpers for status, key rotation, drain-and-restart, config validation, and debug bundle generation

### Bring any model — hardware-aware model selection
StromaAI is not tied to any specific model. The `hfw` command (`hfmodel-check`, installed in the venv) discovers, evaluates, and downloads any Hugging Face model against your actual hardware before you commit to a download:

```bash
# Activate the StromaAI venv on any internet-connected machine:
source /opt/stroma-ai/venv/bin/activate

# See what GPU and VRAM are available:
hfw hardware

# Search the Hub — results are colour-coded by fit:
#   green  = fits natively
#   yellow = fits with quantization (recommended level shown)
#   red    = too large even at Q2
hfw search "llama 70B" --task text-generation
hfw search "mistral instruct AWQ" --task text-generation
hfw search "deepseek coder" --task text-generation

# Download once you've picked a model — hardware check runs first:
export STROMA_SHARED_ROOT=/share   # downloads go to $STROMA_SHARED_ROOT/models/<repo>
hfw download meta-llama/Llama-3-8B-Instruct

# Or specify an explicit destination:
hfw download mistralai/Mistral-7B-Instruct-v0.3 \
  --local-dir /share/models/Mistral-7B-Instruct-v0.3
```

If a model is slightly too large, `hfw download` lists compatible quantization variants and asks for confirmation before proceeding. Once downloaded, update two variables in `/opt/stroma-ai/config.env` and restart the vLLM service:

```bash
# Switch the served model (no reinstall, no container rebuild required):
STROMA_MODEL_PATH=/share/models/<new-model-dir>
STROMA_MODEL_NAME=<alias-for-api>

systemctl restart stroma-ai-vllm
```

All vLLM-supported architectures work — dense, MoE, vision-language, and multimodal — subject to fitting in available VRAM across the burst worker nodes.

### Monitoring
`monitoring/prometheus.yml` provides a complete Prometheus scrape configuration targeting vLLM's `/metrics` endpoint, with example alert rules for:
- GPU KV cache saturation (> 85% VRAM)
- Request queue backlog (> 20 waiting)
- CPU KV cache pressure
- vLLM endpoint availability

### Configurable install path
`STROMA_INSTALL_DIR` (default: `/opt/stroma-ai`) controls the installation root. Systemd units are patched at deploy time, making it trivial to run multiple environments (dev/staging/prod) on the same head node.

---

## Hardware requirements

| Component | Spec |
|---|---|
| Head node | Proxmox VM, no GPU, 4–8 cores, ≥32GB RAM, Debian 11/12 |
| GPU nodes | NVIDIA A30 24GB (Ampere, CC 8.0), ≥64 cores, ≥512GB RAM, RHEL-family |
| Shared storage | NFS/Lustre/GPFS mounted at `/share` on all nodes |
| Model | Qwen/Qwen2.5-Coder-32B-Instruct-AWQ (~18.5GB VRAM with AWQ) |
| Network | TCP: 443 (API), 6380 (Ray GCS), 10001–19999 (Ray workers) |

The Qwen2.5-Coder-32B-Instruct-AWQ model fits comfortably in 24GB with `--gpu-memory-utilization 0.85`, leaving headroom for KV cache. Any vLLM-supported model that fits in your GPU's VRAM will work — use `hfw` (see [Bring any model](#bring-any-model--hardware-aware-model-selection) above) to find and validate a model before downloading.

---

## Quick start

### 1. Run the automated installer (recommended)

```bash
git clone https://github.com/Moffitt-Cancer-Center/StromaAI.git
cd StromaAI
sudo ./install/install.sh --mode=head
```

The installer prompts for site-specific values (shared root, hostname, Slurm partition) and handles everything: system user creation, directory layout, Python venv, nginx config, TLS cert generation, systemd unit deployment, and service startup.

### 2. Or follow manual steps

#### Configure

```bash
cp config/config.example.env /opt/stroma-ai/config.env
# Edit all CHANGEME values and site-specific settings
chmod 640 /opt/stroma-ai/config.env
chown stromaai:stromaai /opt/stroma-ai/config.env
```

#### Build the container (on an internet-connected machine)

```bash
apptainer build /share/containers/stroma-ai-vllm.sif deploy/containers/stroma-ai-vllm.def
```

#### Deploy services

```bash
useradd -r -s /sbin/nologin stromaai
cp deploy/systemd/*.service /etc/systemd/system/
cp src/vllm_watcher.py /opt/stroma-ai/src/
systemctl daemon-reload
systemctl enable --now ray-head stroma-ai-vllm stroma-ai-watcher
```

#### Configure nginx TLS

```bash
mkdir -p /etc/ssl/stroma-ai
openssl req -x509 -nodes -days 3650 -newkey rsa:4096 \
  -keyout /etc/ssl/stroma-ai/server.key \
  -out    /etc/ssl/stroma-ai/server.crt \
  -subj "/CN=stroma-ai.your-cluster.example"
cp deploy/nginx/stroma-ai.conf /etc/nginx/sites-available/stroma-ai
ln -s /etc/nginx/sites-available/stroma-ai /etc/nginx/sites-enabled/stroma-ai
nginx -t && systemctl reload nginx
```

#### Configure Slurm partition and warm reservation

```bash
scontrol create partition Name=stroma-ai-gpu Nodes=node[001-070] MaxNodes=10 State=UP
sacctmgr add account stroma-ai-service Description="StromaAI burst workers"
mkdir -p /share/logs/stroma-ai /share/slurm
cp deploy/slurm/stroma_ai_worker.slurm /share/slurm/

# Always-warm reservation — 1 node pre-allocated for fast first response:
scontrol create Reservation=stroma-ai-warm \
  StartTime=now Duration=UNLIMITED \
  Nodes=node001 \
  Accounts=stroma-ai-service \
  Flags=MAINT,IGNORE_JOBS
```

#### Configure OOD integration

```bash
cp deploy/ood/stroma-ai.conf /etc/ood/stroma-ai.conf
chmod 640 /etc/ood/stroma-ai.conf
# Edit: set STROMA_API_KEY to match /opt/stroma-ai/config.env
# Merge deploy/ood/script.sh.erb into your code-server OOD app template
```

#### Verify

```bash
curl -k https://stroma-ai.your-cluster.example/health
curl -k https://stroma-ai.your-cluster.example/v1/models \
  -H "Authorization: Bearer YOUR_API_KEY"
journalctl -u stroma-ai-vllm -u stroma-ai-watcher -f
```

---

## File structure

```
stroma-ai/
├── config/
│   └── config.example.env         # All configuration variables with documentation
├── deploy/
│   ├── containers/
│   │   └── stroma-ai-vllm.def     # Apptainer build definition (pinned versions)
│   ├── logrotate/
│   │   └── stroma-ai              # Log rotation config for Slurm output logs
│   ├── nginx/
│   │   └── stroma-ai.conf         # nginx TLS reverse proxy + rate limiting
│   ├── ood/
│   │   ├── stroma-ai.conf         # OOD config (API key + endpoint)
│   │   └── script.sh.erb          # code-server session auto-configuration
│   ├── slurm/
│   │   └── stroma_ai_worker.slurm # Slurm burst worker sbatch script
│   └── systemd/
│       ├── ray-head.service        # Ray head node (always-on)
│       ├── stroma-ai-vllm.service  # vLLM API server (always-on)
│       └── stroma-ai-watcher.service # Dynamic scaler daemon (always-on)
├── docs/
│   ├── deployment-guide.md        # Full step-by-step deployment walkthrough
│   └── rhel-slurm-setup.md        # RHEL SELinux + NVIDIA pre-flight checklist
├── install/
│   ├── install.sh                 # Automated installer (head/worker/ood modes)
│   ├── preflight.sh               # Pre-install validation checker
│   ├── uninstall.sh               # Clean uninstaller
│   └── lib/                       # Shared installer library functions
├── monitoring/
│   └── prometheus.yml             # Prometheus scrape config + alert rules
├── scripts/
│   ├── check-config.sh            # Validate config.env before starting services
│   ├── debug-bundle.sh            # Collect diagnostic info for support
│   ├── drain-and-restart.sh       # Safe rolling restart with worker drain
│   ├── rotate-api-key.sh          # Zero-downtime API key rotation
│   └── status.sh                  # Live service and queue status
├── src/
│   └── vllm_watcher.py            # Core burst orchestration daemon
├── tests/
│   ├── integration/smoke_test.sh  # End-to-end API smoke test
│   └── unit/test_watcher.py       # 48 unit tests for watcher logic
├── CONTRIBUTING.md
├── SECURITY.md
└── LICENSE                        # Apache 2.0
```

---

## OS compatibility

| Component | OS | Notes |
|---|---|---|
| Head node (Ray, vLLM, Watcher) | Debian 11/12 | Ubuntu 22.04+ also works |
| Slurm workers | RHEL 8/9, Rocky, AlmaLinux | SELinux pre-flight required |
| Container image | Built on Debian; runs on RHEL/Debian | `--nv` flag required for GPU access |

See [docs/rhel-slurm-setup.md](docs/rhel-slurm-setup.md) for the RHEL SELinux and NVIDIA container toolkit setup, and [docs/deployment-guide.md](docs/deployment-guide.md) for the full walkthrough.

---

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## Security

See [SECURITY.md](SECURITY.md) for the vulnerability disclosure process.

## License

Apache 2.0. See [LICENSE](LICENSE).

---

## What it does

- Runs a **permanent vLLM API server** on a lightweight Proxmox VM (no GPU required)
- **Dynamically bursts Slurm GPU nodes** into a Ray cluster when request queues grow
- **Scales back down** automatically when idle, returning GPUs to the research pool
- Auto-configures **Kilo Code** (VS Code AI extension) in Open OnDemand code-server sessions
- Serves **Qwen2.5-Coder-32B-Instruct-AWQ** optimized for the NVIDIA L30 GPU

```
┌─────────────────────────────────────────────────────────────┐
│  OOD Users (code-server sessions)                           │
│    Kilo Code Extension → HTTPS → nginx (TLS termination)    │
└─────────────────────┬───────────────────────────────────────┘
                      │ :443
         ┌────────────▼────────────┐
         │  Proxmox VM (Debian)    │
         │  ├── nginx TLS proxy    │
         │  ├── vLLM API server    │◄── vllm_watcher.py
         │  └── Ray Head (:6380)  │      │
         └────────────┬────────────┘      │ sbatch (on demand)
                      │ Ray cluster       │
         ┌────────────▼────────────┐      │
         │  Slurm GPU Nodes (RHEL) │◄─────┘
         │  L30 × N  (1 GPU/node)  │
         │  ray start --address=…  │
         └─────────────────────────┘
```

---

## Hardware requirements

| Component | Spec |
|---|---|
| Head node | Proxmox VM, no GPU, 4–8 cores, ≥32GB RAM, Debian |
| GPU nodes | NVIDIA L30 24GB (Ada Lovelace), ≥64 cores, ≥512GB RAM, RHEL-family |
| Shared storage | NFS/Lustre/GPFS mounted at `/share` on both head and workers |
| Model | Qwen/Qwen2.5-Coder-32B-Instruct-AWQ (~18.5GB) |
| Network | Internal TCP: 443 (API), 6380 (Ray GCS), 10001–19999 (Ray workers) |

---

## Quick start

### 1. Configure

```bash
cp config/config.example.env /opt/stroma-ai/config.env
# Edit all CHANGEME values and site-specific settings
chmod 640 /opt/stroma-ai/config.env
```

### 2. Build the container (on an internet-connected machine)

```bash
apptainer build /share/containers/stroma-ai-vllm.sif deploy/containers/stroma-ai-vllm.def
```

### 3. Deploy systemd services (on the Proxmox VM)

```bash
useradd -r -s /sbin/nologin stromaai
cp deploy/systemd/*.service /etc/systemd/system/
cp src/vllm_watcher.py /opt/stroma-ai/
systemctl daemon-reload
systemctl enable --now ray-head
systemctl enable --now stroma-ai-vllm
systemctl enable --now stroma-ai-watcher
```

### 4. Configure nginx TLS

```bash
apt-get install -y nginx
# Create self-signed cert:
mkdir -p /etc/ssl/stroma-ai
openssl req -x509 -nodes -days 3650 -newkey rsa:4096 \
  -keyout /etc/ssl/stroma-ai/server.key \
  -out    /etc/ssl/stroma-ai/server.crt \
  -subj "/CN=stroma-ai.your-cluster.example"
cp deploy/nginx/stroma-ai.conf /etc/nginx/sites-available/stroma-ai
ln -s /etc/nginx/sites-available/stroma-ai /etc/nginx/sites-enabled/stroma-ai
nginx -t && systemctl reload nginx
```

### 5. Configure Slurm partition and warm node

```bash
# Create burst partition:
scontrol create partition Name=stroma-ai-gpu Nodes=node[001-070] MaxNodes=10 State=UP
sacctmgr add account stroma-ai-service Description="StromaAI burst workers"
mkdir -p /share/logs/stroma-ai /share/slurm
cp deploy/slurm/stroma_ai_worker.slurm /share/slurm/

# Create always-warm reservation (1 node permanently allocated):
scontrol create Reservation=stroma-ai-warm \
  StartTime=now Duration=UNLIMITED \
  Nodes=node001 \
  Accounts=stroma-ai-service \
  Flags=MAINT,IGNORE_JOBS
```

### 6. Configure OOD integration

```bash
cp deploy/ood/stroma-ai.conf /etc/ood/stroma-ai.conf
chmod 640 /etc/ood/stroma-ai.conf
# Edit stroma-ai.conf — set STROMA_API_KEY to match /opt/stroma-ai/config.env
# Merge deploy/ood/script.sh.erb into your code-server OOD app template
```

### 7. Verify

```bash
# API health:
curl -k https://stroma-ai.your-cluster.example/health

# Model list:
curl -k https://stroma-ai.your-cluster.example/v1/models \
  -H "Authorization: Bearer YOUR_API_KEY"

# Watch logs:
journalctl -u stroma-ai-ray -u stroma-ai-vllm -u stroma-ai-watcher -f
```

---

## File structure

```
stroma-ai/
├── config/
│   └── config.example.env     # All configuration variables with documentation
├── deploy/
│   ├── containers/
│   │   └── stroma-ai-vllm.def   # Apptainer container definition (pinned versions)
│   ├── nginx/
│   │   └── stroma-ai.conf       # nginx TLS reverse proxy configuration
│   ├── ood/
│   │   ├── stroma-ai.conf       # OOD config file (sourced by script.sh.erb)
│   │   └── script.sh.erb      # code-server session setup template
│   ├── slurm/
│   │   └── stroma_ai_worker.slurm  # Slurm burst worker sbatch script
│   └── systemd/
│       ├── ray-head.service      # Ray head node service
│       ├── stroma-ai-vllm.service  # vLLM API server service
│       └── stroma-ai-watcher.service  # Dynamic burst scaler service
├── docs/
│   ├── deployment-guide.md    # Full step-by-step deployment walkthrough
│   └── rhel-slurm-setup.md   # RHEL-specific pre-flight checklist
├── monitoring/
│   └── prometheus.yml         # Prometheus scrape config + alert rules
├── src/
│   └── vllm_watcher.py        # Dynamic burst orchestration logic
├── LICENSE                    # Apache 2.0
├── README.md                  # This file
├── CONTRIBUTING.md
└── SECURITY.md
```

---

## OS compatibility

| Component | OS | Notes |
|---|---|---|
| Head node (Ray, vLLM, Watcher) | Debian 11/12 | Ubuntu 22.04+ also works |
| Slurm workers | RHEL 8/9, Rocky, AlmaLinux | SELinux pre-flight required |
| Container image | Built on Debian; runs on RHEL/Debian | `--nv` flag required |

See [docs/rhel-slurm-setup.md](docs/rhel-slurm-setup.md) for the RHEL SELinux and NVIDIA container toolkit setup.

---

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md).

## Security

See [SECURITY.md](SECURITY.md) for the vulnerability disclosure process.

## License

Apache 2.0. See [LICENSE](LICENSE).
