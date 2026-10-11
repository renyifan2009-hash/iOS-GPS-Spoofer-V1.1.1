"""A stand-in for the parts of pymobiledevice3 the pairing file export imports.

The export's Python (Sources/SpooferCore/RemotePairingScript.swift) runs in
pymobiledevice3's own interpreter and imports it as a library. Put this folder
on PYTHONPATH and it meets this package instead, so the export can be tried
with no iPhone:

    PYTHONPATH=Tests/Fixtures/fake-site PYMOBILEDEVICE3=Tests/Fixtures/fake-pymobiledevice3 \
        .build/debug/iosgpsspoof export-pairing

FAKE_PMD_RP picks what the pretend iPhone does:
  paired     (default) this Mac paired before: the first connect verifies
  fresh      new to the iPhone: the first connect pairs, the second verifies
  never      the iPhone pairs every time and never accepts the result
  locked     the iPhone is locked
  bare       paired, with an old record that has only the private key
  missing    a pymobiledevice3 too old to have RemotePairingLockdownService
FAKE_PMD_NO_DEVICE=1 means no iPhone on USB, and FAKE_PMD_LOG=<file> records
the calls, as in fake-pymobiledevice3.
"""
import os


def log(line):
    if os.environ.get("FAKE_PMD_LOG"):
        with open(os.environ["FAKE_PMD_LOG"], "a") as handle:
            handle.write(line + "\n")


def mode():
    return os.environ.get("FAKE_PMD_RP", "paired")
