# AI_Flux Roadmap

This document describes the planned evolution of AI_Flux — an HPC burst-inference platform for large-language model serving at Moffitt Cancer Center.

---

## v1.0 — Foundation (current)

Shipped features:

- **vLLM Watcher** (`src/vllm_watcher.py`): state machine that watches GPU demand and submits/cancels Slurm jobs to provision or deprovision vLLM inference workers
- **Multi-distro installer** (`install/`): automated installation for RHEL 8.10, Rocky Linux 9.5, and Ubuntu 22.04 in head-node, worker-node, and Open OnDemand (OOD) modes
- **Containerised inference**: Apptainer `.def` files for vLLM workers; NVIDIA Container Toolkit + CDI device passthrough
- **API gateway**: nginx reverse proxy with TLS termination and bearer-token authentication
- **Slurm integration**: sbatch job templates for GPU-partitioned inference bursts
- **Open OnDemand app**: Batch-connect template for researcher self-service
- **Systemd services**: `ai-flux-watcher`, `ai-flux-vllm`, `ai-flux-metrics`
- **Ops tooling**: Prometheus `/metrics` endpoint, structured logging, dry-run install mode
- **SDLC baseline**: pytest unit tests, shell integration smoke test, GitHub Actions CI, semantic versioning, branching strategy

---

## v1.1 — Observability & UX (next)

Target: Q3 2025

| # | Feature | Description |
|---|---------|-------------|
| 1 | Grafana dashboard | Pre-built dashboard JSON for GPU utilisation, queue depth, request latency, and watcher state transitions |
| 2 | OOD API-key wizard | Guided UI in Open OnDemand for researchers to generate and rotate their bearer tokens |
| 3 | CI smoke-gate | GitHub Actions job that runs `smoke_test.sh` against a staging cluster before promotion to `main` |
| 4 | Structured JSON logs | Replace plain-text log lines in watcher with `structlog` JSON output for easy ingestion into ELK/Splunk |
| 5 | Installer idempotency tests | Ensure running `install.sh` twice on the same node is safe and produces no duplicate service entries |

---

## v1.2 — Scale & Performance

Target: Q4 2025

| # | Feature | Description |
|---|---------|-------------|
| 1 | Node profiles (H100 / A100) | Named profiles in `config.example.env` with sane defaults for each GPU tier; auto-detect via `nvidia-smi` during install |
| 2 | Speculative decoding | Optional draft-model config wired into vLLM batchsize and Slurm GRES requests |
| 3 | Multi-cluster routing | Watcher can target a secondary Slurm cluster (e.g., burst-to-cloud) when primary GPU partition is fully allocated |
| 4 | Rolling-update workflow | `install.sh --upgrade` flow that drains Slurm jobs, updates containers, and restarts services with zero slot loss |
| 5 | Queue-depth autotune | Empirically measure per-model throughput and adjust `SCALE_UP_THRESHOLD` / `SCALE_DOWN_THRESHOLD` automatically |

---

## v2.0 — Enterprise & Cloud (Future)

| # | Feature | Description |
|---|---------|-------------|
| 1 | OIDC / SAML authentication | Replace static bearer tokens with institutional SSO (Shibboleth / Azure AD) |
| 2 | Kubernetes backend | Optional `--backend=kubernetes` mode using KubeFlow or vLLM Operator instead of Slurm |
| 3 | Multi-tenant quotas | Per-group GPU-hour budgets enforced at the API gateway and watcher layers |
| 4 | Model registry | Internal registry for versioned model weights; watcher pulls by digest rather than path |
| 5 | Audit logging | Tamper-evident request logs for HIPAA compliance tracibility |

---

## Versioning Policy

AI_Flux follows [Semantic Versioning](https://semver.org/) (`vMAJOR.MINOR.PATCH`):

- **PATCH**: Bug fixes and documentation corrections that do not change behaviour
- **MINOR**: Backward-compatible new features or installer improvements
- **MAJOR**: Breaking changes to config schema, API, or installation paths

Release tags are created via GitHub Actions (`release.yml`) when a `v*.*.*` tag is pushed to `main`.
