#!/usr/bin/env bash
#
# AnyWhere installer.
#
# Installs the iPhone helper the app needs (pymobiledevice3), builds the app
# from this folder and puts "AnyWhere" in your Applications folder.
# Run it again any time: that's also how you update.
#
#   ./setup.sh               install or update, then open the app
#   ./setup.sh --no-open     install or update without opening the app
#   ./setup.sh --uninstall   remove the app and its helper (keeps saved places)
#
# Advanced settings (environment variables):
#   SPOOFER_APP_DIR     install the app here (default: /Applications, or
#                       ~/Applications when /Applications isn't writable)
#   SPOOFER_HELPER_DIR  put the pymobiledevice3 helper here (default:
#                       ~/Library/Application Support/AnyWhere/venv)
#   SPOOFER_COMMIT      the git commit being built (shown in Settings ▸ About)
#   SPOOFER_PYTHON      use this Python 3.9+ for the helper (default: the newest one found)
#   SPOOFER_SKIP_SELF_TEST=1   install even if the freshly built app fails its start-up test

set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(pwd)"

APP_NAME="AnyWhere"
# The product was called "iOS GPS Spoofer" before. The bundle ID stayed the same on purpose
# (preferences and permissions are keyed by it); the names below are cleaned up on install.
LEGACY_APP_NAME="iOS GPS Spoofer"
BUNDLE_ID="com.iosgpsspoofer.gui"
SUPPORT_DIR="$HOME/Library/Application Support/$APP_NAME"
LEGACY_SUPPORT_DIR="$HOME/Library/Application Support/$LEGACY_APP_NAME"
HELPER_DIR="${SPOOFER_HELPER_DIR:-$SUPPORT_DIR/venv}"
LOG_DIR="$HOME/Library/Logs/$APP_NAME"
LOG="$LOG_DIR/install.log"

OPEN_APP=1
ACTION=install
for arg in "$@"; do
  case "$arg" in
    --no-open) OPEN_APP=0 ;;
    --uninstall) ACTION=uninstall ;;
    -h|--help) sed -n '3,19p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "Unknown option: $arg (try --help)" >&2; exit 2 ;;
  esac
done

SWIFT_VERSION=""
SDK_VERSION=""
BIN_DIR=""
DEST=""

# ---------------------------------------------------------------- output ---

if [ -t 1 ]; then
  BOLD=$'\033[1m'; DIM=$'\033[2m'; RED=$'\033[31m'; GREEN=$'\033[32m'; YELLOW=$'\033[33m'; RESET=$'\033[0m'
else
  BOLD=""; DIM=""; RED=""; GREEN=""; YELLOW=""; RESET=""
fi

STEP=0
STEPS=5
step() { STEP=$((STEP + 1)); printf '\n%s[%d/%d] %s%s\n' "$BOLD" "$STEP" "$STEPS" "$1" "$RESET"; }
ok()   { printf '  %s✓%s %s\n' "$GREEN" "$RESET" "$1"; }
note() { printf '  %s\n' "$1"; }
warn() { printf '  %s!%s %s\n' "$YELLOW" "$RESET" "$1"; }

# fail "headline" ["detail line" ...]: explain what went wrong and stop.
fail() {
  printf '\n%s✗ %s%s\n' "$RED" "$1" "$RESET" >&2
  shift
  local line
  for line in "$@"; do
    printf '%s\n' "$line" | sed 's/^/  /' >&2
  done
  printf '\n  %sFull log: %s%s\n' "$DIM" "$LOG" "$RESET" >&2
  exit 1
}

# run_logged "what it's doing" command [args...]: run a slow command with its
# output going to the log, showing a spinner and the time taken so far.
run_logged() {
  local label="$1"
  shift
  printf '\n$ %s\n' "$*" >>"$LOG"
  "$@" >>"$LOG" 2>&1 &
  local pid=$! start=$SECONDS i=0 spin='|/-\'
  if [ -t 1 ]; then
    while kill -0 "$pid" 2>/dev/null; do
      printf '\r  %s %s %s(%ds)%s ' "${spin:$((i % 4)):1}" "$label" "$DIM" $((SECONDS - start)) "$RESET"
      i=$((i + 1))
      sleep 0.25
    done
    printf '\r\033[K'
  else
    printf '  %s…\n' "$label"
  fi
  wait "$pid"
}

# ----------------------------------------------------------------- steps ---

check_mac() {
  local version arch major
  version="$(sw_vers -productVersion)"
  arch="$(uname -m)"
  major="${version%%.*}"
  if [ "$major" -lt 14 ]; then
    fail "This app needs macOS 14 Sonoma or newer. This Mac has macOS $version." \
         "Update macOS in System Settings ▸ General ▸ Software Update, then run this again."
  fi
  if [ "$arch" = arm64 ]; then ok "macOS $version, Apple silicon"; else ok "macOS $version, Intel"; fi
}

check_developer_tools() {
  local dev_dir out
  dev_dir="$(xcode-select -p 2>/dev/null || true)"
  if [ -z "$dev_dir" ]; then
    xcode-select --install >/dev/null 2>&1 || true
    fail "Apple's Command Line Tools are needed to build the app." \
         "A window should have opened asking to install them. Click Install." \
         "When it finishes (usually 5-15 minutes), run this same command again." \
         "No window? Run this, then try again:  xcode-select --install"
  fi
  if [ ! -d "$dev_dir" ]; then
    fail "This Mac points to developer tools that were deleted ($dev_dir)." \
         "Fix it with:  sudo xcode-select --reset   (it asks for your Mac password)" \
         "or install fresh tools with:  xcode-select --install" \
         "Then run this command again."
  fi
  if ! out="$(swift --version 2>&1)"; then
    case "$out" in
      *icense*)
        fail "Xcode's license hasn't been accepted yet." \
             "Run:  sudo xcodebuild -license accept   (it asks for your Mac password)" \
             "or open Xcode once and click Agree. Then run this command again." ;;
    esac
    fail "Swift doesn't run on this Mac. It said:" "$out" \
         "Reinstalling Apple's Command Line Tools usually fixes this:" \
         "  sudo rm -rf /Library/Developer/CommandLineTools && xcode-select --install"
  fi
  SWIFT_VERSION="$(printf '%s\n' "$out" | grep -o 'Swift version [0-9.]*' | head -1 | cut -d' ' -f3 || true)"
  SDK_VERSION="$(xcrun --show-sdk-version 2>/dev/null || echo unknown)"
  {
    echo "swift: $out"
    echo "sdk: $SDK_VERSION ($(xcrun --show-sdk-path 2>/dev/null || true))"
    echo "developer dir: $dev_dir"
  } >>"$LOG"
  ok "Swift ${SWIFT_VERSION:-(unknown version)} with the macOS $SDK_VERSION SDK"
  # A Swift from swift.org (installed with swiftly) next to an older macOS SDK is the setup that once
  # built an app that crashed at launch. The start-up test below catches it; this says why early.
  local swift_path
  swift_path="$(command -v swift 2>/dev/null || true)"
  case "$swift_path" in
    ""|/usr/bin/swift|/Applications/Xcode*|/Library/Developer/*) ;;
    *) warn "Building with the Swift at $swift_path (not Apple's). If the app crashes when it starts,"
       warn "download the ready-made app instead: https://github.com/${SPOOFER_REPO:-renyifan2009-hash/iOS-GPS-Spoofer-V1.2.3}/releases/latest" ;;
  esac
}

# The newest Python 3.9+ that can make virtual environments. Apple's own
# /usr/bin/python3 comes with the Command Line Tools, so there's always one.
pick_python() {
  # SPOOFER_PYTHON=/path/to/python3 picks one yourself (it still has to be 3.9 or newer).
  if [ -n "${SPOOFER_PYTHON:-}" ] && [ -x "$SPOOFER_PYTHON" ]; then
    echo "$SPOOFER_PYTHON"
    return 0
  fi
  local best="" best_minor=-1 python minor
  for python in /opt/homebrew/bin/python3 /usr/local/bin/python3 \
                /Library/Frameworks/Python.framework/Versions/Current/bin/python3 /usr/bin/python3; do
    [ -x "$python" ] || continue
    minor="$("$python" -c 'import sys, venv, ensurepip; print(sys.version_info[1] if sys.version_info[0] == 3 else -1)' 2>/dev/null || true)"
    case "$minor" in ''|*[!0-9]*) continue ;; esac
    [ "$minor" -ge 9 ] || continue
    if [ "$minor" -gt "$best_minor" ]; then
      best="$python"
      best_minor="$minor"
    fi
  done
  [ -n "$best" ] || return 1
  echo "$best"
}

install_helper() {
  export PYTHONWARNINGS=ignore   # e.g. urllib3's LibreSSL notice on Apple's Python 3.9
  local python="$HELPER_DIR/bin/python3" base pmd_version py_version
  if [ -x "$python" ] && "$python" -c 'import sys' >/dev/null 2>&1; then
    note "Found the helper from an earlier install. Updating it."
  else
    base="$(pick_python)" || fail "Python 3.9 or newer wasn't found on this Mac." \
      "It normally comes with Apple's Command Line Tools. Reinstall them with:  xcode-select --install" \
      "or install Python from https://www.python.org/downloads/macos/ , then run this again."
    rm -rf "$HELPER_DIR"
    mkdir -p "$(dirname "$HELPER_DIR")"
    if ! run_logged "Creating the helper's Python environment" "$base" -m venv "$HELPER_DIR"; then
      fail "Couldn't create a Python environment with $base." "$(tail -n 12 "$LOG")"
    fi
  fi

  if ! run_logged "Updating pip" \
       "$python" -m pip install --disable-pip-version-check --upgrade pip \
     || ! run_logged "Downloading pymobiledevice3 (about a minute)" \
       "$python" -m pip install --disable-pip-version-check --upgrade pymobiledevice3; then
    if ! curl -fsS --max-time 15 -o /dev/null https://pypi.org/simple/pymobiledevice3/ 2>/dev/null; then
      fail "Couldn't download pymobiledevice3, because this Mac can't reach pypi.org." \
           "Check your internet connection (or VPN / firewall), then run this command again."
    fi
    fail "Couldn't install pymobiledevice3. The end of the log says:" "$(tail -n 15 "$LOG")"
  fi

  pmd_version="$("$python" -m pymobiledevice3 version 2>>"$LOG" | tail -1 || true)"
  [ -n "$pmd_version" ] || fail "pymobiledevice3 was installed but doesn't start. The end of the log says:" \
                                "$(tail -n 15 "$LOG")"
  py_version="$("$python" -c 'import platform; print(platform.python_version())' 2>/dev/null || true)"
  ok "pymobiledevice3 $pmd_version (Python $py_version)"
}

build_app() {
  if ! run_logged "Building the app (1-5 minutes)" swift build -c release; then
    # A build cache left by another Swift version is the usual culprit.
    warn "The first try failed. Trying again from a clean slate…"
    rm -rf .build
    if ! run_logged "Building the app again (2-5 minutes)" swift build -c release; then
      local plain errors
      # The compiler's own lines ("Sources/…/File.swift:12:5: error: …"),
      # without colour codes and with short paths.
      plain="$(sed -E $'s/\x1b\\[[0-9;]*m//g' "$LOG")"
      errors="$(printf '%s\n' "$plain" | grep -E '\.swift:[0-9]+:[0-9]+: error:' \
                | sed -E 's#^.*/(Sources/|Tests/)#\1#' | sort -u | head -6 || true)"
      if [ -z "$errors" ]; then
        errors="$(printf '%s\n' "$plain" | grep -E '(^|: )error:' \
                  | grep -v -e 'Build failed' -e 'failed with a nonzero exit code' | sort -u | head -6 || true)"
      fi
      case "$errors" in
        *glassEffect*)
          fail "The build failed because this copy of the project is out of date." \
               "Download the project again (or use the one-line install command), then retry." ;;
      esac
      fail "The build failed." "${errors:-There are details in the log.}" \
           "Make sure you have the newest version of this project, then try again." \
           "Still stuck? Send the log file below to the developer."
    fi
  fi
  BIN_DIR="$(swift build -c release --show-bin-path 2>>"$LOG")"
  ok "Built with Swift ${SWIFT_VERSION:-(unknown version)}"
}

# Is a copy running, under this name or the old one?
app_running() {
  local name
  for name in "$APP_NAME" "$LEGACY_APP_NAME"; do
    pgrep -f "/$name.app/Contents/MacOS/$name" >/dev/null 2>&1 && return 0
  done
  return 1
}

# Quit a running copy (it restores the iPhone's real location as it quits).
quit_running_app() {
  local name i=0
  app_running || return 0
  note "Closing the copy of the app that's running (your iPhone goes back to its real location)…"
  # Both names share one bundle ID, so one request quits either.
  osascript -e "if application id \"$BUNDLE_ID\" is running then tell application id \"$BUNDLE_ID\" to quit" \
    >/dev/null 2>&1 || true
  while [ "$i" -lt 40 ] && app_running; do
    sleep 0.5
    i=$((i + 1))
  done
  for name in "$APP_NAME" "$LEGACY_APP_NAME"; do
    pkill -TERM -f "/$name.app/Contents/MacOS/$name" >/dev/null 2>&1 || true
  done
  sleep 1
}

# Saved places, routes and the remote's pairing live in Application Support. They moved from
# the old name's folder to this one: copy them over (never delete them) the first time.
# The Python environment is not copied: moved environments keep stale absolute paths, and
# install_helper builds a fresh one.
migrate_legacy_data() {
  [ -d "$LEGACY_SUPPORT_DIR" ] || return 0
  mkdir -p "$SUPPORT_DIR"
  local item name moved=0
  for item in "$LEGACY_SUPPORT_DIR"/* "$LEGACY_SUPPORT_DIR"/.[!.]*; do
    [ -e "$item" ] || continue
    name="$(basename "$item")"
    case "$name" in venv|helpers) continue ;; esac
    if [ ! -e "$SUPPORT_DIR/$name" ]; then
      cp -R "$item" "$SUPPORT_DIR/$name" && moved=$((moved + 1))
    fi
  done
  [ "$moved" -eq 0 ] || ok "Copied your saved places and routes from the old folder"
}

# Start the freshly built app in its self-test mode (no window shown, no focus taken) and check
# that it gets as far as running. An app built by Swift tools that don't match this Mac's SDK
# can compile fine and then crash the moment it starts; this catches that before the new copy
# replaces a working one.
self_test_app() {
  local app="$1" exe out pid status waited=0
  exe="$app/Contents/MacOS/$APP_NAME"
  if [ "${SPOOFER_SKIP_SELF_TEST:-0}" = 1 ]; then
    warn "Skipping the start-up test (SPOOFER_SKIP_SELF_TEST=1)."
    return 0
  fi
  # An app can't open without a desktop session (over SSH, say). That is not a crash, so say so and go on.
  local session
  session="$(launchctl managername 2>/dev/null || true)"
  if [ -n "$session" ] && [ "$session" != Aqua ]; then
    warn "This isn't a desktop session ($session), so the start-up test was skipped."
    return 0
  fi
  out="$(mktemp "${TMPDIR:-/tmp}/anywhere-selftest.XXXXXX")"
  ANYWHERE_SELF_TEST=1 ANYWHERE_SELF_TEST_SECONDS=5 "$exe" >"$out" 2>&1 </dev/null &
  pid=$!
  while kill -0 "$pid" 2>/dev/null; do
    if [ "$waited" -ge 120 ]; then
      kill -KILL "$pid" 2>/dev/null || true
      break
    fi
    sleep 1
    waited=$((waited + 1))
  done
  status=0
  wait "$pid" 2>/dev/null || status=$?
  { echo "--- start-up test (status $status, ${waited}s) ---"; cat "$out"; } >>"$LOG"
  if [ "$status" = 0 ] && grep -q '^SELF-TEST-OK' "$out"; then
    rm -f "$out"
    ok "The new app starts"
    return 0
  fi
  rm -f "$out"
  local repo="${SPOOFER_REPO:-renyifan2009-hash/iOS-GPS-Spoofer-V1.2.3}" headline
  if [ "$waited" -ge 120 ]; then
    headline="The app was built, but it didn't finish starting within 2 minutes. It was NOT installed."
  else
    headline="The app was built, but it crashes as soon as it starts. It was NOT installed."
  fi
  fail "$headline" \
       "Your current copy, if you have one, is untouched." \
       "This Mac builds with Swift ${SWIFT_VERSION:-?} and the macOS ${SDK_VERSION:-?} SDK, and that combination makes a broken app." \
       "Download the ready-made app instead (it is built and tested on GitHub):" \
       "  https://github.com/$repo/releases/latest" \
       "To install this build anyway, run the command again with SPOOFER_SKIP_SELF_TEST=1 in front of it."
}

# The login item that `iosgpsspoof serve --install-agent` makes holds the app's path. After the
# rename that path has the old name in it, so point it at the new one.
repair_login_item() {
  local label="com.iosgpsspoof.remote" plist="$HOME/Library/LaunchAgents/com.iosgpsspoof.remote.plist"
  [ -f "$plist" ] || return 0
  grep -qF "/$LEGACY_APP_NAME.app/" "$plist" 2>/dev/null || return 0
  if sed -i '' "s#/$LEGACY_APP_NAME\\.app/#/$APP_NAME.app/#g" "$plist" 2>>"$LOG"; then
    launchctl bootout "gui/$(id -u)/$label" >/dev/null 2>&1 || true
    if launchctl bootstrap "gui/$(id -u)" "$plist" >>"$LOG" 2>&1; then
      ok "Updated the iPhone Remote login item for the new name"
    else
      warn "Updated the login item's path, but couldn't restart it. It starts at your next login."
    fi
  fi
}

install_app() {
  local built app_dir other
  mkdir -p "$ROOT/build"
  built="$(scripts/make-app.sh "$BIN_DIR" "$ROOT/build" 2>>"$LOG" | tail -1)" \
    || fail "Couldn't put the app together."

  note "Checking that the new app starts…"
  self_test_app "$built"

  app_dir="${SPOOFER_APP_DIR:-}"
  if [ -z "$app_dir" ]; then
    if [ -w /Applications ]; then app_dir=/Applications; else app_dir="$HOME/Applications"; fi
  fi
  mkdir -p "$app_dir"
  DEST="$app_dir/$APP_NAME.app"

  # Copy beside the old app first, then swap, so a failed copy never leaves the Mac without one.
  local staging="$app_dir/.$APP_NAME.new.$$" backup="$app_dir/.$APP_NAME.old.$$"
  rm -rf "$staging" "$backup"
  if ! ditto "$built" "$staging"; then
    rm -rf "$staging"
    fail "Couldn't copy the app into $app_dir." "If that folder belongs to another user, ask an administrator, or set SPOOFER_APP_DIR to a folder you own."
  fi
  if ! codesign --verify --deep --strict "$staging" >>"$LOG" 2>&1; then
    rm -rf "$staging"
    fail "The copied app failed its signature check, so it was not installed."
  fi
  quit_running_app
  if [ -e "$DEST" ] && ! mv "$DEST" "$backup" 2>>"$LOG"; then
    rm -rf "$staging"
    fail "Couldn't replace the existing app at $DEST." "Close it, or ask an administrator if the folder isn't yours."
  fi
  if ! mv "$staging" "$DEST" 2>>"$LOG"; then
    # Under set -e a failing last command would stop here: put the old copy back if we can, then report.
    if [ -e "$backup" ]; then mv "$backup" "$DEST" 2>/dev/null || true; fi
    rm -rf "$staging"
    fail "Couldn't put the new app in place. The previous copy was put back."
  fi
  rm -rf "$backup"
  # One copy only: remove one left in the other standard place by an older install, and
  # any copy that still has the old name (it shares this app's bundle ID, so keeping it
  # makes macOS pick between the two when something opens "the app").
  if [ -z "${SPOOFER_APP_DIR:-}" ]; then
    for other in "/Applications/$APP_NAME.app" "$HOME/Applications/$APP_NAME.app"; do
      if [ "$other" != "$DEST" ] && [ -d "$other" ]; then
        rm -rf "$other" 2>>"$LOG" || warn "Couldn't remove the other copy at $other (it belongs to another user?)."
      fi
    done
  fi
  # With SPOOFER_APP_DIR set (CI, tests), only that folder is touched; otherwise the two
  # standard places are.
  local legacy_places=("$app_dir/$LEGACY_APP_NAME.app")
  if [ -z "${SPOOFER_APP_DIR:-}" ]; then
    legacy_places+=("/Applications/$LEGACY_APP_NAME.app" "$HOME/Applications/$LEGACY_APP_NAME.app")
  fi
  for other in "${legacy_places[@]}"; do
    if [ -d "$other" ]; then
      if rm -rf "$other" 2>>"$LOG"; then
        ok "Removed the old \"$LEGACY_APP_NAME\" app (this one replaces it)"
      else
        warn "Couldn't remove the old \"$LEGACY_APP_NAME\" app at $other. Move it to the Trash yourself."
      fi
    fi
  done
  # Let Spotlight and Launchpad find it straight away.
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "$DEST" >/dev/null 2>&1 || true
  ok "Installed $DEST"
  repair_login_item
}

uninstall() {
  local dir removed=0
  quit_running_app
  local name
  local dirs=("${SPOOFER_APP_DIR:-}")
  [ -n "${SPOOFER_APP_DIR:-}" ] || dirs=(/Applications "$HOME/Applications")
  for dir in "${dirs[@]}"; do
    for name in "$APP_NAME" "$LEGACY_APP_NAME"; do
      if [ -d "$dir/$name.app" ]; then
        rm -rf "$dir/$name.app"
        ok "Removed $dir/$name.app"
        removed=1
      fi
    done
  done
  [ "$removed" = 1 ] || note "The app wasn't in Applications."
  local agent="$HOME/Library/LaunchAgents/com.iosgpsspoof.remote.plist"
  if [ -f "$agent" ]; then
    launchctl bootout "gui/$(id -u)/com.iosgpsspoof.remote" >/dev/null 2>&1 || true
    rm -f "$agent"
    ok "Removed the iPhone Remote login item"
  fi
  rm -rf "$HELPER_DIR" "$SUPPORT_DIR/helpers" "$LEGACY_SUPPORT_DIR/venv" "$LEGACY_SUPPORT_DIR/helpers"
  ok "Removed the iPhone helper (pymobiledevice3)"
  note "Your favorites and saved routes are still in:"
  note "  $SUPPORT_DIR"
  note "Delete that folder too if you don't need them."
}

# ------------------------------------------------------------------ main ---

main() {
  mkdir -p "$LOG_DIR"
  {
    echo "=== $APP_NAME installer, $(date)"
    echo "folder: $ROOT"
    echo "version: $(cat VERSION 2>/dev/null || echo unknown) ${SPOOFER_COMMIT:-}"
    echo "macOS: $(sw_vers -productVersion) $(uname -m)"
  } >"$LOG"

  printf '%s%s installer%s\n' "$BOLD" "$APP_NAME" "$RESET"

  if [ "$ACTION" = uninstall ]; then
    uninstall
    exit 0
  fi

  step "Checking this Mac"
  check_mac
  step "Checking Apple's developer tools"
  check_developer_tools
  step "Installing the iPhone helper (pymobiledevice3)"
  migrate_legacy_data
  install_helper
  # The old name's Python environment is no longer used.
  rm -rf "$LEGACY_SUPPORT_DIR/venv" "$LEGACY_SUPPORT_DIR/helpers" 2>/dev/null || true
  step "Building the app"
  build_app
  step "Installing the app"
  install_app

  printf '\n%s✓ Done! %s is installed.%s\n\n' "$GREEN$BOLD" "$APP_NAME" "$RESET"
  note "Next:"
  note "  1. Plug your iPhone into this Mac with a USB cable and unlock it."
  note "  2. If the iPhone asks \"Trust This Computer?\", tap Trust."
  note "  3. Follow the checklist in the app. It tells you anything else to do."
  echo
  note "To update later, run this same command again."
  if [ "$OPEN_APP" = 1 ]; then
    note "Opening the app now…"
    open "$DEST" || true
  fi
}

main
