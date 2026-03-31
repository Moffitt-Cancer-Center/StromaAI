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

Requires
--------
  pip install fastapi uvicorn[standard] httpx PyJWT cryptography

Run
---
  uvicorn src.gateway:app --port 9000
  # or via the CLI: python3 src/stroma_cli.py gateway start
"""

from __future__ import annotations

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

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

OIDC_DISCOVERY_URL = os.environ.get("OIDC_DISCOVERY_URL", "")
OIDC_AUDIENCE      = os.environ.get("OIDC_AUDIENCE", "stroma-gateway")
VLLM_BACKEND_URL   = os.environ.get("VLLM_BACKEND_URL", "http://localhost:8000").rstrip("/")
STROMA_API_KEY     = os.environ.get("STROMA_API_KEY", "")
ALLOWED_ROLE       = os.environ.get("GATEWAY_ALLOWED_ROLE", "stroma_researcher")
JWKS_REFRESH_SECS  = int(os.environ.get("JWKS_REFRESH_SECS", "3600"))

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

        async with httpx.AsyncClient(timeout=10) as client:
            resp = await client.get(OIDC_DISCOVERY_URL)
            resp.raise_for_status()
            discovery = resp.json()

        self._issuer = discovery["issuer"]
        jwks_uri     = discovery["jwks_uri"]
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
# Lifespan — warm the JWKS cache before accepting requests
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

    yield  # Application runs here

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
# Proxy — forward all /v1/* requests to vLLM backend
# ---------------------------------------------------------------------------

@app.api_route(
    "/v1/{path:path}",
    methods=["GET", "POST", "PUT", "DELETE", "OPTIONS"],
)
async def proxy_to_vllm(
    path: str,
    request: Request,
    _claims: Annotated[dict, Depends(validate_token)],
) -> StreamingResponse:
    """
    Authenticated proxy. Substitutes the OIDC Bearer token with the internal
    STROMA_API_KEY before forwarding to the vLLM backend.

    A single streaming connection is opened to the backend. Status code and
    content-type are read from the backend response headers before yielding
    body chunks, so no double-request occurs.
    """
    target_url = f"{VLLM_BACKEND_URL}/{path}"
    params     = dict(request.query_params)
    body       = await request.body()

    # Build forwarded headers — drop the incoming Authorization and inject the
    # internal API key. Pass all other safe headers through unchanged.
    forward_headers: dict[str, str] = {}
    _skip = {"host", "authorization", "content-length", "transfer-encoding"}
    for k, v in request.headers.items():
        if k.lower() not in _skip:
            forward_headers[k] = v

    if STROMA_API_KEY:
        forward_headers["Authorization"] = f"Bearer {STROMA_API_KEY}"

    # Use a shared client with no timeout on the read so streaming completions
    # are not cut off mid-generation.
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
        log.error("Backend request failed: %s", exc)
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
