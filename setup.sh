#!/usr/bin/env bash
# One-time setup: create the Python venv with pymobiledevice3 and build the tool.
set -euo pipefail
cd "$(dirname "$0")"

if [ ! -x .venv/bin/pymobiledevice3 ]; then
  echo "==> creating .venv with pymobiledevice3"
  python3 -m venv .venv
  .venv/bin/pip install --quiet --upgrade pip pymobiledevice3
fi

PMD_VERSION="$(.venv/bin/pymobiledevice3 version 2>/dev/null || true)"
if [ -z "$PMD_VERSION" ]; then
  echo "!! .venv/bin/pymobiledevice3 doesn't run. Delete .venv and re-run ./setup.sh." >&2
  exit 1
fi
echo "==> pymobiledevice3 $PMD_VERSION ready"
case "$PMD_VERSION" in
  [0-9].*|10.*)
    echo "   note: version 11+ is recommended (needed for the default 'native' tunnel)."
    echo "         Upgrade with: .venv/bin/pip install -U pymobiledevice3"
    ;;
esac

echo "==> building (release): CLI + GUI"
swift build -c release

ROOT="$(pwd)"
echo
echo "Done."
echo "  Check:  $ROOT/.build/release/iosgpsspoof doctor"
echo "  CLI:    $ROOT/.build/release/iosgpsspoof list"
echo "  GUI:    $ROOT/.build/release/iosgpsspoofer-gui     (or ./run-gui.sh)"
