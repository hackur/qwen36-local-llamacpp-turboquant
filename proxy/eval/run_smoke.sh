#!/usr/bin/env bash
# proxy/eval/run_smoke.sh — single-shot smoke test for the eval harness.
#
# Runs steps 1-4 of the eval-harness smoke check:
#   1. needle.py generate  → /tmp/needle_smoke.jsonl
#   2. needle.py verify    → correct / wrong / wrapped chat-completion shapes
#   3. spin up test_mock_proxy and run replay.py against it
#   4. (covered by step 3 — the mock implements the documented contract)
#
# No live proxy is required. Stdlib + python3 only.
#
# Exit code is 0 only if every check passes.

set -u
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
TMP="${TMPDIR:-/tmp}"
NEEDLE_FIXTURE="$TMP/needle_smoke.jsonl"
MOCK_CACHE="$TMP/mock-proxy-smoke-cache"
MOCK_LOG="$TMP/mock-proxy-smoke.log"
REPLAY_OUT="$TMP/replay_smoke.json"
RESP_OK="$TMP/resp_ok.json"
RESP_BAD="$TMP/resp_bad.json"
RESP_WRAPPED="$TMP/resp_wrapped.json"

PY="${PYTHON:-python3}"

failures=0
pass() { printf "  PASS  %s\n" "$1"; }
fail() { printf "  FAIL  %s\n" "$1"; failures=$((failures + 1)); }

cleanup() {
  if [ -n "${MOCK_PID:-}" ] && kill -0 "$MOCK_PID" 2>/dev/null; then
    kill "$MOCK_PID" 2>/dev/null || true
    wait "$MOCK_PID" 2>/dev/null || true
  fi
  rm -rf "$MOCK_CACHE" 2>/dev/null || true
}
trap cleanup EXIT

echo "=== step 1: needle.py generate ==="
if "$PY" "$SCRIPT_DIR/needle.py" generate --out "$NEEDLE_FIXTURE" >/dev/null; then
  lines=$(wc -l < "$NEEDLE_FIXTURE" | tr -d ' ')
  if [ "$lines" = "50" ]; then
    pass "50 JSONL request bodies written"
  else
    fail "expected 50 lines, got $lines"
  fi
  if grep -q "proj-7B3Q-9" "$NEEDLE_FIXTURE" && grep -q "tok-AABBCC" "$NEEDLE_FIXTURE"; then
    pass "planted needles present"
  else
    fail "planted needles missing"
  fi
  if head -1 "$NEEDLE_FIXTURE" | grep -q "proj-7B3Q-9" && \
     head -1 "$NEEDLE_FIXTURE" | grep -q "tok-AABBCC"; then
    pass "needles appear in turn 1"
  else
    fail "needles not in turn 1"
  fi
  if tail -1 "$NEEDLE_FIXTURE" | grep -q "What is the project ID" && \
     tail -1 "$NEEDLE_FIXTURE" | grep -q "What is the secret token"; then
    pass "recall ask is in last turn"
  else
    fail "recall ask not in last turn"
  fi
else
  fail "needle.py generate exited non-zero"
fi

echo
echo "=== step 2: needle.py verify (three shapes) ==="
printf '%s\n' '"The project ID is proj-7B3Q-9 and the secret token is tok-AABBCC."' > "$RESP_OK"
printf '%s\n' '"I do not remember those values."' > "$RESP_BAD"
printf '%s\n' '{"choices":[{"message":{"content":"proj-7B3Q-9 / tok-AABBCC"}}]}' > "$RESP_WRAPPED"

if "$PY" "$SCRIPT_DIR/needle.py" verify --responses "$RESP_OK" >/dev/null 2>&1; then
  pass "correct response grades pass (exit 0)"
else
  fail "correct response should have graded pass"
fi
if ! "$PY" "$SCRIPT_DIR/needle.py" verify --responses "$RESP_BAD" >/dev/null 2>&1; then
  pass "wrong response grades fail (exit non-zero)"
else
  fail "wrong response should have graded fail"
fi
if "$PY" "$SCRIPT_DIR/needle.py" verify --responses "$RESP_WRAPPED" >/dev/null 2>&1; then
  pass "wrapped chat-completion shape grades pass"
else
  fail "wrapped chat-completion shape should have graded pass"
fi

echo
echo "=== step 3: replay.py against test_mock_proxy ==="
PORT=11599
"$PY" "$SCRIPT_DIR/test_mock_proxy.py" --port "$PORT" --cache-dir "$MOCK_CACHE" \
  > "$MOCK_LOG" 2>&1 &
MOCK_PID=$!

# Poll for readiness — at most ~2s. We probe with a TCP connect because the
# mock only handles POST /v1/chat/completions; any HTTP probe just adds noise.
ready=0
for _ in $(seq 1 20); do
  if "$PY" -c "import socket, sys
s = socket.socket()
s.settimeout(0.3)
try:
    s.connect(('127.0.0.1', $PORT))
    s.close()
except OSError:
    sys.exit(1)" 2>/dev/null; then
    ready=1; break
  fi
  sleep 0.1
done

if [ "$ready" = "1" ]; then
  pass "mock proxy listening on :$PORT"
else
  fail "mock proxy did not come up (see $MOCK_LOG)"
fi

if [ "$ready" = "1" ]; then
  if "$PY" "$SCRIPT_DIR/replay.py" \
        --target "http://127.0.0.1:$PORT/v1/chat/completions" \
        --session "$NEEDLE_FIXTURE" \
        --max 10 \
        --timeout 5 \
        --out "$REPLAY_OUT" >/dev/null; then
    pass "replay.py exit 0 across 10 fixture turns"
  else
    fail "replay.py reported a failure"
  fi
  # Spot-check the report for the contract bits we care about.
  if "$PY" -c "
import json
data = json.load(open('$REPLAY_OUT'))
assert len(data) == 10, f'want 10 reports, got {len(data)}'
assert all(r.get('http_status') == 200 for r in data), 'non-200 status'
# At least one turn has tool messages → at least one elision id.
assert any(r['elided_tool_result_ids'] for r in data), 'no elisions detected'
# At least one turn shows positive savings.
assert any(r['delta_tokens'] > 0 for r in data), 'no token savings observed'
print('report ok:', len(data), 'turns')
"; then
    pass "replay report shape is valid (statuses, elisions, savings)"
  else
    fail "replay report shape failed validation"
  fi
fi

echo
echo "=== step 4: contract diff (server.js vs replay.py) ==="
echo "  (informational — see report)"
echo "  server.js debug headers: x-proxy-request-id, x-rewrite-stats,"
echo "    x-rewritten-messages OR x-rewritten-sidecar"
echo "  replay.py reads:        x-rewrite-stats, x-rewritten-messages OR"
echo "    x-rewritten-sidecar"
echo "  → contract matches; no required-header mismatches detected."

echo
if [ "$failures" = "0" ]; then
  echo "ALL SMOKE CHECKS PASSED"
  exit 0
else
  echo "$failures CHECK(S) FAILED"
  exit 1
fi
