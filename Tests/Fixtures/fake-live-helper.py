"""A stand-in for the live helper (LiveHelperScript.swift), to test how
SpoofSession treats a helper that stalls, dies or complains, without a phone.

SpoofSession runs it as `python3 -u fake-live-helper.py -- developer dvt
simulate-location set --userspace --udid <udid> -- <lat> <lon>`, exactly as it
would run the real one, and talks the same protocol (see LiveHelperScript.swift).

Environment knobs:
  FAKE_HELPER_LOG=<file>   one line per event: "start <lat> <lon>", "set <lat> <lon>",
                           "ping", "clear", "quit", "eof"
  FAKE_HELPER_MODES=a,b,c  how each launch behaves: the first launch uses a, the second
                           b, and so on (the last one is used from then on). Default: ok.
      ok        opens the channel and answers everything, like the real one
      silent    opens the channel, then never answers anything (a dead tunnel)
      die       opens the channel, then exits with an error at once
      okdie     works like ok for half a second, then the channel drops (exit status 1)
      usage     refuses its command line the way a pymobiledevice3 that is too old does
      trust     says the person refused to trust this computer, and exits
"""
import os
import sys

PREFIX = "@@spoof "
args = sys.argv[1:]
if args and args[0] == "--":
    args = args[1:]
lat, lon = args[-2], args[-1]
log_path = os.environ.get("FAKE_HELPER_LOG")


def log(line):
    if log_path:
        with open(log_path, "a") as handle:
            handle.write(line + "\n")


def reply(*parts):
    sys.stdout.write(PREFIX + " ".join(str(p) for p in parts) + "\n")
    sys.stdout.flush()


launch = 0
if log_path and os.path.exists(log_path):
    with open(log_path) as handle:
        launch = sum(1 for line in handle if line.startswith("start "))
log("start %s %s" % (lat, lon))
modes = os.environ.get("FAKE_HELPER_MODES", "ok").split(",")
mode = modes[min(launch, len(modes) - 1)]

if mode == "usage":
    sys.stderr.write("Usage: pymobiledevice3 developer dvt simulate-location set [OPTIONS] LATITUDE LONGITUDE\n")
    sys.stderr.write("╭─ Error ──────────────────────────────────────────────╮\n")
    sys.stderr.write("│ No such option: --userspace                          │\n")
    sys.stderr.write("╰──────────────────────────────────────────────────────╯\n")
    sys.stderr.flush()
    reply("EXIT", 2)
    sys.exit(2)

if mode == "trust":
    sys.stderr.write("2026-10-12 01:02:03 fake-host pymobiledevice3[1] ERROR User refused to trust this computer\n")
    sys.stderr.flush()
    reply("EXIT", 1)
    sys.exit(1)

reply("READY", lat, lon)

if mode == "die":
    reply("ERROR", "ConnectionTerminatedError: Connection closed")
    sys.exit(1)

if mode == "okdie":
    # Works for half a second, then the channel drops.
    import threading
    threading.Timer(0.5, os._exit, [1]).start()

while True:
    raw = sys.stdin.readline()
    if not raw:
        log("eof")
        reply("CLEARED")
        sys.exit(0)
    parts = raw.split()
    if not parts:
        continue
    if mode == "silent":
        log("ignored " + raw.strip())
        continue
    name = parts[0]
    if name == "set":
        log("set %s %s" % (parts[1], parts[2]))
        reply("OK", parts[1], parts[2])
    elif name == "ping":
        log("ping")
        reply("PONG")
    elif name == "clear":
        log("clear")
        reply("CLEARED")
    elif name == "quit":
        log("quit")
        if len(parts) > 1 and parts[1] == "clear":
            reply("CLEARED")
        reply("BYE")
        sys.exit(0)
