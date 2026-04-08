#!/usr/bin/env python3
"""
StromaAI — Secure FastAPI Gateway
==================================
Authenticates and authorizes requests before proxying them to the vLLM/Ray
Serve backend. Acts as a security boundary between public-facing clients
(OpenWebUI, Kilo Code, OOD) and the internal inference cluster.

Security model
--------------
  1. Bearer token (JWT) is extracted from every incoming request.
  2. Token is validated against the OIDC issuer's public JWKS keys
     (fetched on startup and cached; background refresh on expiry).
  3. Claims are checked: issuer, audience, expiry, and the presence of
     the ``stroma_researcher`` realm role inside ``realm_access.roles``.
  4. Validated request is forwarded to the vLLM backend via httpx with
     the *internal* API key substituted for the OIDC token.

The gateway is intentionally thin — it does NOT:
  • Store tokens or user data
  • Implement refresh-token flows (handled by clients)
  • Terminate TLS directly (put nginx/traefik in front for production)

Environment variables
---------------------
  OIDC_DISCOVERY_URL    OIDC discovery endpoint (required)
  OIDC_AUDIENCE         JWT audience claim to validate (default: stroma-gateway)
  VLLM_BACKEND_URL      Internal vLLM base URL (default: http://localhost:8000)
  STROMA_API_KEY        Internal vLLM API key forwarded to the backend
  GATEWAY_PORT          Port the gateway listens on (default: 9000)
  GATEWAY_LOG_LEVEL     Uvicorn log level (default: info)
  GATEWAY_ALLOWED_ROLE  Realm role required for access (default: stroma_researcher)
  JWKS_REFRESH_SECS     JWKS cache TTL in seconds (default: 3600)
  JWKS_OVERRIDE_URI     Override the JWKS URI from OIDC discovery (optional).
                        Use this when Keycloak is behind a reverse proxy that
                        uses a self-signed cert — point directly at the internal
                        HTTP URL, e.g. http://10.x.x.x:8080/realms/stroma-ai/
                        protocol/openid-connect/certs
  GATEWAY_VERIFY_SSL    Set to "false" to skip TLS verification when fetching
                        the OIDC discovery doc (default: true). Use only when
                        the IdP is behind a self-signed cert on an internal
                        network. JWKS_OVERRIDE_URI is preferred.

Requires
--------
  pip install fastapi uvicorn[standard] httpx PyJWT cryptography

Run
---
  uvicorn src.gateway:app --port 9000
  # or via the CLI: python3 src/stroma_cli.py gateway start
"""

from __future__ import annotations

import asyncio
import logging
import os
import time
from contextlib import asynccontextmanager
from typing import Annotated, Any

import httpx
import jwt
import jwt.algorithms
from fastapi import Depends, FastAPI, HTTPException, Request, status
from fastapi.responses import JSONResponse, StreamingResponse
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer

from model_registry import ModelRegistry, ModelStatus, ModelTier

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

OIDC_DISCOVERY_URL = os.environ.get("OIDC_DISCOVERY_URL", "")
OIDC_AUDIENCE      = os.environ.get("OIDC_AUDIENCE", "stroma-gateway")
VLLM_BACKEND_URL   = os.environ.get("VLLM_BACKEND_URL", "http://localhost:8000").rstrip("/")
STROMA_API_KEY     = os.environ.get("STROMA_API_KEY", "")
ALLOWED_ROLE       = os.environ.get("GATEWAY_ALLOWED_ROLE", "stroma_researcher")
JWKS_REFRESH_SECS  = int(os.environ.get("JWKS_REFRESH_SECS", "3600"))
# Model watcher HTTP API URL for requesting on-demand models.
WATCHER_URL        = os.environ.get("STROMA_WATCHER_URL", "http://localhost:9100")
# How often (seconds) the gateway polls the watcher for model status updates.
WATCHER_SYNC_SECS  = int(os.environ.get("GATEWAY_WATCHER_SYNC_SECS", "10"))
# When set, this URI is used for JWKS instead of the one in the discovery doc.
# Useful when nginx proxy uses a self-signed cert — point at KC's direct HTTP port.
JWKS_OVERRIDE_URI  = os.environ.get("JWKS_OVERRIDE_URI", "")
# Set GATEWAY_VERIFY_SSL=false to skip TLS cert verification for the discovery fetch.
_VERIFY_SSL        = os.environ.get("GATEWAY_VERIFY_SSL", "true").lower() not in ("0", "false", "no")

log = logging.getLogger("stroma-gateway")

# ---------------------------------------------------------------------------
# JWKS cache — fetch once on startup, refresh on TTL or decode failure
# ---------------------------------------------------------------------------

class _JWKSCache:
    """Thread-safe (asyncio-compatible) in-memory JWKS cache."""

    def __init__(self) -> None:
        self._jwks_client: jwt.PyJWKClient | None = None
        self._issuer: str = ""
        self._fetched_at: float = 0.0

    async def _refresh(self) -> None:
        """Discover issuer and JWKS URI from the OIDC discovery document."""
        if not OIDC_DISCOVERY_URL:
            raise RuntimeError("OIDC_DISCOVERY_URL is not configured")

        async with httpx.AsyncClient(timeout=10, verify=_VERIFY_SSL) as client:
            resp = await client.get(OIDC_DISCOVERY_URL)
            resp.raise_for_status()
            discovery = resp.json()

        self._issuer = discovery["issuer"]
        # Allow operator to override the JWKS URI (e.g. to avoid fetching through
        # a self-signed TLS proxy — point directly at internal KC HTTP port instead)
        jwks_uri = JWKS_OVERRIDE_URI if JWKS_OVERRIDE_URI else discovery["jwks_uri"]
        # PyJWKClient handles key selection for us (kid matching)
        self._jwks_client = jwt.PyJWKClient(jwks_uri, cache_keys=True)
        self._fetched_at  = time.monotonic()
        log.info("JWKS refreshed from %s (issuer: %s)", jwks_uri, self._issuer)

    async def get_signing_key(self, token: str) -> jwt.PyJWK:
        """Return the signing key for this token, refreshing the cache if stale."""
        if (
            self._jwks_client is None
            or (time.monotonic() - self._fetched_at) > JWKS_REFRESH_SECS
        ):
            await self._refresh()

        assert self._jwks_client is not None
        try:
            return self._jwks_client.get_signing_key_from_jwt(token)
        except jwt.exceptions.PyJWKClientError:
            # Key not found — may mean keys were rotated; force refresh once
            await self._refresh()
            return self._jwks_client.get_signing_key_from_jwt(token)

    @property
    def issuer(self) -> str:
        return self._issuer


_jwks_cache = _JWKSCache()

# ---------------------------------------------------------------------------
# Model registry — shared catalog of all discovered models
# ---------------------------------------------------------------------------

_registry = ModelRegistry()

# ---------------------------------------------------------------------------
# Lifespan — warm the JWKS cache and scan models before accepting requests
# ---------------------------------------------------------------------------

@asynccontextmanager
async def lifespan(app: FastAPI):
    if not OIDC_DISCOVERY_URL:
        log.warning(
            "OIDC_DISCOVERY_URL not set — all authenticated requests will fail. "
            "Set the variable and restart."
        )
    else:
        try:
            await _jwks_cache._refresh()
        except Exception as exc:
            # Non-fatal at startup so the process doesn't crash on transient IdP
            # connectivity issues; first request will retry.
            log.error("JWKS pre-fetch failed: %s — will retry on first request", exc)

    if not STROMA_API_KEY:
        log.warning("STROMA_API_KEY is not set — backend requests will be unauthenticated")
    if not VLLM_BACKEND_URL:
        log.error("VLLM_BACKEND_URL is not set — proxy will fail on every request")

    # Scan model catalog and mark persistent model as serving
    count = _registry.scan()
    log.info("Model registry: %d model(s) found", count)
    persistent = _registry.get_persistent_model()
    if persistent:
        _registry.update_status(
            persistent.model_id, ModelStatus.SERVING,
            vllm_port=int(os.environ.get("STROMA_VLLM_PORT", "8000")),
        )
        log.info("Persistent model: %s (port %s)", persistent.model_id, persistent.vllm_port)

    # Start background sync with the model watcher
    sync_task = asyncio.create_task(_sync_watcher_status())

    yield  # Application runs here

    sync_task.cancel()
    log.info("Gateway shutting down")


# ---------------------------------------------------------------------------
# FastAPI app
# ---------------------------------------------------------------------------

app = FastAPI(
    title="StromaAI Secure Gateway",
    description=(
        "OIDC-authenticated proxy to the StromaAI vLLM inference backend. "
        "Requires a valid Bearer token with the stroma_researcher realm role."
    ),
    version="1.0.0",
    lifespan=lifespan,
    # Disable the /docs and /redoc endpoints in production by setting
    # GATEWAY_DISABLE_DOCS=1 (add os.environ check if needed)
)

_bearer_scheme = HTTPBearer(auto_error=True)


# ---------------------------------------------------------------------------
# JWT validation dependency
# ---------------------------------------------------------------------------

async def validate_token(
    credentials: Annotated[HTTPAuthorizationCredentials, Depends(_bearer_scheme)],
) -> dict[str, Any]:
    """
    FastAPI dependency that validates a Bearer JWT.

    Returns the decoded claims dict on success.
    Raises HTTP 401 on any validation failure (invalid token, wrong issuer,
    expired, wrong audience).
    Raises HTTP 403 if the token is valid but lacks the required role.
    """
    token = credentials.credentials

    # Static API key bypass — allows server-to-server callers (e.g. OpenWebUI)
    # to authenticate without OIDC round-trips.  STROMA_API_KEY is a 256-bit
    # hex secret never shared with end-users; all interactive researcher access
    # still goes through the full OIDC flow via nginx.
    if STROMA_API_KEY and token == STROMA_API_KEY:
        return {"sub": "api-key-bypass", "realm_access": {"roles": [ALLOWED_ROLE]}}

    _401 = HTTPException(
        status_code=status.HTTP_401_UNAUTHORIZED,
        detail="Invalid or expired authentication token",
        headers={"WWW-Authenticate": "Bearer"},
    )

    try:
        signing_key = await _jwks_cache.get_signing_key(token)
    except Exception as exc:
        log.warning("JWKS key lookup failed: %s", exc)
        raise _401 from exc

    try:
        claims = jwt.decode(
            token,
            signing_key.key,
            algorithms=["RS256", "ES256"],
            issuer=_jwks_cache.issuer,
            audience=OIDC_AUDIENCE,
            options={
                "require": ["exp", "iss", "sub"],
                "verify_exp": True,
                "verify_iss": True,
                "verify_aud": True,
            },
        )
    except jwt.ExpiredSignatureError:
        log.debug("Rejected expired token")
        raise _401
    except jwt.InvalidTokenError as exc:
        log.debug("Token validation failed: %s", exc)
        raise _401

    # -----------------------------------------------------------------------
    # Role check — realm_access.roles (Keycloak standard claim placement)
    # -----------------------------------------------------------------------
    realm_roles: list[str] = (
        claims.get("realm_access", {}).get("roles", [])
    )
    if ALLOWED_ROLE not in realm_roles:
        log.warning(
            "Access denied — sub=%s lacks role '%s' (has: %s)",
            claims.get("sub", "unknown"),
            ALLOWED_ROLE,
            realm_roles,
        )
        raise HTTPException(
            status_code=status.HTTP_403_FORBIDDEN,
            detail=(
                f"You do not have the '{ALLOWED_ROLE}' role required for "
                "StromaAI inference access. Contact your administrator."
            ),
        )

    log.debug(
        "Authenticated sub=%s roles=%s",
        claims.get("sub", "unknown"),
        realm_roles,
    )
    return claims


# ---------------------------------------------------------------------------
# Health endpoint (unauthenticated — used by load balancers)
# ---------------------------------------------------------------------------

@app.get("/health", include_in_schema=False)
async def health() -> JSONResponse:
    return JSONResponse({"status": "ok", "service": "stroma-gateway"})


# ---------------------------------------------------------------------------
# Helper — resolve the backend base URL for a given model
# ---------------------------------------------------------------------------

def _backend_url_for_port(port: int) -> str:
    """Build backend base URL from the vLLM port number.

    Uses the host portion of ``VLLM_BACKEND_URL`` so operators only
    configure the hostname once.
    """
    # VLLM_BACKEND_URL is e.g. "http://localhost:8000"
    from urllib.parse import urlparse

    parsed = urlparse(VLLM_BACKEND_URL)
    return f"{parsed.scheme}://{parsed.hostname}:{port}"


# ---------------------------------------------------------------------------
# Helper — signal the model watcher to provision an on-demand model
# ---------------------------------------------------------------------------

async def _signal_watcher(model_id: str) -> bool:
    """POST to the watcher's HTTP API requesting an on-demand model start.

    Returns True if the watcher accepted the request, False on failure
    (watcher down, etc.).  Failures are logged but never raised — the
    gateway still returns 503 to the caller.
    """
    try:
        async with httpx.AsyncClient(timeout=5) as client:
            resp = await client.post(f"{WATCHER_URL}/request-model/{model_id}")
            if resp.status_code < 300:
                log.info("Watcher accepted model request: %s", model_id)
                return True
            log.warning("Watcher rejected model request %s: %s", model_id, resp.status_code)
    except httpx.RequestError as exc:
        log.warning("Could not reach model watcher at %s: %s", WATCHER_URL, exc)
    return False


# ---------------------------------------------------------------------------
# Background — sync model statuses from the watcher periodically
# ---------------------------------------------------------------------------

_STATUS_MAP = {v.value: v for v in ModelStatus}

async def _sync_watcher_status() -> None:
    """Poll the watcher's ``/status`` endpoint and update the gateway registry.

    Runs forever as a background task.  On each cycle the watcher returns the
    authoritative status, vllm_port, and slurm_job_ids for every model.  The
    gateway applies those to its own in-memory registry so the proxy can route
    requests to newly-serving models without a gateway restart.
    """
    while True:
        await asyncio.sleep(WATCHER_SYNC_SECS)
        try:
            async with httpx.AsyncClient(timeout=5) as client:
                resp = await client.get(f"{WATCHER_URL}/status")
            if resp.status_code != 200:
                continue
            data = resp.json()
            for model_id, info in data.get("models", {}).items():
                status_str = info.get("status", "")
                new_status = _STATUS_MAP.get(status_str)
                if new_status is None:
                    continue
                entry = _registry.get_model(model_id)
                if entry is None:
                    continue
                # Only update if the status actually changed
                if entry.status != new_status or entry.vllm_port != info.get("vllm_port"):
                    kwargs: dict[str, object] = {}
                    if info.get("vllm_port"):
                        kwargs["vllm_port"] = info["vllm_port"]
                    if info.get("error_message"):
                        kwargs["error_message"] = info["error_message"]
                    if entry.status != new_status:
                        log.info(
                            "Watcher sync: %s %s → %s",
                            model_id, entry.status.value, new_status.value,
                        )
                    _registry.update_status(model_id, new_status, **kwargs)
        except Exception:
            # Watcher unavailable — not fatal, just skip this cycle
            pass


# ---------------------------------------------------------------------------
# /v1/models — aggregated catalog from the registry (NOT proxied to vLLM)
# ---------------------------------------------------------------------------
# This route MUST be defined BEFORE the catch-all /v1/{path:path} so FastAPI
# matches it first.

@app.get("/v1/models")
async def list_models(
    _claims: Annotated[dict, Depends(validate_token)],
) -> JSONResponse:
    """Return the full model catalog in OpenAI-compatible format.

    Every discovered model is listed regardless of whether it is currently
    serving.  On-demand models that are not yet running include a
    ``stroma_status`` field so clients can display a loading indicator.
    """
    return JSONResponse(_registry.openai_models_response())


# ---------------------------------------------------------------------------
# Proxy — forward /v1/* requests to the correct vLLM backend
# ---------------------------------------------------------------------------

# Paths that carry a ``model`` field in the JSON body.
_MODEL_BODY_PATHS = {"chat/completions", "completions", "embeddings"}

@app.api_route(
    "/v1/{path:path}",
    methods=["GET", "POST", "PUT", "DELETE", "OPTIONS"],
    response_model=None,
)
async def proxy_to_vllm(
    path: str,
    request: Request,
    _claims: Annotated[dict, Depends(validate_token)],
) -> StreamingResponse | JSONResponse:
    """
    Model-aware authenticated proxy.

    For inference paths (chat/completions, completions, embeddings) the
    ``model`` field is extracted from the JSON body and used to look up the
    correct backend in the model registry:

      * **SERVING** — proxy to the model's vLLM port
      * **AVAILABLE / REQUESTED** — signal the watcher then return 503 with
        ``Retry-After`` so the client knows to poll again
      * **Unknown model** — 404

    All other /v1/* paths (e.g. /v1/chat/tokenize) are forwarded to the
    persistent model's backend unchanged.
    """
    body   = await request.body()
    params = dict(request.query_params)

    # --- Resolve the target backend URL based on model field -----------------
    backend_base = VLLM_BACKEND_URL  # default: persistent model

    if path in _MODEL_BODY_PATHS and body and request.method == "POST":
        import json as _json

        try:
            payload = _json.loads(body)
        except (ValueError, UnicodeDecodeError):
            payload = {}

        requested_model = payload.get("model")
        if requested_model:
            entry = _registry.get_model(requested_model)
            if entry is None:
                raise HTTPException(
                    status_code=status.HTTP_404_NOT_FOUND,
                    detail=f"Model '{requested_model}' not found in catalog",
                )

            if entry.status == ModelStatus.SERVING and entry.vllm_port:
                backend_base = _backend_url_for_port(entry.vllm_port)
            elif entry.status in (ModelStatus.AVAILABLE, ModelStatus.REQUESTED):
                # Signal the watcher every time — covers first request and
                # retries where the previous signal was lost.  The watcher
                # is idempotent; repeated POSTs for an already-requested
                # model are harmless.
                _registry.update_status(entry.model_id, ModelStatus.REQUESTED)
                await _signal_watcher(entry.model_id)
                return JSONResponse(
                    status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                    content={
                        "error": {
                            "message": (
                                f"Model '{entry.display_name}' is starting up. "
                                "Please retry in a few minutes."
                            ),
                            "type": "model_not_ready",
                            "code": "model_starting",
                            "model": entry.model_id,
                            "stroma_status": entry.status.value,
                        },
                    },
                    headers={"Retry-After": "180"},
                )
            elif entry.status == ModelStatus.PROVISIONING:
                return JSONResponse(
                    status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
                    content={
                        "error": {
                            "message": (
                                f"Model '{entry.display_name}' is loading "
                                f"(GPU resources allocated). Please retry shortly."
                            ),
                            "type": "model_not_ready",
                            "code": "model_provisioning",
                            "model": entry.model_id,
                            "stroma_status": entry.status.value,
                        },
                    },
                    headers={"Retry-After": "60"},
                )
            elif entry.status == ModelStatus.ERROR:
                raise HTTPException(
                    status_code=status.HTTP_502_BAD_GATEWAY,
                    detail=f"Model '{entry.display_name}' failed to start: {entry.error_message}",
                )

    target_url = f"{backend_base}/v1/{path}"

    # --- Forward headers -----------------------------------------------------
    forward_headers: dict[str, str] = {}
    _skip = {"host", "authorization", "content-length", "transfer-encoding"}
    for k, v in request.headers.items():
        if k.lower() not in _skip:
            forward_headers[k] = v

    if STROMA_API_KEY:
        forward_headers["Authorization"] = f"Bearer {STROMA_API_KEY}"

    # --- Stream the response from the backend --------------------------------
    client = httpx.AsyncClient(timeout=httpx.Timeout(connect=10.0, read=None, write=30.0, pool=10.0))

    backend_req = client.build_request(
        request.method,
        target_url,
        params=params,
        content=body,
        headers=forward_headers,
    )

    try:
        backend_resp = await client.send(backend_req, stream=True)
    except httpx.RequestError as exc:
        await client.aclose()
        log.error("Backend request failed (%s): %s", target_url, exc)
        raise HTTPException(
            status_code=status.HTTP_502_BAD_GATEWAY,
            detail="Upstream inference service unavailable",
        ) from exc

    content_type    = backend_resp.headers.get("content-type", "application/json")
    response_status = backend_resp.status_code

    async def _stream_and_close():
        try:
            async for chunk in backend_resp.aiter_bytes():
                yield chunk
        finally:
            await backend_resp.aclose()
            await client.aclose()

    return StreamingResponse(
        _stream_and_close(),
        status_code=response_status,
        media_type=content_type,
    )


# ---------------------------------------------------------------------------
# Global exception handler — never leak internal tracebacks to clients
# ---------------------------------------------------------------------------

@app.exception_handler(Exception)
async def _unhandled(request: Request, exc: Exception) -> JSONResponse:
    log.exception("Unhandled exception on %s %s", request.method, request.url.path)
    return JSONResponse(
        status_code=status.HTTP_500_INTERNAL_SERVER_ERROR,
        content={"detail": "An internal error occurred. Contact your administrator."},
    )


# ---------------------------------------------------------------------------
# Entrypoint (direct execution)
# ---------------------------------------------------------------------------

if __name__ == "__main__":
    import uvicorn

    uvicorn.run(
        "gateway:app",
        host="0.0.0.0",                              # noqa: S104 — intentional bind; TLS in front
        port=int(os.environ.get("GATEWAY_PORT", "9000")),
        log_level=os.environ.get("GATEWAY_LOG_LEVEL", "info"),
        access_log=True,
        proxy_headers=True,                          # trust X-Forwarded-* from nginx
        forwarded_allow_ips="*",
    )
