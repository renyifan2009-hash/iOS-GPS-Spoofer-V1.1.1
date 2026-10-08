#!/usr/bin/env bash
# For development: build the GUI and run it straight from the build folder,
# with its output in this terminal. To install the app for everyday use,
# run ./setup.sh instead.
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release --product iosgpsspoofer-gui
exec "$(swift build -c release --show-bin-path)/iosgpsspoofer-gui"
