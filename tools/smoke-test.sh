#!/bin/bash
# End-to-end check against a running bridge.
#
#   swift run                       # in one terminal
#   ./tools/smoke-test.sh 123456     # in another, with the code from the window
#
# Exits non-zero on the first failed assertion, so it works as a CI/rungate.
set -uo pipefail

CODE="${1:?usage: smoke-test.sh <6-digit-code> [port]}"
PORT="${2:-8080}"
BASE="http://127.0.0.1:${PORT}"
JAR="$(mktemp)"
trap 'rm -f "$JAR"' EXIT

fails=0
pass() { printf '  ok    %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; fails=$((fails+1)); }
check() { if [ "$1" = "0" ]; then pass "$2"; else fail "$2"; fi; }

# GNU `timeout` is absent on stock macOS. Use gtimeout if coreutils is
# installed, else emulate with a background killer.
run_limited() {
  local secs="$1"; shift
  if command -v gtimeout >/dev/null 2>&1; then gtimeout "$secs" "$@"; return $?
  elif command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"; return $?
  fi
  "$@" & local pid=$!
  ( sleep "$secs"; kill "$pid" 2>/dev/null ) & local killer=$!
  wait "$pid" 2>/dev/null
  local rc=$?
  kill "$killer" 2>/dev/null
  return $rc
}

echo "== static assets =="
# A regression here is silent and total: if Bundle.module can't find the web
# resources the receiver page is replaced by a "missing web resource" string
# and nothing else in this script is meaningful.
page="$(curl -s --max-time 5 "$BASE/")"
if printf '%s' "$page" | grep -q 'id="code-input"'; then
  pass "GET / serves the pair page"
else
  fail "GET / did not serve the pair page (got: ${page:0:60})"
fi
curl -s --max-time 5 "$BASE/receiver.js" | grep -q 'function connect' \
  && pass "GET /receiver.js serves the client" \
  || fail "GET /receiver.js did not serve the client"

echo "== pairing gate =="
bad="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
        -H 'Content-Type: application/json' -d '{"code":"000000"}' "$BASE/pair")"
[ "$bad" = "403" ] && pass "POST /pair rejects a wrong code (403)" \
                   || fail "POST /pair wrong code returned $bad, want 403"

curl -s --max-time 5 -c "$JAR" -H 'Content-Type: application/json' \
     -d "{\"code\":\"$CODE\"}" "$BASE/pair" | grep -q '"ok":true' \
  && pass "POST /pair accepts the code" \
  || fail "POST /pair rejected the code (is '$CODE' current?)"

TOKEN="$(awk -F'\t' '$6=="odpair"{print $7}' "$JAR")"
[ -n "$TOKEN" ] && pass "pairing cookie issued" || fail "no odpair cookie in jar"

echo "== websocket upgrade =="
nocookie="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 \
             -H 'Connection: Upgrade' -H 'Upgrade: websocket' \
             -H 'Sec-WebSocket-Version: 13' -H 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' \
             "$BASE/od")"
[ "$nocookie" = "403" ] && pass "GET /od without cookie is gated (403)" \
                        || fail "GET /od without cookie returned $nocookie, want 403"

if ! command -v websocat >/dev/null 2>&1; then
  echo "  skip  WebSocket round-trip (install with: brew install websocat)"
else
  # Four websocat invocation traps, all found the hard way:
  #   1. the URL must be ws://, not the http:// base curl uses
  #   2. a bare `-H "Cookie: ..."` EATS the next argument (the URL) — websocat's
  #      own help says to use -H=... or put headers last
  #   3. stdin must stay open after the hello or websocat closes before the
  #      server's reply arrives
  #   4. output must go to a FILE, not a pipe inside $( ): websocat's binary
  #      stdout does not survive command substitution here
  # -b sends frames as BINARY; the binding ignores text frames, so a text hello
  # would be dropped and this would look like a hang.
  #
  # Exactly ONE message is written. `websocat -b` does not split stdin on
  # newlines — it ships the whole of stdin as ONE binary message, so sending
  # hello+ping on two lines just produces a single unparseable frame and the
  # server (correctly) ignores it. Coalesced-frame handling is covered by the
  # unit test instead, where it can be exercised deterministically.
  WS_OUT="$(mktemp)"
  { printf '%s\n' '{"type":"hello","pixelsWide":1170,"pixelsHigh":2532,"scale":2,"device":"iPad","id":"smoke","pv":3}'; sleep 5; } \
    | websocat -b "-H=Cookie: odpair=$TOKEN" "ws://127.0.0.1:$PORT/od" > "$WS_OUT" 2>/dev/null &
  WS_PID=$!
  # Plain sleep, deliberately: `tail --pid` is GNU-only (absent on macOS) and
  # using it here returned instantly, killing websocat before it could reply.
  sleep 6
  kill "$WS_PID" 2>/dev/null
  wait "$WS_PID" 2>/dev/null

  grep -aq '"type":"welcome"' "$WS_OUT" \
    && pass "hello -> welcome round-trip" \
    || fail "no welcome frame received"
  grep -aq '"type":"streamConfig"' "$WS_OUT" \
    && pass "streamConfig follows welcome" \
    || fail "no streamConfig frame received"
  # Video frames need a working H.264 encoder backend; headless/VM hosts may
  # have none at all (VTCopyVideoEncoderList returns empty). welcome +
  # streamConfig without video is an environment limit, not a binding failure.
  echo "  note  video frames not asserted (needs a host H.264 encoder)"
  rm -f "$WS_OUT"
fi

echo
if [ "$fails" -eq 0 ]; then
  echo "smoke test PASSED"
else
  echo "smoke test FAILED ($fails assertion(s))"
fi
exit "$fails"
