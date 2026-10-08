#!/usr/bin/env bash
#
# iOS GPS Spoofer installer.
#
# Installs the iPhone helper the app needs (pymobiledevice3), builds the app
# from this folder and puts "iOS GPS Spoofer" in your Applications folder.
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
#                       ~/Library/Application Support/iOS GPS Spoofer/venv)
#   SPOOFER_COMMIT      the git commit being built (shown in Settings ▸ About)

set -euo pipefail
cd "$(dirname "$0")"
ROOT="$(pwd)"

APP_NAME="iOS GPS Spoofer"
BUNDLE_ID="com.iosgpsspoofer.gui"
SUPPORT_DIR="$HOME/Library/Application Support/$APP_NAME"
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
}

# The newest Python 3.9+ that can make virtual environments. Apple's own
# /usr/bin/python3 comes with the Command Line Tools, so there's always one.
pick_python() {
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

# Quit a running copy (it restores the iPhone's real location as it quits).
quit_running_app() {
  local pattern="/$APP_NAME.app/Contents/MacOS/$APP_NAME" i=0
  pgrep -f "$pattern" >/dev/null 2>&1 || return 0
  note "Closing the copy of the app that's running (your iPhone goes back to its real location)…"
  osascript -e "if application id \"$BUNDLE_ID\" is running then tell application id \"$BUNDLE_ID\" to quit" \
    >/dev/null 2>&1 || true
  while [ "$i" -lt 40 ] && pgrep -f "$pattern" >/dev/null 2>&1; do
    sleep 0.5
    i=$((i + 1))
  done
  pkill -TERM -f "$pattern" >/dev/null 2>&1 || true
  sleep 1
}

install_app() {
  local built app_dir other
  mkdir -p "$ROOT/build"
  built="$(scripts/make-app.sh "$BIN_DIR" "$ROOT/build" 2>>"$LOG" | tail -1)" \
    || fail "Couldn't put the app together."

  app_dir="${SPOOFER_APP_DIR:-}"
  if [ -z "$app_dir" ]; then
    if [ -w /Applications ]; then app_dir=/Applications; else app_dir="$HOME/Applications"; fi
  fi
  mkdir -p "$app_dir"
  DEST="$app_dir/$APP_NAME.app"

  quit_running_app
  rm -rf "$DEST"
  ditto "$built" "$DEST" || fail "Couldn't copy the app into $app_dir."
  # One copy only: remove one left in the other standard place by an older install.
  if [ -z "${SPOOFER_APP_DIR:-}" ]; then
    for other in "/Applications/$APP_NAME.app" "$HOME/Applications/$APP_NAME.app"; do
      if [ "$other" != "$DEST" ] && [ -d "$other" ]; then rm -rf "$other"; fi
    done
  fi
  # Let Spotlight and Launchpad find it straight away.
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister \
    -f "$DEST" >/dev/null 2>&1 || true
  ok "Installed $DEST"
}

uninstall() {
  local dir removed=0
  quit_running_app
  for dir in /Applications "$HOME/Applications" "${SPOOFER_APP_DIR:-/Applications}"; do
    if [ -d "$dir/$APP_NAME.app" ]; then
      rm -rf "$dir/$APP_NAME.app"
      ok "Removed $dir/$APP_NAME.app"
      removed=1
    fi
  done
  [ "$removed" = 1 ] || note "The app wasn't in Applications."
  rm -rf "$HELPER_DIR" "$SUPPORT_DIR/helpers"
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
  install_helper
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
