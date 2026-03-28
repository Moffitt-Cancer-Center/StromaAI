# Contributing to AI_Flux

Thank you for considering a contribution to AI_Flux. This project is maintained by the Moffitt Cancer Center HPC team and open to the research computing community.

## Branching strategy

### Branch model

| Branch | Purpose |
|--------|---------|
| `main` | Always-deployable. Protected — no direct pushes; all changes via PR. |
| `feat/<short-name>` | New features (e.g., `feat/grafana-dashboard`) |
| `fix/<short-name>` | Bug fixes (e.g., `fix/squeue-parse-race`) |
| `docs/<short-name>` | Documentation-only changes |
| `chore/<short-name>` | Tooling, CI, dependency bumps |

### Workflow

1. Branch off `main`: `git checkout -b feat/my-feature`
2. Commit small, logical units with descriptive messages (see commit style below)
3. Push and open a PR against `main`
4. CI must pass (all 5 jobs in `.github/workflows/ci.yml`) before merge
5. At least one review from the HPC team is required for non-trivial changes
6. Squash-merge preferred to keep `main` history linear

### Semantic versioning

AI_Flux follows `vMAJOR.MINOR.PATCH` (see [semver.org](https://semver.org)):

- **PATCH** — bug fixes, doc corrections, no behaviour change
- **MINOR** — backward-compatible new features or installer improvements
- **MAJOR** — breaking changes to config schema, API, or installation paths

To cut a release, push a tag from `main`:
```bash
git tag v1.1.0
git push origin v1.1.0
```
The `release.yml` workflow creates the GitHub Release automatically.

### Commit style

Use a short imperative prefix:
```
feat: add Grafana dashboard JSON export
fix: handle squeue empty output on idle cluster
docs: clarify RHEL SELinux boolean requirements
chore: pin shellcheck to v0.10 in ci.yml
```

---

## How to contribute

### Reporting bugs

Open a GitHub issue with:
- A clear description of the problem
- The component affected (watcher, Slurm script, container, nginx, OOD)
- Your OS / Slurm / NVIDIA driver versions
- Relevant log output from `journalctl -u ai-flux-*`

### Suggesting changes

Open a GitHub issue before submitting a PR for significant changes. For small fixes (typos, missing comments, obvious bugs), a PR alone is fine.

### Pull requests

1. Fork the repo and create a branch from `main`
2. Make your changes
3. Verify shell scripts pass `shellcheck`:
   ```bash
   shellcheck deploy/slurm/ai_flux_worker.slurm deploy/ood/script.sh.erb
   ```
4. Verify Python passes basic linting:
   ```bash
   python3 -m py_compile src/vllm_watcher.py
   ```
5. Update documentation if your change affects deployment steps
6. Open a PR against `main` with a clear description of the change and why

## What we're looking for

- Additional GPU node shapes (A100, H100, A40, etc.) with tuned vLLM flags
- Alternative Slurm workflows (array jobs, preemption policies)
- Site deployment reports and configuration examples
- Documentation improvements
- Monitoring dashboards (Grafana JSON exports)

## What to avoid

- Moffitt-specific values in any script or config (use config.example.env variables)
- New dependencies without a clear justification
- Changes that break the RHEL/Debian split compatibility

## Code style

- Shell scripts: POSIX-compatible where possible; use `set -euo pipefail`
- Python: PEP 8, type-annotated function signatures, no external packages beyond `requests` and `ray`
- All configuration via environment variables — no hardcoded hosts, paths, or secrets

## License

By contributing, you agree that your contributions will be licensed under the Apache 2.0 License.
