"""
Unit tests for the FastAPI secure gateway (src/gateway.py).

Uses pytest-asyncio + respx (async httpx mock) + cryptography to generate
ephemeral RSA key pairs so JWT creation and validation can be exercised
end-to-end without a live Keycloak instance.
"""

from __future__ import annotations

import json
import time
from typing import Any
from unittest.mock import AsyncMock, MagicMock, patch

import jwt
import pytest
import pytest_asyncio
from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import rsa
from fastapi.testclient import TestClient
from httpx import AsyncClient

# ---------------------------------------------------------------------------
# Generate an ephemeral RSA key pair for signing test JWTs
# ---------------------------------------------------------------------------

_PRIVATE_KEY = rsa.generate_private_key(
    public_exponent=65537,
    key_size=2048,
)
_PRIVATE_KEY_PEM = _PRIVATE_KEY.private_bytes(
    serialization.Encoding.PEM,
    serialization.PrivateFormat.TraditionalOpenSSL,
    serialization.NoEncryption(),
)
_PUBLIC_KEY = _PRIVATE_KEY.public_key()


def _make_token(
    sub: str = "user-123",
    roles: list[str] | None = None,
    exp_offset: int = 900,
    audience: str = "stroma-gateway",
    issuer: str = "http://keycloak.test/realms/stroma-ai",
) -> str:
    """Create a signed RS256 JWT for testing."""
    now = int(time.time())
    payload: dict[str, Any] = {
        "sub": sub,
        "iss": issuer,
        "aud": audience,
        "iat": now,
        "exp": now + exp_offset,
        "realm_access": {"roles": roles if roles is not None else ["stroma_researcher"]},
    }
    return jwt.encode(payload, _PRIVATE_KEY, algorithm="RS256")


# ---------------------------------------------------------------------------
# Fixtures: mock JWKS + discovery
# ---------------------------------------------------------------------------

@pytest.fixture(autouse=True)
def _patch_oidc(monkeypatch):
    """
    Patch the _jwks_cache so tests don't need a live Keycloak.

    The cache's _issuer is set to the test issuer, and get_signing_key
    returns a PyJWK wrapping the test public key.
    """
    from src import gateway

    # Inject a known issuer into the module-level cache
    gateway._jwks_cache._issuer = "http://keycloak.test/realms/stroma-ai"

    # Make get_signing_key return a mock that carries the real RSA public key
    async def _mock_get_signing_key(token: str):
        key_mock = MagicMock()
        key_mock.key = _PUBLIC_KEY
        return key_mock

    monkeypatch.setattr(gateway._jwks_cache, "get_signing_key", _mock_get_signing_key)
    monkeypatch.setenv("OIDC_AUDIENCE", "stroma-gateway")
    monkeypatch.setenv("GATEWAY_ALLOWED_ROLE", "stroma_researcher")
    monkeypatch.setenv("VLLM_BACKEND_URL", "http://vllm-backend.test")
    monkeypatch.setenv("STROMA_API_KEY", "internal-test-key")


@pytest.fixture()
def client():
    """Synchronous TestClient for non-streaming endpoint tests."""
    from src.gateway import app
    with TestClient(app, raise_server_exceptions=False) as c:
        yield c


# ---------------------------------------------------------------------------
# Health endpoint (unauthenticated)
# ---------------------------------------------------------------------------

class TestHealthEndpoint:

    def test_returns_200_without_auth(self, client):
        resp = client.get("/health")
        assert resp.status_code == 200
        assert resp.json()["status"] == "ok"

    def test_returns_service_name(self, client):
        resp = client.get("/health")
        assert resp.json()["service"] == "stroma-gateway"


# ---------------------------------------------------------------------------
# Authentication: missing / malformed token
# ---------------------------------------------------------------------------

class TestAuthMissing:

    def test_no_auth_header_returns_403(self, client):
        resp = client.post("/v1/chat/completions", json={})
        # FastAPI HTTPBearer returns 403 when no credentials provided
        assert resp.status_code in (401, 403)

    def test_non_bearer_scheme_rejected(self, client):
        resp = client.post(
            "/v1/chat/completions",
            headers={"Authorization": "Basic dXNlcjpwYXNz"},
            json={},
        )
        assert resp.status_code in (401, 403)


# ---------------------------------------------------------------------------
# Authentication: invalid token
# ---------------------------------------------------------------------------

class TestAuthInvalid:

    def test_expired_token_returns_401(self, client):
        token = _make_token(exp_offset=-60)  # already expired
        resp  = client.post(
            "/v1/chat/completions",
            headers={"Authorization": f"Bearer {token}"},
            json={},
        )
        assert resp.status_code == 401

    def test_wrong_issuer_returns_401(self, client):
        token = _make_token(issuer="http://evil.com/realms/bad")
        resp  = client.post(
            "/v1/chat/completions",
            headers={"Authorization": f"Bearer {token}"},
            json={},
        )
        assert resp.status_code == 401

    def test_wrong_audience_returns_401(self, client):
        token = _make_token(audience="wrong-audience")
        resp  = client.post(
            "/v1/chat/completions",
            headers={"Authorization": f"Bearer {token}"},
            json={},
        )
        assert resp.status_code == 401

    def test_garbage_token_returns_401(self, client):
        resp = client.post(
            "/v1/chat/completions",
            headers={"Authorization": "Bearer not.a.jwt"},
            json={},
        )
        assert resp.status_code == 401


# ---------------------------------------------------------------------------
# Authorization: missing role
# ---------------------------------------------------------------------------

class TestAuthorizationRole:

    def test_valid_token_wrong_role_returns_403(self, client):
        token = _make_token(roles=["some_other_role"])
        resp  = client.post(
            "/v1/chat/completions",
            headers={"Authorization": f"Bearer {token}"},
            json={},
        )
        assert resp.status_code == 403

    def test_empty_roles_returns_403(self, client):
        token = _make_token(roles=[])
        resp  = client.post(
            "/v1/chat/completions",
            headers={"Authorization": f"Bearer {token}"},
            json={},
        )
        assert resp.status_code == 403

    def test_stroma_admin_also_has_researcher_role_passes(self, client):
        """stroma_admin is a composite that includes stroma_researcher."""
        token = _make_token(roles=["stroma_admin", "stroma_researcher"])
        # We need to mock the backend response too
        import respx
        import httpx as _httpx

        with respx.mock:
            respx.post("http://vllm-backend.test/chat/completions").mock(
                return_value=_httpx.Response(200, json={"choices": []})
            )
            resp = client.post(
                "/v1/chat/completions",
                headers={"Authorization": f"Bearer {token}"},
                json={"model": "test", "messages": []},
            )
        assert resp.status_code == 200


# ---------------------------------------------------------------------------
# Proxy: authorised request forwarded correctly
# ---------------------------------------------------------------------------

class TestProxy:

    def test_internal_api_key_substituted(self, client):
        """The OIDC Bearer token must NOT reach the backend — only the internal key."""
        import respx
        import httpx as _httpx

        captured_headers: dict[str, str] = {}

        def _capture_request(request):
            captured_headers.update(dict(request.headers))
            return _httpx.Response(200, json={"id": "cmpl-test"})

        token = _make_token()
        with respx.mock:
            respx.post("http://vllm-backend.test/chat/completions").mock(
                side_effect=_capture_request
            )
            client.post(
                "/v1/chat/completions",
                headers={"Authorization": f"Bearer {token}"},
                json={"model": "test", "messages": []},
            )

        auth = captured_headers.get("authorization", "")
        assert auth == "Bearer internal-test-key"
        # Original OIDC token must not be forwarded
        assert "eyJ" not in auth  # OIDC JWTs start with "eyJ"

    def test_backend_error_forwarded(self, client):
        import respx
        import httpx as _httpx

        token = _make_token()
        with respx.mock:
            respx.post("http://vllm-backend.test/chat/completions").mock(
                return_value=_httpx.Response(503, json={"error": "backend down"})
            )
            resp = client.post(
                "/v1/chat/completions",
                headers={"Authorization": f"Bearer {token}"},
                json={"model": "test", "messages": []},
            )
        assert resp.status_code == 503

    def test_backend_unreachable_returns_502(self, client):
        import respx
        import httpx as _httpx

        token = _make_token()
        with respx.mock:
            respx.post("http://vllm-backend.test/chat/completions").mock(
                side_effect=_httpx.ConnectError("connection refused")
            )
            resp = client.post(
                "/v1/chat/completions",
                headers={"Authorization": f"Bearer {token}"},
                json={"model": "test", "messages": []},
            )
        assert resp.status_code == 502
