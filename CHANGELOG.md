# Changelog

All notable changes to StromaAI are documented here.

Format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).
This project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

---

## [Unreleased]

*(Changes staged for the next release go here.)*

---

## [1.0.0] — 2025-07-11

### Added

**Core platform**
- `src/vllm_watcher.py`: state-machine watcher that monitors vLLM GPU demand and
  automatically submits or cancels Slurm jobs to burst inference capacity
- Prometheus `/metrics` endpoint exposed by the watcher (queue depth, active job count,
  last-scale timestamps)
- Systemd service units: `ai-flux-watcher.service`, `ai-flux-vllm.service`,
  `ai-flux-metrics.service`

**Multi-distro installer** (`install/`)
- `install.sh`: main entry point with `--mode=head|worker|ood`, `--dry-run`, and `--yes` flags
- `install/preflight.sh`: pre-flight checks (disk space, RAM, GPU presence)
- `install/uninstall.sh`: clean removal of all StromaAI components
- `install/lib/common.sh`: logging helpers, dry-run guard, `confirm()` prompt
- `install/lib/detect.sh`: OS / GPU / RAM / SELinux detection (RHEL, Rocky, Ubuntu)
- `install/lib/packages.sh`: dnf/apt wrappers, Python 3.11, nginx provisioning
- `install/lib/apptainer.sh`: Apptainer from EPEL (RHEL/Rocky) or GitHub `.deb` (Ubuntu)
- `install/lib/nvidia.sh`: NVIDIA Container Toolkit + CDI device passthrough
- `install/lib/selinux.sh`: SELinux/AppArmor policy booleans and firewall rules
- Tested on RHEL 8.10, Rocky Linux 9.5, Ubuntu 22.04

**Containerisation**
- Apptainer `.def` files for vLLM worker containers
- NVIDIA GPU access via CDI (`--device nvidia.com/gpu=all`)

**API gateway**
- nginx reverse proxy with TLS termination
- Bearer-token authentication for all `/v1/*` endpoints

**Open OnDemand**
- Batch-connect app template for researcher self-service model access

**Slurm integration**
- `sbatch` job templates for GPU-partitioned inference bursts
- Watcher polls `squeue` and reconciles desired vs. actual job count on every tick

**SDLC infrastructure**
- `tests/unit/test_watcher.py`: 47 pytest unit tests across 12 test classes
- `tests/integration/smoke_test.sh`: 7-section post-deploy smoke test suite
- `.github/workflows/ci.yml`: 5-job CI pipeline (shellcheck, python-tests,
  installer-dry-run, apptainer-def-lint, config-check)
- `.github/workflows/release.yml`: automated GitHub Release on `v*.*.*` tag push
- `ROADMAP.md`: milestone-based feature roadmap
- `CONTRIBUTING.md`: branching strategy, PR process, and commit conventions

---

[Unreleased]: https://github.com/Moffitt-Cancer-Center/ai-flux/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/Moffitt-Cancer-Center/ai-flux/releases/tag/v1.0.0
