#!/usr/bin/env python3
"""Drive the real Mac app (a debug build) over its remote API, the way the AnyWhere iPhone app does, against
the pretend iPhone (Tests/Fixtures/fake-pymobiledevice3). What the phone "received" is read from the fake's log.

    swift build && scripts/test-remote-bridge.py

It uses a temporary HOME and its own data folder, so it touches nothing of yours. Exit status 0 = all passed.
It needs python3 and a free port 47653 (turn off Settings > iPhone Remote in a running AnyWhere first).
"""
import json
import os
import re
import signal
import subprocess
import sys
import tempfile
import threading
import time
import urllib.error
import urllib.request

REPO = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
EXE = os.path.join(REPO, ".build", "debug", "iosgpsspoofer-gui")
FAKE = os.path.join(REPO, "Tests", "Fixtures", "fake-pymobiledevice3")
BASE = "http://127.0.0.1:47653"

failures = []


def check(ok, what):
    print(("  ok    " if ok else "  FAIL  ") + what)
    if not ok:
        failures.append(what)


def call(method, path, body=None, token=None):
    data = None if body is None else json.dumps(body).encode()
    req = urllib.request.Request(BASE + path, data=data, method=method)
    if token:
        req.add_header("Authorization", "Bearer " + token)
    if data is not None:
        req.add_header("Content-Type", "application/json")
    try:
        with urllib.request.urlopen(req, timeout=10) as resp:
            raw = resp.read()
            return resp.status, (json.loads(raw) if raw else None)
    except urllib.error.HTTPError as e:
        raw = e.read()
        try:
            return e.code, json.loads(raw)
        except Exception:
            return e.code, None


def wait_for(condition, timeout=15.0, step=0.2):
    end = time.time() + timeout
    while time.time() < end:
        value = condition()
        if value:
            return value
        time.sleep(step)
    return None


class MacApp:
    """A debug build of the Mac app with the remote server on, a temporary HOME and the pretend iPhone."""

    def __init__(self, *extra_args):
        self.home = tempfile.mkdtemp(prefix="anywhere-bridge-")
        self.log = os.path.join(self.home, "fake.log")
        env = dict(os.environ, HOME=self.home, SPOOFER_APP_DIR=os.path.join(self.home, "apps"), PYMOBILEDEVICE3=FAKE,
                   FAKE_PMD_LOG=self.log, SPOOFER_SNAPSHOT="1", SPOOFER_PRINT_PAIRING="1")
        self.proc = subprocess.Popen([EXE, "-remoteControlEnabled", "YES", *extra_args], env=env,
                                     stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True)
        self.code = {}
        threading.Thread(target=self._read_output, daemon=True).start()

    def _read_output(self):
        for line in self.proc.stdout:
            m = re.match(r"PAIRING-CODE (\d{6})", line)
            if m:
                self.code["value"] = m.group(1)

    def sets(self):
        """Every location the phone was told to take, in order, as (lat, lon)."""
        out = []
        try:
            for line in open(self.log):
                if "simulate-location set" in line and " -- " in line:
                    parts = line.strip().split(" -- ")[-1].split()
                    if len(parts) == 2:
                        out.append((float(parts[0]), float(parts[1])))
        except FileNotFoundError:
            pass
        return out

    def cleared(self):
        try:
            return any("simulate-location clear" in line for line in open(self.log))
        except FileNotFoundError:
            return False

    def pair(self):
        if not wait_for(lambda: self.code.get("value"), 30):
            sys.exit("The app never printed a pairing code (is the port in use?).")
        status, paired = call("POST", "/pair", {"code": self.code["value"], "clientName": "Test", "clientID": "test-1"})
        check(status == 200 and paired and paired.get("token"), "pairing with the code works")
        return paired["token"]

    def quit(self):
        self.proc.send_signal(signal.SIGTERM)
        try:
            self.proc.wait(timeout=10)
        except subprocess.TimeoutExpired:
            self.proc.kill()


def status_of(token):
    return call("GET", "/status", None, token)[1] or {}


def hold(app, token, place=(37.3349, -122.0090)):
    if not wait_for(lambda: status_of(token).get("connected"), 20):
        sys.exit("The Mac never saw the pretend iPhone.")
    status, _ = call("POST", "/start", {"latitude": place[0], "longitude": place[1], "name": "Home"}, token)
    check(status == 200, "POST /start is accepted")
    return wait_for(lambda: (lambda s: s if s.get("phase") == "active" else None)(status_of(token)))


def check_waits_before_leaving(app, token, label):
    """A route whose first stop waits 4 s: it sits at the start, says so, then goes."""
    start = (37.3349, -122.0090)
    route = {"waypoints": [{"latitude": start[0], "longitude": start[1], "wait": 4},
                           {"latitude": 37.3349, "longitude": -122.0050}],
             "followRoads": False, "travelMode": "walking", "loopMode": "once", "speed": 5, "realistic": True,
             "name": "Friend's house"}
    status, _ = call("POST", "/route", route, token)
    check(status == 200, "%s: a route that waits before leaving is accepted (%s)" % (label, status))
    sent_at = time.time()
    first = len(app.sets())
    waiting = wait_for(lambda: (lambda s: s if (s.get("routeWait") or {}).get("reason") == "stop" else None)(status_of(token)), 10)
    wait_info = (waiting or {}).get("routeWait") or {}
    check(wait_info.get("stop") == 0, "%s: the Mac says it is waiting at the start (%s)" % (label, wait_info))
    left = wait_info.get("remaining")
    check(left is not None and 0 < left <= 4.01, "%s: with the time left (%s s)" % (label, left))
    time.sleep(2.0)
    during = app.sets()[first:]
    far = [p for p in during if abs(p[1] - start[1]) > 0.0001]
    check(not far, "%s: the phone stays at the start while it waits (%d of %d points moved)" % (label, len(far), len(during)))
    moved = wait_for(lambda: any(p[1] > start[1] + 0.0002 for p in app.sets()[first:]), 20, 0.1)
    went = time.time() - sent_at
    check(bool(moved), "%s: then it sets off east" % label)
    check(went >= 3.5, "%s: and not before the wait is over (%.1f s after sending)" % (label, went))
    st = status_of(token)
    check((st.get("routeWait") or {}).get("reason") != "stop", "%s: and the wait is no longer reported (%s)" % (label, st.get("routeWait")))


def main():
    if not os.path.exists(EXE):
        sys.exit("Build first: swift build")
    app = MacApp()
    sets, cleared = app.sets, app.cleared
    try:
        print("Starting the Mac app with the remote server on...")
        wait_for(lambda: app.code.get("value"), 30)
        status, info = call("GET", "/info")
        check(status == 200, "GET /info answers without a token")
        token = app.pair()

        print("Errors before anything is held:")
        status, _ = call("POST", "/joystick", {"heading": 90, "speed": 3}, token)
        check(status == 409, "the joystick needs a location first (409), got %s" % status)
        status, _ = call("POST", "/pause", {"paused": True}, token)
        check(status == 409, "pausing needs a route (409), got %s" % status)
        status, _ = call("POST", "/autostop", {"minutes": 5}, token)
        check(status == 409, "auto-stop needs a location first (409), got %s" % status)
        status, _ = call("POST", "/joystick", {"heading": 400, "speed": 3}, token)
        check(status == 400, "a heading of 400 is refused (400), got %s" % status)

        print("Hold a place:")
        if not wait_for(lambda: call("GET", "/status", None, token)[1].get("connected"), 20):
            sys.exit("The Mac never saw the pretend iPhone.")
        status, st = call("POST", "/start", {"latitude": 37.3349, "longitude": -122.0090, "name": "Apple Park"}, token)
        check(status == 200, "POST /start is accepted")
        active = wait_for(lambda: (lambda s: s if s.get("phase") == "active" else None)(call("GET", "/status", None, token)[1]))
        check(bool(active), "the session comes up")
        check(active and active.get("activity") == "hold", "the Mac says it is holding a place")

        print("Steer with the joystick:")
        before = len(sets())
        for _ in range(8):
            status, st = call("POST", "/joystick", {"heading": 90, "speed": 8}, token)
            time.sleep(0.4)
        check(status == 200, "POST /joystick is accepted")
        check(st.get("activity") == "joystick", "the Mac switches to the joystick (activity=%s)" % st.get("activity"))
        moved = sets()[before:]
        check(len(moved) >= 3, "the phone keeps getting new places while steered (%d)" % len(moved))
        if len(moved) >= 2:
            check(moved[-1][1] > moved[0][1], "east means the longitude grows")
            check(abs(moved[-1][0] - moved[0][0]) < 1e-5, "and the latitude stays")
        st = call("GET", "/status", None, token)[1]
        check((st.get("speed") or 0) > 0, "status reports a speed while steering (%s)" % st.get("speed"))
        # No request for 1.5 s and the Mac lets go; it then eases to a stop (about 2 s from a cycling pace).
        time.sleep(5.0)
        settled = len(sets())
        time.sleep(1.5)
        check(len(sets()) == settled, "it stops moving by itself when the iPhone goes quiet")

        print("Drive a route, pause and resume:")
        route = {"waypoints": [{"latitude": 37.3349, "longitude": -122.0090}, {"latitude": 37.3349, "longitude": -122.0050}],
                 "followRoads": False, "travelMode": "walking", "loopMode": "once", "speed": 5, "realistic": True}
        status, st = call("POST", "/route", route, token)
        check(status == 200, "POST /route is accepted (not 501) -> %s" % status)
        on_route = wait_for(lambda: (lambda s: s if s.get("activity") == "route" else None)(call("GET", "/status", None, token)[1]), 15)
        check(bool(on_route), "the route starts")
        time.sleep(2.0)
        st = call("GET", "/status", None, token)[1]
        p1 = st.get("routeProgress")
        check(p1 is not None and p1 > 0, "progress is reported (%s)" % p1)
        status, st = call("POST", "/pause", {"paused": True}, token)
        check(status == 200 and st.get("routePaused") is True, "pause is accepted")
        time.sleep(0.5)
        a = call("GET", "/status", None, token)[1].get("routeProgress")
        time.sleep(2.0)
        b = call("GET", "/status", None, token)[1].get("routeProgress")
        check(a is not None and b is not None and abs(a - b) < 0.003, "the route stands still while paused (%s -> %s)" % (a, b))
        status, st = call("POST", "/pause", {"paused": False}, token)
        check(status == 200 and st.get("routePaused") is False, "resume is accepted")
        time.sleep(2.5)
        c = call("GET", "/status", None, token)[1].get("routeProgress")
        check(c is not None and b is not None and c > b, "and it carries on (%s -> %s)" % (b, c))

        print("Wait before leaving (realistic trips on):")
        check_waits_before_leaving(app, token, "realistic on")

        print("Auto-stop:")
        status, st = call("POST", "/autostop", {"minutes": 5}, token)
        left = (st or {}).get("autoStopAt", 0) - time.time()
        check(status == 200 and 280 < left < 305, "armed for about 5 minutes (%.0f s)" % left)
        status, st = call("POST", "/autostop", {"minutes": 0}, token)
        check(status == 200 and (st or {}).get("autoStopAt") is None, "and turned off again")
        status, _ = call("POST", "/autostop", {"minutes": 99999}, token)
        check(status == 400, "a silly number of minutes is refused (400), got %s" % status)

        print("Stop:")
        status, st = call("POST", "/stop", None, token)
        check(status == 200, "POST /stop is accepted")
        check(bool(wait_for(cleared, 10)), "the real location goes back on the phone")
        st = wait_for(lambda: (lambda s: s if not s.get("spoofing") else None)(call("GET", "/status", None, token)[1]), 10)
        check(bool(st), "status says nothing is held any more")
    finally:
        app.quit()

    print("Wait before leaving with \"Drive like a real person\" off:")
    plain = MacApp("-realisticTrips", "NO")
    try:
        token = plain.pair()
        check(bool(hold(plain, token)), "the session comes up")
        check_waits_before_leaving(plain, token, "realistic off")
    finally:
        plain.quit()

    print()
    if failures:
        print("%d check(s) FAILED:" % len(failures))
        for f in failures:
            print("  -", f)
        sys.exit(1)
    print("All checks passed.")


if __name__ == "__main__":
    main()
