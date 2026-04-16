#!/usr/bin/env python3
"""
StromaAI CLI  —  stroma-cli.py
================================
Unified command-line interface for deploying, configuring, and operating the
StromaAI platform. Acts as the single entry point for:

  • Hardware pre-flight checks (GPU, memory, disk, container runtime)
  • Identity provider setup (local Keycloak vs. external institutional IdP)
  • OpenWebUI deployment (local container vs. external instance)
  • Secure gateway management (start, stop, status)
  • Cluster management (worker status, manual scale-up/down)
  • Platform health summary

Usage
-----
    python3 src/stroma_cli.py --setup          # Interactive first-time wizard
    python3 src/stroma_cli.py --status         # Show all component statuses
    python3 src/stroma_cli.py hardware         # Hardware pre-flight only
    python3 src/stroma_cli.py gateway start    # Start the FastAPI gateway
    python3 src/stroma_cli.py gateway stop     # Stop the FastAPI gateway
    python3 src/stroma_cli.py gateway status   # Gateway health check
    python3 src/stroma_cli.py cluster status   # Ray + Slurm worker summary
    python3 src/stroma_cli.py cluster scale-up # Manually submit a burst worker
    python3 src/stroma_cli.py idp setup        # Re-run IdP configuration

Configuration
-------------
All configuration is read from STROMA_CONFIG_ENV (default: /opt/stroma-ai/config.env).
The wizard writes to this file; individual commands read from it.

Requires
--------
  # Minimal (hardware checks + config only):
  pip install rich

  # Full (gateway + cluster management):
  pip install rich requests ray
"""

from __future__ import annotations

import argparse
import os
import platform
import shutil
import subprocess
import sys
from pathlib import Path
from typing import Optional

# ---------------------------------------------------------------------------
# Optional rich import — graceful fallback to plain print
# ---------------------------------------------------------------------------
try:
    from rich.console import Console
    from rich.table import Table
    from rich import print as rprint
    _console = Console()
    HAS_RICH = True
except ImportError:
    _console = None  # type: ignore[assignment]
    HAS_RICH = False

    class _FallbackConsole:
        def print(self, msg: str, **_kw) -> None: print(msg)
        def rule(self, msg: str = "", **_kw) -> None: print(f"\n{'─'*60} {msg} {'─'*60}")
    _console = _FallbackConsole()  # type: ignore[assignment]

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
REPO_ROOT   = Path(__file__).parent.parent.resolve()
INSTALL_DIR = Path(os.environ.get("STROMA_INSTALL_DIR", str(REPO_ROOT)))
# CONFIG_ENV resolves relative to INSTALL_DIR so a single STROMA_INSTALL_DIR
# env var is enough to relocate the entire platform.
CONFIG_ENV  = Path(os.environ.get("STROMA_CONFIG_ENV", str(INSTALL_DIR / "config.env")))


# ---------------------------------------------------------------------------
# Config helpers
# ---------------------------------------------------------------------------

def _load_config() -> dict[str, str]:
    """Load key=value pairs from CONFIG_ENV into a dict."""
    cfg: dict[str, str] = {}
    if not CONFIG_ENV.exists():
        return cfg
    for line in CONFIG_ENV.read_text().splitlines():
        line = line.strip()
        if not line or line.startswith("#") or "=" not in line:
            continue
        k, _, v = line.partition("=")
        cfg[k.strip()] = v.strip()
    return cfg


def _write_config_var(key: str, value: str) -> None:
    """Write or update a single KEY=VALUE in CONFIG_ENV."""
    CONFIG_ENV.parent.mkdir(parents=True, exist_ok=True)
    if CONFIG_ENV.exists():
        lines = CONFIG_ENV.read_text().splitlines()
        updated = False
        new_lines = []
        for line in lines:
            if line.startswith(f"{key}="):
                new_lines.append(f"{key}={value}")
                updated = True
            else:
                new_lines.append(line)
        if not updated:
            new_lines.append(f"{key}={value}")
        CONFIG_ENV.write_text("\n".join(new_lines) + "\n")
    else:
        CONFIG_ENV.write_text(f"{key}={value}\n")
    CONFIG_ENV.chmod(0o640)


# ---------------------------------------------------------------------------
# Hardware checks
# ---------------------------------------------------------------------------

class HardwareCheckResult:
    def __init__(self) -> None:
        self.passed: list[str] = []
        self.warnings: list[str] = []
        self.failures: list[str] = []

    @property
    def ok(self) -> bool:
        return len(self.failures) == 0


def _check_hardware() -> HardwareCheckResult:
    """
    Run pre-flight hardware and environment checks.

    Checks performed:
      • OS / architecture (Linux x86_64 expected for production)
      • Python version (3.10+)
      • GPU availability (nvidia-smi)
      • GPU VRAM (warn if < 24 GB)
      • System RAM (warn if < 64 GB)
      • Disk space on STROMA_SHARED_ROOT (warn if < 200 GB free)
      • Container runtime (apptainer or singularity)
      • CUDA availability
      • Podman (for Keycloak / OpenWebUI containers)
    """
    r = HardwareCheckResult()

    # Python version
    vi = sys.version_info
    if vi >= (3, 10):
        r.passed.append(f"Python {vi.major}.{vi.minor}.{vi.micro}")
    else:
        r.failures.append(
            f"Python 3.10+ required (found {vi.major}.{vi.minor}.{vi.micro})"
        )

    # OS
    system = platform.system()
    arch   = platform.machine()
    if system == "Linux" and arch == "x86_64":
        r.passed.append(f"OS: {system} {arch}")
    else:
        r.warnings.append(
            f"OS: {system} {arch} — production deployments require Linux x86_64"
        )

    # NVIDIA GPU via nvidia-smi
    if shutil.which("nvidia-smi"):
        try:
            proc = subprocess.run(
                [
                    "nvidia-smi",
                    "--query-gpu=name,memory.total",
                    "--format=csv,noheader,nounits",
                ],
                capture_output=True, text=True, timeout=10, check=False,
            )
            if proc.returncode == 0 and proc.stdout.strip():
                gpu_lines = [l.strip() for l in proc.stdout.strip().splitlines() if l.strip()]
                for gpu_line in gpu_lines:
                    parts = gpu_line.split(",")
                    gpu_name = parts[0].strip() if parts else "Unknown GPU"
                    try:
                        vram_mb = int(parts[1].strip()) if len(parts) > 1 else 0
                        vram_gb = vram_mb / 1024
                        if vram_gb >= 24:
                            r.passed.append(f"GPU: {gpu_name} ({vram_gb:.0f} GB VRAM)")
                        else:
                            r.warnings.append(
                                f"GPU: {gpu_name} ({vram_gb:.1f} GB VRAM) — "
                                "24 GB+ recommended for 32B parameter models"
                            )
                    except (ValueError, IndexError):
                        r.passed.append(f"GPU: {gpu_name}")
            else:
                r.warnings.append("nvidia-smi found but returned no GPU data")
        except subprocess.TimeoutExpired:
            r.warnings.append("nvidia-smi timed out")
    else:
        r.warnings.append(
            "nvidia-smi not found — GPU checks skipped. "
            "Required for Slurm burst workers."
        )

    # System RAM
    try:
        mem_bytes = os.sysconf("SC_PAGE_SIZE") * os.sysconf("SC_PHYS_PAGES")
        mem_gb    = mem_bytes / (1024 ** 3)
        if mem_gb >= 64:
            r.passed.append(f"RAM: {mem_gb:.0f} GB")
        else:
            r.warnings.append(
                f"RAM: {mem_gb:.0f} GB — 64 GB+ recommended for head node"
            )
    except (AttributeError, ValueError):
        r.warnings.append("RAM check skipped (sysconf unavailable)")

    # Disk space on shared root
    shared_root = os.environ.get("STROMA_SHARED_ROOT", "/share")
    try:
        st = shutil.disk_usage(shared_root if Path(shared_root).exists() else "/")
        free_gb = st.free / (1024 ** 3)
        if free_gb >= 200:
            r.passed.append(f"Disk ({shared_root}): {free_gb:.0f} GB free")
        elif free_gb >= 50:
            r.warnings.append(
                f"Disk ({shared_root}): {free_gb:.0f} GB free — "
                "200 GB+ recommended for model weights + SIF image"
            )
        else:
            r.failures.append(
                f"Disk ({shared_root}): only {free_gb:.0f} GB free — "
                "insufficient for model weights"
            )
    except OSError as exc:
        r.warnings.append(f"Disk check failed for {shared_root}: {exc}")

    # Container runtime
    for runtime in ("apptainer", "singularity"):
        if shutil.which(runtime):
            r.passed.append(f"Container runtime: {runtime}")
            break
    else:
        r.failures.append(
            "No container runtime found (apptainer or singularity). "
            "Install: https://apptainer.org/docs/admin/latest/installation.html"
        )

    # Podman (for Keycloak / OpenWebUI containers)
    if shutil.which("podman"):
        try:
            proc = subprocess.run(
                ["podman", "info"], capture_output=True, timeout=10, check=False
            )
            if proc.returncode == 0:
                r.passed.append("Podman: available")
            else:
                r.warnings.append("Podman installed but not functioning correctly")
        except subprocess.TimeoutExpired:
            r.warnings.append("Podman check timed out")
    else:
        r.warnings.append(
            "Podman not found — required for Keycloak and OpenWebUI containers "
            "(not required for HPC-only deployments)"
        )

    return r


def cmd_hardware(_args: argparse.Namespace) -> int:
    """Run hardware pre-flight checks and print a summary."""
    _console.rule("[bold]Hardware Pre-flight Check[/bold]" if HAS_RICH else "Hardware Pre-flight Check")
    result = _check_hardware()

    for msg in result.passed:
        _console.print(f"  [green]✓[/green] {msg}" if HAS_RICH else f"  PASS  {msg}")
    for msg in result.warnings:
        _console.print(f"  [yellow]⚠[/yellow] {msg}" if HAS_RICH else f"  WARN  {msg}")
    for msg in result.failures:
        _console.print(f"  [red]✗[/red] {msg}" if HAS_RICH else f"  FAIL  {msg}")

    print()
    if result.ok:
        _console.print("[green]Pre-flight checks passed.[/green]" if HAS_RICH else "Pre-flight checks passed.")
        return 0
    else:
        _console.print(
            f"[red]{len(result.failures)} check(s) failed — resolve failures before deploying.[/red]"
            if HAS_RICH else
            f"{len(result.failures)} check(s) failed — resolve failures before deploying."
        )
        return 1


# ---------------------------------------------------------------------------
# Identity Provider setup
# ---------------------------------------------------------------------------

def cmd_idp_setup(_args: argparse.Namespace) -> int:
    """
    Interactive IdP configuration wizard.

    Delegates to deploy/keycloak/setup-keycloak.sh — this function
    validates prerequisites and then hands off to the shell script so all
    Keycloak logic lives in one place.
    """
    setup_script = REPO_ROOT / "deploy" / "keycloak" / "setup-keycloak.sh"
    if not setup_script.exists():
        _console.print(f"[red]Setup script not found: {setup_script}[/red]" if HAS_RICH else str(setup_script))
        return 1

    if not shutil.which("podman"):
        _console.print(
            "[yellow]Warning:[/yellow] Podman not found. "
            "LOCAL mode requires Podman. EXTERNAL mode will still work."
            if HAS_RICH else
            "Warning: Podman not found."
        )

    os.execv("/bin/bash", ["/bin/bash", str(setup_script)])
    return 0  # unreachable — exec replaces process


# ---------------------------------------------------------------------------
# Gateway management
# ---------------------------------------------------------------------------

def _gateway_pid() -> Optional[int]:
    """Return the PID of a running gateway process, or None."""
    pid_file = INSTALL_DIR / "gateway.pid"
    if pid_file.exists():
        try:
            pid = int(pid_file.read_text().strip())
            # Verify process exists
            os.kill(pid, 0)
            return pid
        except (ValueError, ProcessLookupError, PermissionError):
            pid_file.unlink(missing_ok=True)
    return None


def cmd_gateway(args: argparse.Namespace) -> int:
    """Manage the FastAPI secure gateway process."""
    action = getattr(args, "gateway_action", "status")
    cfg    = _load_config()

    if action == "start":
        pid = _gateway_pid()
        if pid:
            _console.print(f"Gateway already running (PID {pid})" if not HAS_RICH else f"Gateway already running (PID [bold]{pid}[/bold])")
            return 0

        gateway_script = REPO_ROOT / "src" / "gateway.py"
        log_file       = INSTALL_DIR / "logs" / "gateway.log"
        pid_file       = INSTALL_DIR / "gateway.pid"
        log_file.parent.mkdir(parents=True, exist_ok=True)

        env = {**os.environ}
        for k in ("OIDC_DISCOVERY_URL", "STROMA_API_KEY", "VLLM_BACKEND_URL"):
            if k in cfg:
                env[k] = cfg[k]

        port = cfg.get("GATEWAY_PORT", "9000")
        _console.print(f"Starting gateway on port {port} ...")

        with open(log_file, "a") as log_f:
            proc = subprocess.Popen(
                [sys.executable, str(gateway_script)],
                env=env,
                stdout=log_f,
                stderr=log_f,
                start_new_session=True,
            )
        pid_file.write_text(str(proc.pid))
        _console.print(
            f"[green]Gateway started (PID {proc.pid})[/green]" if HAS_RICH
            else f"Gateway started (PID {proc.pid})"
        )
        _console.print(f"  Logs : {log_file}")
        _console.print(f"  URL  : http://localhost:{port}/v1")
        return 0

    elif action == "stop":
        pid = _gateway_pid()
        if not pid:
            _console.print("Gateway is not running.")
            return 0
        import signal as _signal
        os.kill(pid, _signal.SIGTERM)
        (INSTALL_DIR / "gateway.pid").unlink(missing_ok=True)
        _console.print(f"Gateway stopped (PID {pid}).")
        return 0

    elif action == "status":
        pid = _gateway_pid()
        if pid:
            _console.print(
                f"[green]Gateway running[/green] (PID {pid})" if HAS_RICH
                else f"Gateway running (PID {pid})"
            )
        else:
            _console.print(
                "[yellow]Gateway not running[/yellow]" if HAS_RICH
                else "Gateway not running"
            )

        # Health ping
        port = cfg.get("GATEWAY_PORT", "9000")
        try:
            import urllib.request
            with urllib.request.urlopen(
                f"http://localhost:{port}/health", timeout=3
            ) as resp:
                import json
                data = json.load(resp)
                _console.print(f"  Health: {data}")
        except Exception:
            _console.print("  Health: unreachable")
        return 0

    _console.print(f"Unknown gateway action: {action}")
    return 1


# ---------------------------------------------------------------------------
# Cluster management
# ---------------------------------------------------------------------------

def cmd_cluster(args: argparse.Namespace) -> int:
    """Display cluster status or manually trigger worker operations."""
    action = getattr(args, "cluster_action", "status")

    try:
        # Import here so the CLI works even without Ray installed
        sys.path.insert(0, str(REPO_ROOT / "src"))
        from cluster_manager import ClusterManager  # noqa: PLC0415
        mgr = ClusterManager.from_env()
    except ImportError as exc:
        _console.print(f"[red]Cannot import ClusterManager: {exc}[/red]" if HAS_RICH else str(exc))
        return 1

    if action == "status":
        errors = mgr.validate()
        _console.rule("Cluster Status" if not HAS_RICH else "[bold]Cluster Status[/bold]")
        if errors:
            for e in errors:
                _console.print(f"  [red]✗[/red] {e}" if HAS_RICH else f"  FAIL {e}")
        else:
            _console.print(
                "  [green]✓[/green] ClusterManager configuration valid" if HAS_RICH
                else "  PASS  ClusterManager configuration valid"
            )
        _console.print(f"  Container : {mgr.container_path}")
        _console.print(f"  Slurm     : partition={mgr.partition} account={mgr.account}")
        _console.print(f"  Head      : {mgr.head_host}:{mgr.ray_port}")
        return 0 if not errors else 1

    elif action == "scale-up":
        _console.print("Submitting a burst worker job...")
        result = mgr.submit_worker()
        if result.success:
            _console.print(
                f"[green]Submitted job {result.job_id}[/green]" if HAS_RICH
                else f"Submitted job {result.job_id}"
            )
            return 0
        else:
            _console.print(
                f"[red]Submission failed: {result.error}[/red]" if HAS_RICH
                else f"Submission failed: {result.error}"
            )
            return 1

    _console.print(f"Unknown cluster action: {action}")
    return 1


# ---------------------------------------------------------------------------
# Overall status
# ---------------------------------------------------------------------------

def cmd_status(_args: argparse.Namespace) -> int:
    """Show a summary of all platform components."""
    cfg = _load_config()
    _console.rule("StromaAI Platform Status" if not HAS_RICH else "[bold cyan]StromaAI Platform Status[/bold cyan]")

    components = {
        "Config file"         : str(CONFIG_ENV) if CONFIG_ENV.exists() else "NOT FOUND",
        "OIDC Discovery URL"  : cfg.get("OIDC_DISCOVERY_URL", "not configured"),
        "vLLM backend"        : cfg.get("VLLM_BACKEND_URL", cfg.get("STROMA_HEAD_HOST", "not set")),
        "OpenWebUI URL"       : cfg.get("OPENWEBUI_URL", "not configured"),
        "Keycloak admin URL"  : cfg.get("KC_ADMIN_URL", "not configured"),
    }

    for label, value in components.items():
        _console.print(f"  {label:<22}: {value}")

    print()

    # Hardware summary
    hwr = _check_hardware()
    h_status = (
        f"[green]{len(hwr.passed)} passed[/green]"
        f" [yellow]{len(hwr.warnings)} warnings[/yellow]"
        f" [red]{len(hwr.failures)} failures[/red]"
    ) if HAS_RICH else (
        f"{len(hwr.passed)} passed / {len(hwr.warnings)} warnings / {len(hwr.failures)} failures"
    )
    _console.print(f"  Hardware checks: {h_status}")

    # Gateway
    pid = _gateway_pid()
    gw_status = (
        f"[green]running (PID {pid})[/green]" if pid and HAS_RICH
        else f"running (PID {pid})" if pid
        else ("[yellow]not running[/yellow]" if HAS_RICH else "not running")
    )
    _console.print(f"  Gateway        : {gw_status}")

    return 0


# ---------------------------------------------------------------------------
# Setup wizard
# ---------------------------------------------------------------------------

def cmd_setup(_args: argparse.Namespace) -> int:
    """
    Interactive first-time setup wizard. Runs hardware checks, then guides
    the user through IdP and OpenWebUI configuration.
    """
    _console.rule("StromaAI First-Time Setup" if not HAS_RICH else "[bold cyan]StromaAI First-Time Setup[/bold cyan]")
    print()

    # Step 1: Hardware
    _console.print("Step 1/3: Hardware pre-flight checks")
    hw_rc = cmd_hardware(_args)
    if hw_rc != 0:
        print()
        resp = input("Hardware checks failed. Continue anyway? [y/N]: ").strip().lower()
        if resp != "y":
            _console.print("Setup aborted. Resolve hardware issues and re-run.")
            return 1

    print()
    _console.print("Step 2/3: Identity provider (Keycloak / OIDC)")
    print()
    print("  Run:  bash deploy/keycloak/setup-keycloak.sh")
    print("  Then re-run:  python3 src/stroma_cli.py --setup  (skip to step 3)")
    print()

    oidc_url = _load_config().get("OIDC_DISCOVERY_URL", "")
    if not oidc_url:
        _console.print(
            "[yellow]OIDC_DISCOVERY_URL not yet configured.[/yellow]  "
            "Run setup-keycloak.sh first, then re-run this wizard."
            if HAS_RICH else
            "OIDC_DISCOVERY_URL not yet configured. Run setup-keycloak.sh first."
        )
        return 0

    _console.print(
        f"[green]✓[/green] OIDC_DISCOVERY_URL: {oidc_url}" if HAS_RICH
        else f"PASS OIDC_DISCOVERY_URL: {oidc_url}"
    )
    print()
    _console.print("Step 3/3: OpenWebUI")
    print()
    print("  Run:  bash deploy/openwebui/setup-openwebui.sh")
    print()

    owu_url = _load_config().get("OPENWEBUI_URL", "")
    if owu_url:
        _console.print(
            f"[green]✓[/green] OpenWebUI: {owu_url}" if HAS_RICH
            else f"PASS OpenWebUI: {owu_url}"
        )
    else:
        _console.print(
            "[yellow]OpenWebUI not yet configured.[/yellow]" if HAS_RICH
            else "OpenWebUI not yet configured."
        )

    print()
    _console.print("Setup wizard complete. Run  [bold]python3 src/stroma_cli.py --status[/bold]  for a full summary." if HAS_RICH else "Setup wizard complete. Run  python3 src/stroma_cli.py --status  for a full summary.")
    return 0


# ---------------------------------------------------------------------------
# Argument parser + dispatch
# ---------------------------------------------------------------------------

def _build_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(
        prog="stroma-cli",
        description="StromaAI platform management CLI",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=__doc__,
    )

    # Top-level shortcuts
    p.add_argument("--setup",  action="store_true", help="Run the first-time setup wizard")
    p.add_argument("--status", action="store_true", help="Show platform status summary")

    sub = p.add_subparsers(dest="command", metavar="COMMAND")

    # hardware
    sub.add_parser("hardware", help="Run hardware pre-flight checks")

    # idp
    idp_p = sub.add_parser("idp", help="Identity provider management")
    idp_sub = idp_p.add_subparsers(dest="idp_action", metavar="ACTION")
    idp_sub.add_parser("setup", help="Configure Keycloak / external OIDC")

    # gateway
    gw_p = sub.add_parser("gateway", help="Secure FastAPI gateway management")
    gw_sub = gw_p.add_subparsers(dest="gateway_action", metavar="ACTION")
    gw_sub.add_parser("start",  help="Start the gateway process")
    gw_sub.add_parser("stop",   help="Stop the gateway process")
    gw_sub.add_parser("status", help="Check gateway health")

    # cluster
    cl_p = sub.add_parser("cluster", help="HPC cluster management")
    cl_sub = cl_p.add_subparsers(dest="cluster_action", metavar="ACTION")
    cl_sub.add_parser("status",   help="Show Ray + Slurm stat")
    cl_sub.add_parser("scale-up", help="Manually submit a burst worker job")

    return p


def main(argv: Optional[list[str]] = None) -> int:
    parser = _build_parser()
    args   = parser.parse_args(argv)

    if args.setup:
        return cmd_setup(args)

    if args.status or args.command is None:
        return cmd_status(args)

    dispatch = {
        "hardware": cmd_hardware,
        "idp":      lambda a: cmd_idp_setup(a) if getattr(a, "idp_action", None) == "setup" else cmd_status(a),
        "gateway":  cmd_gateway,
        "cluster":  cmd_cluster,
    }

    handler = dispatch.get(args.command)
    if handler:
        return handler(args)

    parser.print_help()
    return 1


if __name__ == "__main__":
    sys.exit(main())
