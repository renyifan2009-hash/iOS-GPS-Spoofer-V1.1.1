#!/usr/bin/env bash
#
# Build "iOS GPS Spoofer.app" and wrap it in a drag-to-install DMG.
#
#   ./package-dmg.sh             # → dist/iOS-GPS-Spoofer-<version>.dmg
#
# The DMG holds just the app. The app looks for pymobiledevice3 where
# ./setup.sh installs it, and also finds pipx and Homebrew installs.
# Set VERSION to override the version in the VERSION file.

set -euo pipefail
cd "$(dirname "$0")"

for arg in "$@"; do
  case "$arg" in
    --no-venv) ;;   # accepted for older scripts: the app is always built without one
    -h|--help) sed -n '3,9p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 1 ;;
  esac
done

APP_NAME="iOS GPS Spoofer"
export VERSION="${VERSION:-$(tr -d '[:space:]' < VERSION)}"

echo "==> swift build -c release"
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

echo "==> assembling the app"
APP="$(scripts/make-app.sh "$BIN_DIR" build | tail -1)"

echo "==> creating the DMG"
mkdir -p dist
STAGING="$(mktemp -d)"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
DMG="dist/${APP_NAME// /-}-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGING"

echo
echo "==> done: $DMG ($(du -h "$DMG" | cut -f1))"
echo "    Open it and drag the app to Applications. It's ad-hoc signed, so the"
echo "    first time macOS blocks it: open System Settings ▸ Privacy & Security"
echo "    and click Open Anyway."
