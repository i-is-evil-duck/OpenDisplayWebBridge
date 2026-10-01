#!/bin/bash
# Full check: build, unit tests, then (if a bridge is running) the smoke test.
#
#   tools/check.sh              # build + tests
#   tools/check.sh 424242 8099  # also smoke-test a running bridge on that port
set -uo pipefail
cd "$(dirname "$0")/.."

# XCTest ships with the full Xcode toolchain, not the bare Command Line Tools.
# If xcode-select points at CommandLineTools, use the Xcode install instead.
if [ -d /Applications/Xcode.app/Contents/Developer ]; then
  export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi

rc=0
echo "== build =="
if swift build 2>&1 | grep -vE "ld: warning: search path" | tail -3; then :; fi
swift build 2>/dev/null >/dev/null || { echo "BUILD FAILED"; rc=1; }

echo
echo "== unit tests =="
if swift test 2>&1 | grep -E "Executed [0-9]+ tests" | tail -1; then
  swift test 2>/dev/null >/dev/null || { echo "TESTS FAILED"; rc=1; }
else
  echo "TESTS FAILED"; rc=1
fi

if [ $# -ge 1 ]; then
  echo
  echo "== smoke test =="
  ./tools/smoke-test.sh "$@" || rc=1
fi

echo
[ "$rc" -eq 0 ] && echo "ALL CHECKS PASSED" || echo "CHECKS FAILED"
exit "$rc"
