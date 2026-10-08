#!/bin/bash
#
# One-line installer for iOS GPS Spoofer. Paste this into Terminal:
#
#   curl -fsSL https://raw.githubusercontent.com/renyifan2009-hash/iOS-GPS-Spoofer-V1.1.1/main/install.sh | bash
#
# It downloads the newest version of the app's source code, then setup.sh
# builds the app on this Mac and puts "iOS GPS Spoofer" in your Applications
# folder. Run it again any time to update. To pass options to setup.sh:
#
#   curl -fsSL …/install.sh | bash -s -- --uninstall
#
# Optional environment: SPOOFER_REPO (GitHub "owner/name"), SPOOFER_REF
# (branch, tag or commit to install; default: main).

# Everything runs inside main(), so a half-downloaded script does nothing.
main() {
  set -euo pipefail
  local repo="${SPOOFER_REPO:-renyifan2009-hash/iOS-GPS-Spoofer-V1.1.1}"
  local ref="${SPOOFER_REF:-main}"
  local sha

  echo "iOS GPS Spoofer: downloading the newest version…"

  # Building needs Apple's Command Line Tools, so check before downloading.
  if ! xcode-select -p >/dev/null 2>&1; then
    xcode-select --install >/dev/null 2>&1 || true
    echo
    echo "Apple's Command Line Tools are needed to build the app."
    echo "A window should have opened asking to install them. Click Install."
    echo "When it finishes (usually 5-15 minutes), paste the same command again."
    exit 1
  fi

  # Global, not local: the EXIT trap runs after main() has returned.
  SPOOFER_WORK="$(mktemp -d "${TMPDIR:-/tmp}/ios-gps-spoofer.XXXXXX")"
  trap 'rm -rf "$SPOOFER_WORK"' EXIT

  # Pin the exact commit, so the app knows which version it is.
  sha="$(curl -fsSL --max-time 20 -H 'Accept: application/vnd.github.sha' \
         "https://api.github.com/repos/$repo/commits/$ref" 2>/dev/null || true)"
  case "$sha" in '' | *[!0-9a-f]*) sha="" ;; esac

  if ! curl -fsSL --retry 3 "https://codeload.github.com/$repo/tar.gz/${sha:-$ref}" \
       | tar -xzf - -C "$SPOOFER_WORK" --strip-components 1; then
    echo "Couldn't download the app's source code. Check your internet connection and try again." >&2
    exit 1
  fi

  SPOOFER_COMMIT="$sha" SPOOFER_REPO="$repo" /bin/bash "$SPOOFER_WORK/setup.sh" "$@" </dev/null
}

main "$@"
