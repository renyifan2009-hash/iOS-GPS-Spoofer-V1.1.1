#!/usr/bin/env bash
#
# Build the GUI as a double-clickable "iOS GPS Spoofer.app" and wrap it in a DMG.
#
#   ./package-dmg.sh              # bundles the .venv (pymobiledevice3) into the app
#   ./package-dmg.sh --no-venv    # lean build; the app expects pymobiledevice3 on PATH
#
# Output: dist/iOS-GPS-Spoofer-<version>.dmg
#
# NOTE on the bundled venv: it's a copy of ./.venv, whose Python still points at
# this machine's Homebrew Python (see .venv/pyvenv.cfg). The DMG therefore runs
# on this Mac and on Macs with the same `brew install python@3.x`. For a fully
# portable build, use --no-venv and have users install pymobiledevice3 themselves.

set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="iOS GPS Spoofer"
BUNDLE_ID="com.iosgpsspoofer.gui"
VERSION="${VERSION:-2.0.0}"
BUILD_DIR="build"
DIST_DIR="dist"
APP="$BUILD_DIR/$APP_NAME.app"
BUNDLE_VENV=1

for arg in "$@"; do
  case "$arg" in
    --no-venv) BUNDLE_VENV=0 ;;
    -h|--help) sed -n '2,15p' "$0"; exit 0 ;;
    *) echo "unknown option: $arg" >&2; exit 1 ;;
  esac
done

echo "==> swift build -c release"
swift build -c release --product iosgpsspoofer-gui
BIN=".build/release/iosgpsspoofer-gui"

echo "==> assembling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/$APP_NAME"
chmod +x "$APP/Contents/MacOS/$APP_NAME"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>CFBundleName</key><string>$APP_NAME</string>
  <key>CFBundleDisplayName</key><string>$APP_NAME</string>
  <key>CFBundleExecutable</key><string>$APP_NAME</string>
  <key>CFBundleIdentifier</key><string>$BUNDLE_ID</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>LSMinimumSystemVersion</key><string>14.0</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
  <key>NSHighResolutionCapable</key><true/>
  <key>NSHumanReadableCopyright</key><string>Uses Apple developer location-simulation via pymobiledevice3.</string>
  <key>ITSAppUsesNonExemptEncryption</key><false/>
</dict></plist>
PLIST

echo "==> generating icon"
# The app draws its own icon (AppIcon.swift); render it to an .iconset.
ICON_TMP="$(mktemp -d)"
if "$BIN" --render-icon "$ICON_TMP/AppIcon.iconset" \
   && iconutil -c icns "$ICON_TMP/AppIcon.iconset" -o "$APP/Contents/Resources/AppIcon.icns"; then
  :
else
  echo "   icon generation failed — app will use the default icon"
  /usr/libexec/PlistBuddy -c "Delete :CFBundleIconFile" "$APP/Contents/Info.plist" 2>/dev/null || true
fi
rm -rf "$ICON_TMP"

if [ "$BUNDLE_VENV" = 1 ]; then
  if [ ! -x .venv/bin/pymobiledevice3 ]; then
    echo "!! .venv/bin/pymobiledevice3 not found. Run ./setup.sh first, or use --no-venv." >&2
    exit 1
  fi
  echo "==> bundling .venv (pymobiledevice3 $(.venv/bin/pymobiledevice3 version 2>/dev/null || echo '?'))"
  rm -rf "$APP/Contents/Resources/venv"
  cp -R .venv "$APP/Contents/Resources/venv"
  find "$APP/Contents/Resources/venv" -type d -name '__pycache__' -exec rm -rf {} + 2>/dev/null || true
  find "$APP/Contents/Resources/venv" -type f -name '*.pyc' -delete 2>/dev/null || true
  rm -rf "$APP/Contents/Resources/venv"/lib/python*/site-packages/{pip,pip-*,setuptools,pkg_resources,_distutils_hack} 2>/dev/null || true
  rm -rf "$APP/Contents/Resources/venv"/lib/python*/site-packages/*.dist-info/RECORD 2>/dev/null || true
else
  echo "==> --no-venv: app will look for pymobiledevice3 on PATH / \$PYMOBILEDEVICE3"
fi

echo "==> codesigning (ad-hoc)"
codesign --force --deep --sign - "$APP" 2>/dev/null \
  || codesign --force --sign - "$APP/Contents/MacOS/$APP_NAME"

echo "==> creating DMG"
mkdir -p "$DIST_DIR"
STAGING="$(mktemp -d)"
cp -R "$APP" "$STAGING/"
ln -s /Applications "$STAGING/Applications"
DMG="$DIST_DIR/${APP_NAME// /-}-$VERSION.dmg"
rm -f "$DMG"
hdiutil create -volname "$APP_NAME" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGING"

SIZE="$(du -h "$DMG" | cut -f1)"
echo
echo "==> done: $DMG  ($SIZE)"
echo "    Open it, drag the app to Applications."
echo "    First launch: right-click ▸ Open (ad-hoc signed, so Gatekeeper warns once)."
