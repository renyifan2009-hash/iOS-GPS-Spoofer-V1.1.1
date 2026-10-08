#!/bin/bash
# Downloads idevice (https://github.com/jkcoxson/idevice, Rust, MIT), the
# library the iPhone-only mode uses to reach the iPhone's own developer
# services. Checks it against a pinned SHA-256 and unpacks it to
# iPhoneRemote/Vendor/IDevice.xcframework (not in git: about 1.3 GB unpacked).
#
#   iPhoneRemote/scripts/fetch-idevice.sh
#
# IDEVICE_ZIP=/path/to/idevice-xcframework-v0.1.68.zip uses a copy you already
# downloaded. IDEVICE_CACHE_DIR=<folder> keeps the download there for next
# time (CI caches that folder). Either way it's checked against the SHA-256.
set -euo pipefail

VERSION="0.1.68"
SHA256="c9eccdd1942de756d746a2569d93302774ab0eff1cff314ec8118f768b3d8dc7"
URL="https://github.com/jkcoxson/idevice/releases/download/v${VERSION}/idevice-xcframework-v${VERSION}.zip"

HERE="$(cd "$(dirname "$0")/.." && pwd)"
DEST="$HERE/Vendor"
FRAMEWORK="$DEST/IDevice.xcframework"
STAMP="$FRAMEWORK/.idevice-version"

if [ -f "$STAMP" ] && [ "$(cat "$STAMP")" = "$VERSION" ]; then
  echo "idevice $VERSION is already in Vendor/."
  exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

ZIP="${IDEVICE_ZIP:-}"
CACHED="${IDEVICE_CACHE_DIR:-}${IDEVICE_CACHE_DIR:+/idevice-xcframework-v${VERSION}.zip}"
if [ -z "$ZIP" ] && [ -n "$CACHED" ] && [ -f "$CACHED" ]; then
  ZIP="$CACHED"
fi
if [ -z "$ZIP" ]; then
  echo "Downloading idevice $VERSION (about 210 MB)…"
  ZIP="${CACHED:-$WORK/idevice.zip}"
  mkdir -p "$(dirname "$ZIP")"
  curl -fL --retry 3 --progress-bar -o "$ZIP.part" "$URL"
  mv "$ZIP.part" "$ZIP"
fi

echo "$SHA256  $ZIP" | shasum -a 256 -c - >/dev/null || {
  echo "The download doesn't match the pinned SHA-256. Not using it." >&2
  # A bad copy in the cache would fail every run after this one.
  if [ "$ZIP" = "$CACHED" ]; then rm -f "$CACHED"; fi
  exit 1
}

unzip -q "$ZIP" -d "$WORK/unzipped"
FOUND="$(find "$WORK/unzipped" -maxdepth 3 -name IDevice.xcframework -type d | head -1)"
if [ -z "$FOUND" ]; then
  echo "IDevice.xcframework isn't in the download." >&2
  exit 1
fi

rm -rf "$FRAMEWORK"
mkdir -p "$DEST"
mv "$FOUND" "$FRAMEWORK"
echo "$VERSION" > "$STAMP"
echo "idevice $VERSION is ready in Vendor/IDevice.xcframework."
