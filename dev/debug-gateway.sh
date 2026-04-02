#!/usr/bin/env bash
# Debug script for StromaAI gateway container issues
# Run this on the Linux system where containers are running

set -euo pipefail

echo "=== StromaAI Gateway Debug ==="
echo ""

# Check container status
echo "1. Container status:"
podman ps -a --filter name=gateway --format "{{.Names}}: {{.Status}}"
echo ""

# Get recent logs
echo "2. Recent gateway logs (last 50 lines):"
podman logs --tail 50 dev-stroma-gateway 2>&1 || echo "  Container not found or no logs"
echo ""

# Check if vLLM is reachable
echo "3. Checking vLLM backend:"
VLLM_PORT=$(grep STROMA_VLLM_PORT= .env 2>/dev/null | cut -d= -f2)
VLLM_PORT=${VLLM_PORT:-8000}
if curl -sf "http://localhost:${VLLM_PORT}/health" &>/dev/null; then
    echo "  ✓ vLLM is reachable on :${VLLM_PORT}"
else
    echo "  ✗ vLLM not reachable on :${VLLM_PORT}"
    echo "    Check: podman ps | grep vllm"
fi
echo ""

# Check if Keycloak is reachable
echo "4. Checking Keycloak:"
KC_PORT=$(grep KC_PORT= .env 2>/dev/null | cut -d= -f2)
KC_PORT=${KC_PORT:-8080}
if curl -sf "http://localhost:${KC_PORT}/realms/stroma-ai/.well-known/openid-configuration" &>/dev/null; then
    echo "  ✓ Keycloak OIDC discovery is reachable on :${KC_PORT}"
else
    echo "  ✗ Keycloak not reachable on :${KC_PORT}"
    echo "    Check: podman ps | grep keycloak"
    echo "    May need to wait for Keycloak to finish starting"
fi
echo ""

# Check environment variables
echo "5. Gateway environment (from .env):"
grep -E "^(OIDC_|VLLM_|STROMA_API_KEY|GATEWAY_)" .env 2>/dev/null | head -10 || echo "  No .env file"
echo ""

# Check network connectivity from gateway container
echo "6. Network test from gateway container:"
if podman exec dev-stroma-gateway curl -sf http://host.containers.internal:${KC_PORT}/health &>/dev/null 2>&1; then
    echo "  ✓ Gateway can reach host.containers.internal"
else
    echo "  ✗ Gateway cannot reach host.containers.internal"
    echo "    This may indicate a networking issue"
fi
echo ""

echo "=== Suggestions ==="
echo "If gateway is restarting:"
echo "  1. Check logs above for Python errors or connection failures"
echo "  2. Ensure Keycloak has fully started: podman logs dev-stroma-keycloak | tail"
echo "  3. Ensure vLLM is healthy: curl http://localhost:${VLLM_PORT}/health"
echo "  4. Check gateway can resolve host.containers.internal"
echo ""
echo "To follow gateway logs in real-time:"
echo "  podman logs -f dev-stroma-gateway"
