#!/usr/bin/env bash
# proxy/tests/integration.sh
#
# End-to-end integration test against a real llama-server.
# Assumes:
#   - llama-server (turboquant) is running on :10501
#   - the proxy is running on :11500
# This script does NOT start either; run them separately:
#   $ scripts/start-turboquant.sh &
#   $ cd proxy && npm install && npm start &
#   $ proxy/tests/integration.sh
set -euo pipefail

PROXY="${PROXY:-http://127.0.0.1:11500}"
UPSTREAM="${UPSTREAM:-http://127.0.0.1:10501}"

pass() { printf "  ok   %s\n" "$1"; }
fail() { printf "  FAIL %s\n" "$1"; exit 1; }

echo "── preflight ──"
curl -sf "$UPSTREAM/health" >/dev/null || fail "upstream not on :10501"
curl -sf "$PROXY/health"    >/dev/null || fail "proxy not on :11500"
pass "both servers reachable"

echo "── /v1/models ──"
curl -sf "$PROXY/v1/models" | grep -q '"data"' || fail "/v1/models did not return data[]"
pass "/v1/models passthrough"

echo "── /proxy/info ──"
INFO=$(curl -sf "$PROXY/proxy/info")
echo "$INFO" | grep -q '"mode"' || fail "/proxy/info missing mode"
echo "$INFO" | grep -q '"n_ctx"' || fail "/proxy/info missing n_ctx"
pass "/proxy/info reports config"

echo "── non-streaming chat ──"
RESP=$(curl -sf "$PROXY/v1/chat/completions" \
  -H "content-type: application/json" \
  -D /tmp/qwen-compact-headers.txt \
  -d '{"model":"local","messages":[{"role":"user","content":"Reply with the single word: pong"}],"max_tokens":16,"chat_template_kwargs":{"enable_thinking":false}}')
echo "$RESP" | grep -q '"choices"' || fail "non-streaming response missing choices"
grep -qi '^x-proxy-request-id:' /tmp/qwen-compact-headers.txt || fail "missing x-proxy-request-id header"
pass "non-streaming round-trip"

echo "── streaming chat ──"
STREAM=$(curl -sN "$PROXY/v1/chat/completions" \
  -H "content-type: application/json" \
  -d '{"model":"local","messages":[{"role":"user","content":"Count to three."}],"max_tokens":32,"stream":true,"chat_template_kwargs":{"enable_thinking":false}}')
echo "$STREAM" | grep -q '^data: ' || fail "no SSE data: frames"
echo "$STREAM" | tail -n 5 | grep -q 'data: \[DONE\]' || fail "missing terminal [DONE] frame"
pass "streaming round-trip with [DONE]"

echo "── x-compact: off bypass header ──"
curl -sf -o /dev/null -D /tmp/qwen-compact-headers.txt "$PROXY/v1/chat/completions" \
  -H "content-type: application/json" \
  -H "x-compact: off" \
  -d '{"model":"local","messages":[{"role":"user","content":"hi"}],"max_tokens":4,"chat_template_kwargs":{"enable_thinking":false}}'
grep -qi '^x-compact: off' /tmp/qwen-compact-headers.txt || fail "x-compact: off not echoed"
pass "x-compact: off honoured"

echo
echo "all checks passed."
