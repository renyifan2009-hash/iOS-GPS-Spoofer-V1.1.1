#!/usr/bin/env bash
#
# Start an AnyWhere build in its launch self-test mode and say whether it works.
#
#   scripts/self-test.sh <path to the app's executable> [seconds to wait, default 90]
#
# The app (see Sources/iosgpsspoofer-gui/SelfTest.swift) runs headless for a few seconds, prints
# "SELF-TEST-OK" and quits 0. This script waits for that. If the app crashes it says so; if it
# hangs it takes a `sample` of where it is stuck (so the cause is in the log), then stops it.
# Exit status: 0 = it started, 1 = it didn't. Used by CI and by setup.sh.

set -u
exe="${1:?usage: scripts/self-test.sh <executable> [seconds]}"
limit="${2:-90}"
out="$(mktemp "${TMPDIR:-/tmp}/anywhere-selftest.XXXXXX")"
trap 'rm -f "$out"' EXIT

ANYWHERE_SELF_TEST=1 ANYWHERE_SELF_TEST_SECONDS="${ANYWHERE_SELF_TEST_SECONDS:-5}" "$exe" >"$out" 2>&1 </dev/null &
pid=$!
waited=0
while kill -0 "$pid" 2>/dev/null; do
  if [ "$waited" -ge "$limit" ]; then
    echo "self-test: still running after ${limit}s, so it is stuck. Where it is stuck:" >&2
    if command -v sample >/dev/null 2>&1; then
      sample "$pid" 3 -mayDie 2>&1 | sed -n '1,120p' >&2 || true
    fi
    kill -KILL "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
    echo "--- what the app printed ---" >&2
    cat "$out" >&2
    exit 1
  fi
  sleep 1
  waited=$((waited + 1))
done
status=0
wait "$pid" 2>/dev/null || status=$?
cat "$out"
if [ "$status" = 0 ] && grep -q '^SELF-TEST-OK' "$out"; then
  exit 0
fi
echo "self-test: the app ended with status $status without saying SELF-TEST-OK." >&2
exit 1
