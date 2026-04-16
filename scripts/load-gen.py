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
import json
import os
import ssl
import sys
import time
import threading
import urllib.request
import urllib.error
from concurrent.futures import ThreadPoolExecutor, as_completed


def _build_payload(model: str, max_tokens: int, think: bool) -> dict:
    """Build a chat-completion payload designed to generate many tokens."""
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
    if not think:
        payload["chat_template_kwargs"] = {"enable_thinking": False}
    return payload


def _make_ssl_ctx(verify: bool) -> ssl.SSLContext | None:
    if verify:
        return None  # use default
    ctx = ssl.create_default_context()
    ctx.check_hostname = False
    ctx.verify_mode = ssl.CERT_NONE
    return ctx


_lock = threading.Lock()
_stats = {"sent": 0, "ok": 0, "err": 0, "tokens": 0}


def _send_request(
    url: str,
    headers: dict,
    payload: dict,
    req_id: int,
    ssl_ctx: ssl.SSLContext | None,
) -> None:
    """Send a single blocking request and record stats."""
    with _lock:
        _stats["sent"] += 1
    data = json.dumps(payload).encode()
    req = urllib.request.Request(url, data=data, headers=headers, method="POST")
    t0 = time.monotonic()
    try:
        with urllib.request.urlopen(req, timeout=600, context=ssl_ctx) as resp:
            body = json.loads(resp.read())
            elapsed = time.monotonic() - t0
            usage = body.get("usage", {})
            gen_tokens = usage.get("completion_tokens", 0)
            with _lock:
                _stats["ok"] += 1
                _stats["tokens"] += gen_tokens
            print(f"  [req {req_id:3d}] OK  {gen_tokens:5d} tokens  {elapsed:6.1f}s")
    except urllib.error.HTTPError as exc:
        elapsed = time.monotonic() - t0
        err_body = exc.read().decode(errors="replace")[:200]
        with _lock:
            _stats["err"] += 1
        print(f"  [req {req_id:3d}] ERR {exc.code}  {elapsed:6.1f}s  {err_body}")
    except (urllib.error.URLError, OSError) as exc:
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

    ssl_ctx = _make_ssl_ctx(not args.no_verify)
    headers = {
        "Authorization": f"Bearer {args.token}",
        "Content-Type": "application/json",
    }

    # Auto-detect model if not specified
    model = args.model
    if not model:
        base_url = args.url.rsplit("/v1/", 1)[0]
        try:
            req = urllib.request.Request(
                f"{base_url}/v1/models", headers=headers,
            )
            with urllib.request.urlopen(req, timeout=10, context=ssl_ctx) as resp:
                data = json.loads(resp.read())
                models = data.get("data", [])
                if models:
                    model = models[0]["id"]
        except (urllib.error.URLError, OSError):
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
                        args.url, headers, payload, req_counter, ssl_ctx,
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
