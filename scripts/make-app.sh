#!/usr/bin/env bash
#
# Wrap a release build into "iOS GPS Spoofer.app": Info.plist, icon, the
# iosgpsspoof command-line tool next to the app, and an ad-hoc signature
# (Apple silicon won't run unsigned code).
#
#   scripts/make-app.sh <bin-dir> <output-dir>
#
# <bin-dir> is where `swift build -c release` put the binaries; ask SwiftPM
# with `swift build -c release --show-bin-path`. The app's path is printed
# on the last line.
#
# Optional environment:
#   VERSION          marketing version (default: the VERSION file)
#   SPOOFER_COMMIT   git commit the build came from (default: git rev-parse HEAD)
#   SPOOFER_REPO     GitHub "owner/name" the app checks for updates

set -euo pipefail

usage="usage: scripts/make-app.sh <bin-dir> <output-dir>"
BIN_DIR="${1:?$usage}"
OUT_DIR="${2:?$usage}"
ROOT="$(cd "$(dirname "$0")/.." && pwd)"

APP_NAME="iOS GPS Spoofer"
BUNDLE_ID="com.iosgpsspoofer.gui"
VERSION="${VERSION:-$(tr -d '[:space:]' < "$ROOT/VERSION")}"
# Only this project's own git history: a folder unzipped inside some other
# repository must not pick up that repository's commit.
COMMIT="${SPOOFER_COMMIT:-}"
if [ -z "$COMMIT" ] && [ -e "$ROOT/.git" ]; then
  COMMIT="$(git -C "$ROOT" rev-parse HEAD 2>/dev/null || true)"
fi
REPO="${SPOOFER_REPO:-renyifan2009-hash/iOS-GPS-Spoofer-V1.1.1}"
BUILD_DATE="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
BUILD_NUMBER="$(date -u +%Y%m%d.%H%M)"

GUI="$BIN_DIR/iosgpsspoofer-gui"
CLI="$BIN_DIR/iosgpsspoof"
for binary in "$GUI" "$CLI"; do
  if [ ! -x "$binary" ]; then
    echo "make-app: $binary is missing. Run 'swift build -c release' first." >&2
    exit 1
  fi
done

APP="$OUT_DIR/$APP_NAME.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$GUI" "$APP/Contents/MacOS/$APP_NAME"
cp "$CLI" "$APP/Contents/MacOS/iosgpsspoof"
chmod +x "$APP/Contents/MacOS/$APP_NAME" "$APP/Contents/MacOS/iosgpsspoof"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleVersion</key><string>$BUILD_NUMBER</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>Uses Apple developer location-simulation via pymobiledevice3.</string>
  <key>NSLocalNetworkUsageDescription</key><string>The iPhone Remote setting lets the SpoofRemote app on your iPhone control this Mac over your local network.</string>
  <key>NSBonjourServices</key><array><string>_iosgpsspoof._tcp</string></array>
  <key>SpooferGitCommit</key><string>$COMMIT</string>
  <key>SpooferRepository</key><string>$REPO</string>
  <key>SpooferBuildDate</key><string>$BUILD_DATE</string>
</dict></plist>
PLIST

# The app draws its own icon (AppIcon.swift), so the icon has a single source.
ICON_TMP="$(mktemp -d)"
if "$GUI" --render-icon "$ICON_TMP/AppIcon.iconset" >/dev/null 2>&1 \
   && iconutil -c icns "$ICON_TMP/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns" 2>/dev/null; then
  :
else
  echo "make-app: icon generation failed; the app will use the default icon." >&2
  /usr/libexec/PlistBuddy -c "Delete :CFBundleIconFile" "$APP/Contents/Info.plist" 2>/dev/null || true
fi
rm -rf "$ICON_TMP"

# Ad-hoc signature, inside-out: the command-line tool, then the bundle.
codesign --force --sign - "$APP/Contents/MacOS/iosgpsspoof" >/dev/null 2>&1
codesign --force --sign - "$APP" >/dev/null 2>&1

echo "$APP"
