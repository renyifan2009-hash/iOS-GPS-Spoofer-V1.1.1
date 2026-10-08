"""Tests for the live-location helper embedded in LiveHelperScript.swift.

The helper is extracted straight from the Swift source, so these run without a
Swift toolchain:

    python3 -m pip install pymobiledevice3
    python3 Tests/LiveHelperTests/test_live_helper.py

Set LIVE_HELPER_PATH to test a dumped copy instead (`iosgpsspoof dump-helper`).
The end-to-end tests drive pymobiledevice3's real CLI command with only the
device connection mocked out, so they also catch upstream API drift.
"""

import asyncio
import contextlib
import importlib.util
import io
import os
import subprocess
import sys
import tempfile
import textwrap
import threading
import time
import unittest

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
SWIFT_SOURCE = os.path.join(REPO, "Sources", "SpooferCore", "LiveHelperScript.swift")
PREFIX = "@@spoof "


def extract_script():
    override = os.environ.get("LIVE_HELPER_PATH")
    if override:
        with open(override, encoding="utf-8") as handle:
            return handle.read()
    with open(SWIFT_SOURCE, encoding="utf-8") as handle:
        source = handle.read()
    start = source.index('#"""\n') + len('#"""\n')
    end = source.index('\n"""#', start)
    return source[start:end]


WORKDIR = tempfile.mkdtemp(prefix="live-helper-test-")
HELPER_PATH = os.path.join(WORKDIR, "live_helper.py")
with open(HELPER_PATH, "w", encoding="utf-8") as _handle:
    _handle.write(extract_script())


def load_helper():
    spec = importlib.util.spec_from_file_location("live_helper_under_test", HELPER_PATH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def have_pymobiledevice3():
    try:
        import pymobiledevice3  # noqa: F401
        return True
    except Exception:
        return False


def protocol_lines(text):
    return [line[len(PREFIX):] for line in text.splitlines() if line.startswith(PREFIX)]


class Feeder:
    """A pipe whose read end the helper consumes, written from the test."""

    def __init__(self):
        read_fd, self.write_fd = os.pipe()
        self.stream = os.fdopen(read_fd, "r")

    def send(self, *lines, close=False, delay=0.0):
        def run():
            if delay:
                time.sleep(delay)
            for line in lines:
                os.write(self.write_fd, (line + "\n").encode())
                time.sleep(0.02)
            if close:
                os.close(self.write_fd)

        threading.Thread(target=run, daemon=True).start()


class ParseCommandTests(unittest.TestCase):
    def setUp(self):
        self.helper = load_helper()

    def test_set(self):
        self.assertEqual(self.helper.parse_command("set 48.8584 2.2945\n"), ("set", 48.8584, 2.2945))
        self.assertEqual(self.helper.parse_command("SET -33.5 151\n"), ("set", -33.5, 151.0))

    def test_set_rejects_bad_input(self):
        for raw in ("set 1", "set a b", "set 91 0", "set 0 181", "set nan 0", "set inf 0"):
            self.assertEqual(self.helper.parse_command(raw)[0], "error", raw)

    def test_other_commands(self):
        self.assertEqual(self.helper.parse_command("clear"), ("clear",))
        self.assertEqual(self.helper.parse_command("ping"), ("ping",))
        self.assertEqual(self.helper.parse_command("quit"), ("quit", False))
        self.assertEqual(self.helper.parse_command("quit clear"), ("quit", True))
        self.assertIsNone(self.helper.parse_command("   \n"))
        self.assertEqual(self.helper.parse_command("dance")[0], "error")

    def test_superseded(self):
        h = self.helper
        items = ["set 1 1\n", "set 2 2\n", "ping\n", "set 3 3\n", h.EOF]
        self.assertTrue(h.superseded(items, 0))
        self.assertFalse(h.superseded(items, 1))
        self.assertFalse(h.superseded(items, 3))


class ProtocolLoopTests(unittest.TestCase):
    """The patched `set` against fake services (no pymobiledevice3 needed)."""

    def setUp(self):
        self.helper = load_helper()

    def run_async_service(self, lines, close=True):
        calls = []

        class FakeAsyncService:
            async def set(self, latitude, longitude):
                calls.append(("set", latitude, longitude))

            async def clear(self):
                calls.append(("clear",))

        feeder = Feeder()
        FakeAsyncService.set = self.helper.make_live_set(FakeAsyncService.set, feeder.stream)
        feeder.send(*lines, close=close, delay=0.05)
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            asyncio.run(asyncio.wait_for(FakeAsyncService().set(10.0, 20.0), timeout=10))
        return calls, protocol_lines(out.getvalue())

    def run_sync_service(self, lines, close=True):
        calls = []

        class FakeSyncService:
            def set(self, latitude, longitude):
                calls.append(("set", latitude, longitude))

            def clear(self):
                calls.append(("clear",))

        feeder = Feeder()
        FakeSyncService.set = self.helper.make_live_set(FakeSyncService.set, feeder.stream)
        feeder.send(*lines, close=close, delay=0.05)
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            FakeSyncService().set(10.0, 20.0)
        return calls, protocol_lines(out.getvalue())

    def check_session(self, runner):
        calls, replies = runner(["set 1.5 2.5", "ping", "clear", "set 3 4", "bogus", "quit clear"], close=False)
        self.assertEqual(
            calls,
            [("set", 10.0, 20.0), ("set", 1.5, 2.5), ("clear",), ("set", 3.0, 4.0), ("clear",)],
        )
        self.assertEqual(replies[0], "READY 10.0 20.0")
        self.assertIn("OK 1.5 2.5", replies)
        self.assertIn("PONG", replies)
        self.assertIn("OK 3.0 4.0", replies)
        self.assertTrue(any(r.startswith("ERROR unknown command") for r in replies))
        self.assertEqual(replies[-2:], ["CLEARED", "BYE"])

    def test_async_session(self):
        self.check_session(self.run_async_service)

    def test_sync_session(self):
        self.check_session(self.run_sync_service)

    def test_eof_clears_location(self):
        for runner in (self.run_async_service, self.run_sync_service):
            self.helper.STATE.engaged = False
            calls, replies = runner(["set 5 6"], close=True)
            self.assertEqual(calls[-1], ("clear",))
            self.assertEqual(replies[-1], "CLEARED")

    def test_quit_without_clear(self):
        calls, replies = self.run_async_service(["quit"], close=False)
        self.assertEqual(calls, [("set", 10.0, 20.0)])
        self.assertEqual(replies, ["READY 10.0 20.0", "BYE"])


@unittest.skipUnless(have_pymobiledevice3(), "pymobiledevice3 is not installed")
class InstalledPymobiledevice3Tests(unittest.TestCase):
    def test_patch_targets_exist(self):
        helper = load_helper()
        classes = helper.find_service_classes()
        names = sorted(cls.__name__ for cls in classes)
        self.assertEqual(names, ["DtSimulateLocation", "LocationSimulation"])

    def test_probe(self):
        result = subprocess.run(
            [sys.executable, "-u", HELPER_PATH, "--probe"], capture_output=True, text=True, timeout=120
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        replies = protocol_lines(result.stdout)
        self.assertEqual(len(replies), 1, result.stdout)
        kind, version, protocol = replies[0].split()
        self.assertEqual(kind, "PROBE")
        self.assertRegex(version, r"^\d+\.")
        self.assertEqual(protocol, "1")


HARNESS = textwrap.dedent(
    """
    import sys
    sys.path.insert(0, {workdir!r})
    import pymobiledevice3.__main__  # noqa: F401  (load the CLI before patching it)
    import pymobiledevice3.cli.cli_common as cli_common
    from pymobiledevice3.services.dvt.instruments.location_simulation import LocationSimulation
    from pymobiledevice3.services.simulate_location import DtSimulateLocation
    import live_helper

    def log(*parts):
        sys.stderr.write("FAKE " + " ".join(str(p) for p in parts) + "\\n")
        sys.stderr.flush()

    class FakeLockdown:
        udid = "FAKE-UDID"
        identifier = "FAKE-UDID"
        product_version = "18.0"

    async def fake_create_using_usbmux(*args, **kwargs):
        log("connect", kwargs.get("serial"))
        return FakeLockdown()

    cli_common.create_using_usbmux = fake_create_using_usbmux

    class FakeProvider:
        def __init__(self, *args, **kwargs):
            pass

        async def __aenter__(self):
            return self

        async def __aexit__(self, *exc):
            return False

    import pymobiledevice3.cli.developer.dvt.simulate_location as dvt_cli
    dvt_cli.DvtProvider = FakeProvider

    async def enter(self):
        return self

    async def leave(self, *exc):
        log("closed")
        return False

    LocationSimulation.__init__ = lambda self, dvt: None
    LocationSimulation.__aenter__ = enter
    LocationSimulation.__aexit__ = leave

    async def fake_set(self, latitude, longitude):
        log("set", latitude, longitude)

    async def fake_clear(self):
        log("clear")

    for cls in (LocationSimulation, DtSimulateLocation):
        cls.set = fake_set
        cls.clear = fake_clear
    DtSimulateLocation.__init__ = lambda self, lockdown: None

    sys.exit(live_helper.main(sys.argv[1:]))
    """
)


@unittest.skipUnless(have_pymobiledevice3(), "pymobiledevice3 is not installed")
class EndToEndCliTests(unittest.TestCase):
    """Real pymobiledevice3 CLI parsing + command flow, fake device."""

    @classmethod
    def setUpClass(cls):
        cls.harness = os.path.join(WORKDIR, "harness.py")
        with open(cls.harness, "w", encoding="utf-8") as handle:
            handle.write(HARNESS.format(workdir=WORKDIR))

    def run_cli(self, cli_args, commands, close_stdin):
        process = subprocess.Popen(
            [sys.executable, "-u", self.harness, "--"] + cli_args,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        replies = []
        errors = []
        ready = threading.Event()

        def pump_stdout():
            for line in process.stdout:
                if line.startswith(PREFIX):
                    replies.append(line[len(PREFIX):].strip())
                    if line[len(PREFIX):].startswith("READY"):
                        ready.set()

        def pump_stderr():
            for line in process.stderr:
                errors.append(line)

        readers = [threading.Thread(target=pump_stdout, daemon=True), threading.Thread(target=pump_stderr, daemon=True)]
        for reader in readers:
            reader.start()
        if not ready.wait(60):
            process.kill()
            process.wait()
            self.fail("helper never reported READY:\n" + "".join(errors))
        for command in commands:
            process.stdin.write(command + "\n")
            process.stdin.flush()
            time.sleep(0.05)
        if close_stdin:
            process.stdin.close()
        try:
            status = process.wait(timeout=30)
        except subprocess.TimeoutExpired:
            process.kill()
            process.wait()
            self.fail("helper did not exit; replies so far: %r\n%s" % (replies, "".join(errors)))
        for reader in readers:
            reader.join(5)
        for stream in (process.stdin, process.stdout, process.stderr):
            with contextlib.suppress(Exception):
                stream.close()
        stderr = "".join(errors)
        fake_calls = [line[5:] for line in stderr.splitlines() if line.startswith("FAKE ")]
        return status, replies, fake_calls, stderr

    def test_dvt_set_session(self):
        status, replies, calls, stderr = self.run_cli(
            ["developer", "dvt", "simulate-location", "set", "--udid", "FAKE-UDID", "--", "48.8584", "2.2945"],
            ["set 40.6892 -74.0445", "ping", "quit clear"],
            close_stdin=False,
        )
        self.assertEqual(status, 0, stderr)
        self.assertEqual(replies[0], "READY 48.8584 2.2945")
        self.assertIn("OK 40.6892 -74.0445", replies)
        self.assertIn("PONG", replies)
        self.assertEqual(replies[-3:], ["CLEARED", "BYE", "EXIT 0"])
        self.assertEqual(calls[0], "connect FAKE-UDID")
        self.assertEqual(calls[1:4], ["set 48.8584 2.2945", "set 40.6892 -74.0445", "clear"])

    def test_parent_death_clears(self):
        status, replies, calls, stderr = self.run_cli(
            ["developer", "dvt", "simulate-location", "set", "--udid", "FAKE-UDID", "--", "1", "2"],
            ["set 3 4"],
            close_stdin=True,
        )
        self.assertEqual(status, 0, stderr)
        self.assertEqual(replies[-2:], ["CLEARED", "EXIT 0"])
        self.assertIn("clear", calls)

    def test_legacy_set_session(self):
        status, replies, calls, stderr = self.run_cli(
            ["developer", "simulate-location", "set", "--udid", "FAKE-UDID", "--", "35.6595", "139.7005"],
            ["set 35.66 139.70", "quit clear"],
            close_stdin=False,
        )
        self.assertEqual(status, 0, stderr)
        self.assertEqual(replies[0], "READY 35.6595 139.7005")
        self.assertIn("OK 35.66 139.7", replies)
        self.assertEqual(replies[-3:], ["CLEARED", "BYE", "EXIT 0"])


class IncompatibleInstallTests(unittest.TestCase):
    def test_reports_incompatible(self):
        fake_root = tempfile.mkdtemp(prefix="fake-pmd-")
        package = os.path.join(fake_root, "pymobiledevice3")
        os.makedirs(package)
        with open(os.path.join(package, "__init__.py"), "w") as handle:
            handle.write("")
        with open(os.path.join(package, "__main__.py"), "w") as handle:
            handle.write("def main():\n    return 0\n")
        env = dict(os.environ, PYTHONPATH=fake_root)
        result = subprocess.run(
            [sys.executable, "-u", HELPER_PATH, "--probe"], capture_output=True, text=True, env=env, timeout=60
        )
        self.assertEqual(result.returncode, 86)
        self.assertTrue(protocol_lines(result.stdout)[0].startswith("INCOMPATIBLE"))


if __name__ == "__main__":
    unittest.main(verbosity=2)
