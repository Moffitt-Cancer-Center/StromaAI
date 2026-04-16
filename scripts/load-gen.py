#!/usr/bin/env python3
"""
StromaAI load generator — saturate the persistent model to trigger burst scaling.

Sends concurrent long-running requests to build up a queue (num_requests_waiting)
past STROMA_SCALE_UP_THRESHOLD (default: 2), which triggers the watcher to submit
additional Slurm GPU workers.

Usage:
    # From any machine that can reach the gateway:
    python3 scripts/load-gen.py --url https://stroma-ai.example/v1/chat/completions \
                                --token YOUR_BEARER_TOKEN \
                                --concurrency 10 \
                                --rounds 3

    # Minimal (uses env vars):
    export STROMA_URL=https://stroma-ai.example
    export STROMA_TOKEN=your_bearer_token
    python3 scripts/load-gen.py
"""
from __future__ import annotations

import argparse
import os
import sys
import time
import threading
from concurrent.futures import ThreadPoolExecutor, as_completed

# ---------------------------------------------------------------------------
# Allow running without any third-party packages (stdlib only)
# ---------------------------------------------------------------------------
try:
    import requests
except ImportError:
    print("ERROR: 'requests' is required.  pip install requests", file=sys.stderr)
    sys.exit(1)


def _build_payload(model: str, max_tokens: int, think: bool) -> dict:
    """Build a chat-completion payload designed to generate many tokens."""
    # The prompt asks for an exhaustive, verbose answer to maximize generation
    # time and keep the GPU busy long enough for queued requests to pile up.
    prompt = (
        "Write an extremely detailed, step-by-step technical tutorial on "
        "building a distributed GPU inference platform for large language "
        "models on an HPC cluster with Slurm scheduling.  Cover networking, "
        "containerization, monitoring, security, and scaling.  Be as verbose "
        "and thorough as possible.  Do not summarize."
    )
    payload: dict = {
        "model": model,
        "messages": [{"role": "user", "content": prompt}],
        "max_tokens": max_tokens,
        "temperature": 0.7,
        "stream": False,
    }
    # Disable thinking/reasoning to avoid the model spending tokens on
    # chain-of-thought rather than generating output tokens.
    if not think:
        payload["chat_template_kwargs"] = {"enable_thinking": False}
    return payload


_lock = threading.Lock()
_stats = {"sent": 0, "ok": 0, "err": 0, "tokens": 0}


def _send_request(
    url: str,
    headers: dict,
    payload: dict,
    req_id: int,
    verify_ssl: bool,
) -> None:
    """Send a single blocking request and record stats."""
    with _lock:
        _stats["sent"] += 1
    t0 = time.monotonic()
    try:
        resp = requests.post(
            url, json=payload, headers=headers,
            timeout=600,  # 10 min — long generations
            verify=verify_ssl,
        )
        elapsed = time.monotonic() - t0
        if resp.status_code == 200:
            data = resp.json()
            usage = data.get("usage", {})
            gen_tokens = usage.get("completion_tokens", 0)
            with _lock:
                _stats["ok"] += 1
                _stats["tokens"] += gen_tokens
            print(f"  [req {req_id:3d}] OK  {gen_tokens:5d} tokens  {elapsed:6.1f}s")
        else:
            with _lock:
                _stats["err"] += 1
            # Truncate error body for readability
            body = resp.text[:200]
            print(f"  [req {req_id:3d}] ERR {resp.status_code}  {elapsed:6.1f}s  {body}")
    except requests.RequestException as exc:
        elapsed = time.monotonic() - t0
        with _lock:
            _stats["err"] += 1
        print(f"  [req {req_id:3d}] EXC {elapsed:6.1f}s  {exc}")


def main() -> None:
    parser = argparse.ArgumentParser(
        description="StromaAI load generator — trigger burst scaling",
    )
    parser.add_argument(
        "--url",
        default=os.environ.get(
            "STROMA_URL", "https://localhost"
        ).rstrip("/") + "/v1/chat/completions",
        help="Full chat-completions endpoint URL",
    )
    parser.add_argument(
        "--token",
        default=os.environ.get("STROMA_TOKEN", ""),
        help="Bearer token (or set STROMA_TOKEN env var)",
    )
    parser.add_argument(
        "--model",
        default=os.environ.get("STROMA_MODEL", ""),
        help="Model name to target (default: auto-detect from /v1/models)",
    )
    parser.add_argument(
        "--concurrency", "-c", type=int, default=10,
        help="Number of parallel requests per round (default: 10)",
    )
    parser.add_argument(
        "--rounds", "-r", type=int, default=3,
        help="Number of rounds to send (default: 3)",
    )
    parser.add_argument(
        "--max-tokens", "-t", type=int, default=2048,
        help="Max tokens per response — higher = longer GPU time (default: 2048)",
    )
    parser.add_argument(
        "--think", action="store_true",
        help="Allow model thinking/reasoning (default: disabled for faster output)",
    )
    parser.add_argument(
        "--no-verify", action="store_true",
        help="Skip TLS certificate verification (for self-signed certs)",
    )
    args = parser.parse_args()

    if not args.token:
        print("ERROR: --token or STROMA_TOKEN is required", file=sys.stderr)
        sys.exit(1)

    verify_ssl = not args.no_verify
    headers = {
        "Authorization": f"Bearer {args.token}",
        "Content-Type": "application/json",
    }

    # Auto-detect model if not specified
    model = args.model
    if not model:
        base_url = args.url.rsplit("/v1/", 1)[0]
        try:
            r = requests.get(
                f"{base_url}/v1/models",
                headers=headers,
                timeout=10,
                verify=verify_ssl,
            )
            if r.status_code == 200:
                models = r.json().get("data", [])
                if models:
                    model = models[0]["id"]
        except requests.RequestException:
            pass
        if not model:
            print("ERROR: Could not auto-detect model. Use --model.", file=sys.stderr)
            sys.exit(1)

    print(f"StromaAI Load Generator")
    print(f"  Target:      {args.url}")
    print(f"  Model:       {model}")
    print(f"  Concurrency: {args.concurrency}")
    print(f"  Rounds:      {args.rounds}")
    print(f"  Max tokens:  {args.max_tokens}")
    print(f"  Total reqs:  {args.concurrency * args.rounds}")
    print()

    payload = _build_payload(model, args.max_tokens, args.think)
    req_counter = 0
    t_start = time.monotonic()

    for rnd in range(1, args.rounds + 1):
        print(f"--- Round {rnd}/{args.rounds} ({args.concurrency} requests) ---")
        futures = []
        with ThreadPoolExecutor(max_workers=args.concurrency) as pool:
            for _ in range(args.concurrency):
                req_counter += 1
                futures.append(
                    pool.submit(
                        _send_request,
                        args.url, headers, payload, req_counter, verify_ssl,
                    )
                )
            # Wait for all requests in this round
            for f in as_completed(futures):
                f.result()  # propagate exceptions
        print()

    elapsed = time.monotonic() - t_start
    print(f"Done in {elapsed:.1f}s")
    print(f"  Sent:   {_stats['sent']}")
    print(f"  OK:     {_stats['ok']}")
    print(f"  Errors: {_stats['err']}")
    print(f"  Tokens: {_stats['tokens']}")
    if _stats["ok"] > 0:
        print(f"  Avg tokens/req: {_stats['tokens'] // _stats['ok']}")


if __name__ == "__main__":
    main()
