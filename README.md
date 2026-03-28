# AI_Flux

> *"Be water, my friend."* — Bruce Lee

AI_Flux is an open-source **Hybrid AI Orchestration Platform** that bridges a persistent control node with dynamically bursting HPC GPU workers to deliver on-demand LLM inference. It was designed for research computing environments where GPU nodes are shared across many workloads and must be used efficiently.

Built and reference-deployed at **Moffitt Cancer Center HPC**.

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
| Shared storage | NFS/Lustre/GPFS mounted at `/shared` on both head and workers |
| Model | Qwen/Qwen2.5-Coder-32B-Instruct-AWQ (~18.5GB) |
| Network | Internal TCP: 443 (API), 6380 (Ray GCS), 10001–19999 (Ray workers) |

---

## Quick start

### 1. Configure

```bash
cp config/config.example.env /opt/ai-flux/config.env
# Edit all CHANGEME values and site-specific settings
chmod 640 /opt/ai-flux/config.env
```

### 2. Build the container (on an internet-connected machine)

```bash
apptainer build /shared/containers/ai-flux-vllm.sif deploy/containers/ai-flux-vllm.def
```

### 3. Deploy systemd services (on the Proxmox VM)

```bash
useradd -r -s /sbin/nologin aiflux
cp deploy/systemd/*.service /etc/systemd/system/
cp src/vllm_watcher.py /opt/ai-flux/
systemctl daemon-reload
systemctl enable --now ray-head
systemctl enable --now ai-flux-vllm
systemctl enable --now ai-flux-watcher
```

### 4. Configure nginx TLS

```bash
apt-get install -y nginx
# Create self-signed cert:
mkdir -p /etc/ssl/ai-flux
openssl req -x509 -nodes -days 3650 -newkey rsa:4096 \
  -keyout /etc/ssl/ai-flux/server.key \
  -out    /etc/ssl/ai-flux/server.crt \
  -subj "/CN=ai-flux.your-cluster.example"
cp deploy/nginx/ai-flux.conf /etc/nginx/sites-available/ai-flux
ln -s /etc/nginx/sites-available/ai-flux /etc/nginx/sites-enabled/ai-flux
nginx -t && systemctl reload nginx
```

### 5. Configure Slurm partition and warm node

```bash
# Create burst partition:
scontrol create partition Name=ai-flux-gpu Nodes=node[001-070] MaxNodes=10 State=UP
sacctmgr add account ai-flux-service Description="AI_Flux burst workers"
mkdir -p /shared/logs/ai-flux /shared/slurm
cp deploy/slurm/ai_flux_worker.slurm /shared/slurm/

# Create always-warm reservation (1 node permanently allocated):
scontrol create Reservation=ai-flux-warm \
  StartTime=now Duration=UNLIMITED \
  Nodes=node001 \
  Accounts=ai-flux-service \
  Flags=MAINT,IGNORE_JOBS
```

### 6. Configure OOD integration

```bash
cp deploy/ood/ai-flux.conf /etc/ood/ai-flux.conf
chmod 640 /etc/ood/ai-flux.conf
# Edit ai-flux.conf — set AI_FLUX_API_KEY to match /opt/ai-flux/config.env
# Merge deploy/ood/script.sh.erb into your code-server OOD app template
```

### 7. Verify

```bash
# API health:
curl -k https://ai-flux.your-cluster.example/health

# Model list:
curl -k https://ai-flux.your-cluster.example/v1/models \
  -H "Authorization: Bearer YOUR_API_KEY"

# Watch logs:
journalctl -u ai-flux-ray -u ai-flux-vllm -u ai-flux-watcher -f
```

---

## File structure

```
ai-flux/
├── config/
│   └── config.example.env     # All configuration variables with documentation
├── deploy/
│   ├── containers/
│   │   └── ai-flux-vllm.def   # Apptainer container definition (pinned versions)
│   ├── nginx/
│   │   └── ai-flux.conf       # nginx TLS reverse proxy configuration
│   ├── ood/
│   │   ├── ai-flux.conf       # OOD config file (sourced by script.sh.erb)
│   │   └── script.sh.erb      # code-server session setup template
│   ├── slurm/
│   │   └── ai_flux_worker.slurm  # Slurm burst worker sbatch script
│   └── systemd/
│       ├── ray-head.service      # Ray head node service
│       ├── ai-flux-vllm.service  # vLLM API server service
│       └── ai-flux-watcher.service  # Dynamic burst scaler service
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
