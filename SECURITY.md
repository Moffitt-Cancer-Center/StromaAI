# Security Policy

## Scope

This policy covers the StromaAI platform: the vLLM Watcher script, Slurm worker template, Apptainer container definition, nginx configuration, systemd services, and OOD integration scripts.

## Supported versions

| Version | Security fixes |
|---|---|
| `main` | Yes |

## Reporting a vulnerability

**Do not open a public GitHub issue for security vulnerabilities.**

Email the maintainers directly at the email address on the GitHub profile. Include:

1. A description of the vulnerability
2. Steps to reproduce
3. The component affected
4. Impact assessment (what an attacker could do)

You will receive an acknowledgement within 5 business days. We will work with you on a coordinated disclosure timeline.

## Security model

StromaAI is designed for **internal HPC environments behind a firewall**. The security model assumes:

- Only authenticated HPC users can reach the vLLM HTTPS endpoint (network-level control)
- The API key (`STROMA_API_KEY`) is an internal shared secret that prevents unauthorized lateral-movement calls within the HPC network — it is not a user credential
- The Slurm burst jobs run under a dedicated service account (`ai-flux-service`) with no elevated cluster privileges
- The Proxmox VM is managed by HPC admins and not accessible to regular users

### Known limitations

- The API key is a single shared secret (no per-user identity). This is a known trade-off for v1. A future phase will add per-user identity via an auth proxy.
- `--trust-remote-code` is required by the AWQ tokenizer. Only deploy model weights from verified, checksummed sources. Do not run `huggingface-cli download` from untrusted model repos on the same machine as the inference server.
- TLS certificates default to self-signed. Replace with your organization's CA-signed certificate to prevent MITM within the cluster.

## Dependency security

All container package versions are pinned in `deploy/containers/stroma-ai-vllm.def`. When upgrading:

1. Review the vLLM and Ray changelogs for security fixes
2. Rebuild and test the container on RHEL before updating shared storage
3. Update the `%labels` version tags
