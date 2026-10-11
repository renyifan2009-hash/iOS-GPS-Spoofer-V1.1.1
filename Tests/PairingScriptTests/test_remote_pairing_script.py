"""Tests for the Remote Pairing export embedded in RemotePairingScript.swift.

The script is extracted straight from the Swift source, so these run without a
Swift toolchain:

    python3 -m pip install pymobiledevice3
    python3 Tests/PairingScriptTests/test_remote_pairing_script.py

Most tests run it against the stand-in library in Tests/Fixtures/fake-site.
The last group checks the real pymobiledevice3 still has what the script uses,
and drives its real pairing flow with only the conversation with the iPhone
replaced, so upstream changes show up here. Those are skipped when
pymobiledevice3 isn't installed.
"""

import asyncio
import base64
import importlib.util
import inspect
import os
import plistlib
import subprocess
import sys
import tempfile
import unittest

REPO = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
SWIFT_SOURCE = os.path.join(REPO, "Sources", "SpooferCore", "RemotePairingScript.swift")
FAKE_SITE = os.path.join(REPO, "Tests", "Fixtures", "fake-site")
PREFIX = "@@pairing "
UDID = "00008110-000DEMO0000DEMO"


def extract_script():
    with open(SWIFT_SOURCE, encoding="utf-8") as handle:
        source = handle.read()
    start = source.index('#"""\n') + len('#"""\n')
    end = source.index('\n"""#', start)
    return source[start:end]


SCRIPT = extract_script()
WORKDIR = tempfile.mkdtemp(prefix="pairing-script-test-")
SCRIPT_PATH = os.path.join(WORKDIR, "remote_pairing.py")
with open(SCRIPT_PATH, "w", encoding="utf-8") as _handle:
    _handle.write(SCRIPT)


def load_script():
    spec = importlib.util.spec_from_file_location("remote_pairing_under_test", SCRIPT_PATH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def have_pymobiledevice3():
    try:
        import pymobiledevice3.remote.tunnel_service  # noqa: F401
        return True
    except Exception:
        return False


def have_cryptography():
    try:
        import cryptography  # noqa: F401
        return True
    except Exception:
        return False


def run_with_fake(mode="paired", udid=UDID, **environment):
    """Run the script the way the Mac app does (`python -c <script> <udid>`), against the stand-in library."""
    env = dict(os.environ, PYTHONPATH=FAKE_SITE, PYTHONDONTWRITEBYTECODE="1", FAKE_PMD_RP=mode, **environment)
    args = [sys.executable, "-c", SCRIPT] + ([udid] if udid is not None else [])
    result = subprocess.run(args, capture_output=True, text=True, env=env, timeout=120)
    lines = [line[len(PREFIX):] for line in result.stdout.splitlines() if line.startswith(PREFIX)]
    return result, lines


def identity_of(lines):
    kind, _, payload = lines[-1].partition(" ")
    assert kind == "IDENTITY", lines
    return plistlib.loads(base64.b64decode(payload))


class FakeLibraryTests(unittest.TestCase):
    def test_already_paired(self):
        result, lines = run_with_fake("paired")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(lines), 1)
        identity = identity_of(lines)
        self.assertEqual(identity["public_key"], bytes(range(32)))
        self.assertEqual(identity["private_key"], bytes(range(100, 132)))
        self.assertEqual(identity["identifier"], "F3B1A0C2-FA4E-3000-8000-00000000FA4E")
        self.assertEqual(identity["alt_irk"], bytes(range(200, 216)))
        self.assertEqual(set(identity), {"public_key", "private_key", "identifier", "alt_irk"})

    def test_uses_the_cable_and_starts_no_lockdown_pairing(self):
        log = os.path.join(WORKDIR, "calls-paired.log")
        result, _ = run_with_fake("paired", FAKE_PMD_LOG=log)
        self.assertEqual(result.returncode, 0, result.stderr)
        with open(log) as handle:
            calls = handle.read().splitlines()
        self.assertIn("lib create_using_usbmux serial=%s connection_type=USB autopair=False" % UDID, calls)
        self.assertEqual(calls.count("lib service.close"), 1)
        self.assertEqual(calls[-1], "lib lockdown.close")

    def test_a_new_pairing_is_verified_with_a_second_connect(self):
        log = os.path.join(WORKDIR, "calls-fresh.log")
        result, lines = run_with_fake("fresh", FAKE_PMD_LOG=log)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(identity_of(lines)["private_key"], bytes(range(100, 132)))
        with open(log) as handle:
            calls = handle.read().splitlines()
        self.assertEqual([call for call in calls if call.startswith("lib connect")],
                         ["lib connect #1 autopair=True", "lib connect #2 autopair=True"])
        # Each service is closed, and the lockdown connection after them.
        self.assertEqual(calls.count("lib service.close"), 2)
        self.assertEqual(calls[-1], "lib lockdown.close")

    def test_a_pairing_that_never_sticks(self):
        result, lines = run_with_fake("never")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(lines, ["ERROR the iPhone paired but then didn't accept the pairing. Try again."])

    def test_locked(self):
        result, lines = run_with_fake("locked")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(lines, ["ERROR the iPhone is locked. Unlock it and try again."])

    def test_no_iphone_on_usb(self):
        result, lines = run_with_fake(FAKE_PMD_NO_DEVICE="1")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(lines, ["ERROR the iPhone isn't connected with a cable. Plug it in and try again."])

    def test_a_pymobiledevice3_without_remote_pairing(self):
        result, lines = run_with_fake("missing")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(len(lines), 1)
        self.assertTrue(lines[0].startswith("ERROR pymobiledevice3's Remote Pairing isn't available (ImportError"),
                        lines)
        self.assertIn("Update pymobiledevice3", lines[0])

    def test_no_pymobiledevice3_at_all(self):
        empty = os.path.join(WORKDIR, "empty-site")
        os.makedirs(empty, exist_ok=True)
        # -S -E: no site-packages and no PYTHONPATH, so nothing named pymobiledevice3 can be found.
        result = subprocess.run([sys.executable, "-S", "-E", "-c", SCRIPT, UDID], capture_output=True, text=True,
                                cwd=empty, timeout=120)
        self.assertEqual(result.returncode, 1)
        self.assertIn(PREFIX + "ERROR pymobiledevice3's Remote Pairing isn't available (ModuleNotFoundError",
                      result.stdout)

    def test_usage(self):
        result, lines = run_with_fake(udid=None)
        self.assertEqual(result.returncode, 2)
        self.assertEqual(lines, ["ERROR usage: <udid>"])

    @unittest.skipUnless(have_cryptography(), "needs the cryptography package (pymobiledevice3 brings it)")
    def test_a_record_with_only_the_private_key_gets_its_public_key(self):
        from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

        result, lines = run_with_fake("bare")
        self.assertEqual(result.returncode, 0, result.stderr)
        identity = identity_of(lines)
        private_key = Ed25519PrivateKey.from_private_bytes(identity["private_key"])
        signature = private_key.sign(b"check")
        from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey

        Ed25519PublicKey.from_public_bytes(identity["public_key"]).verify(signature, b"check")
        self.assertNotIn("alt_irk", identity)

    def test_every_reason_is_one_line(self):
        script = load_script()

        class Odd(Exception):
            pass

        self.assertEqual(script.describe(Odd("first line\nsecond line")), "Odd: first line")
        self.assertEqual(script.describe(Odd()), "Odd")
        self.assertIn("didn't answer in time", script.describe(asyncio.TimeoutError()))


@unittest.skipUnless(have_pymobiledevice3(), "pymobiledevice3 is not installed")
class InstalledPymobiledevice3Tests(unittest.TestCase):
    """The real library still has what the script uses."""

    def test_the_names_the_script_imports(self):
        from pymobiledevice3.exceptions import RemotePairingCompletedError  # noqa: F401
        from pymobiledevice3.lockdown import create_using_usbmux
        from pymobiledevice3.remote.tunnel_service import RemotePairingLockdownService

        parameters = inspect.signature(create_using_usbmux).parameters
        for name in ("serial", "connection_type", "autopair"):
            self.assertIn(name, parameters)
        self.assertIn("autopair", inspect.signature(RemotePairingLockdownService.connect).parameters)
        self.assertTrue(inspect.iscoroutinefunction(RemotePairingLockdownService.create))
        self.assertTrue(isinstance(inspect.getattr_static(RemotePairingLockdownService, "pair_record"), property))
        self.assertTrue(callable(RemotePairingLockdownService.close))

    def test_the_error_names_the_script_knows(self):
        import pymobiledevice3.exceptions as exceptions

        for name in ("NoDeviceConnectedError", "PasswordRequiredError", "NotPairedError", "InvalidServiceError"):
            self.assertTrue(hasattr(exceptions, name), name)

    def test_the_real_pairing_flow(self):
        """pymobiledevice3's own connect() and pair record, with the iPhone's side replaced.

        The steps of connect() are private, so this is skipped rather than
        failed if pymobiledevice3 renames them.
        """
        import pathlib

        import pymobiledevice3.lockdown as lockdown_module
        import pymobiledevice3.remote.tunnel_service as tunnel_service

        real = tunnel_service.RemotePairingLockdownService
        for private in ("_attempt_pair_verify", "_validate_pairing", "_pair", "save_pair_record",
                        "pair_record_path"):
            if not hasattr(real, private):
                self.skipTest("pymobiledevice3 no longer has RemotePairingProtocol.%s" % private)

        # pymobiledevice3 keeps its records under the home folder: keep this one out of it.
        record_path = pathlib.Path(tempfile.mkdtemp(prefix="pairing-records-")) / ("remote_%s.plist" % UDID)
        accepted = []  # private keys the pretend iPhone has on file

        class FakeConnection:
            reader = writer = None

            async def close(self):
                pass

        class FakeLockdown:
            udid = UDID

            async def start_lockdown_service(self, name):
                assert name == "com.apple.dt.remotepairingdeviced.lockdown", name
                return FakeConnection()

            async def close(self):
                pass

        class Service(real):
            pair_record_path = record_path

            async def _attempt_pair_verify(self):
                self.handshake_info = {"peerDeviceInfo": {"identifier": UDID, "model": "iPhone15,3"}}

            async def _validate_pairing(self):
                record = self.pair_record
                return record is not None and record["private_key"] in accepted

            async def _pair(self):
                self.remote_unlock_host_key = ""
                self.save_pair_record()
                accepted.append(self.pair_record["private_key"])

            def _init_client_server_main_encryption_keys(self):
                pass

        async def fake_create_using_usbmux(serial=None, connection_type=None, autopair=True, **kwargs):
            assert connection_type == "USB" and autopair is False
            return FakeLockdown()

        script = load_script()
        saved = (tunnel_service.RemotePairingLockdownService, lockdown_module.create_using_usbmux)
        tunnel_service.RemotePairingLockdownService = Service
        lockdown_module.create_using_usbmux = fake_create_using_usbmux
        try:
            first = asyncio.run(script.identity(UDID))
            second = asyncio.run(script.identity(UDID))
        finally:
            tunnel_service.RemotePairingLockdownService, lockdown_module.create_using_usbmux = saved

        # New to the iPhone the first time: paired once, then verified.
        self.assertEqual(len(accepted), 1)
        self.assertTrue(record_path.exists())
        self.assertEqual(first["private_key"], accepted[0])
        self.assertEqual(len(first["private_key"]), 32)
        self.assertEqual(len(first["public_key"]), 32)
        self.assertTrue(first["identifier"])
        # The second export reuses the record: same identity, no new pairing.
        self.assertEqual(second, first)


if __name__ == "__main__":
    unittest.main(verbosity=2)
