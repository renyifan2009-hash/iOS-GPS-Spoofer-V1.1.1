// The Python half of the pairing file export: it makes the Remote Pairing
// identity newer iOS versions need. Kept in its own file so the test suite
// (Tests/PairingScriptTests) can extract and exercise it without a Swift
// toolchain. The literal is raw (`#"""`) and its closing delimiter sits in
// column 0, so the script is embedded byte-for-byte.

import Foundation
import PhoneOnlyCore

enum RemotePairingScript {
    /// What each line the script prints for us starts with.
    static let prefix = "@@pairing "

    /// The identity the script printed, or the reason it gave for having none.
    static func parse(_ stdout: String) -> Result<PairingRecord.RemotePairingIdentity, SpoofError> {
        let lines = stdout.split(whereSeparator: \.isNewline)
            .filter { $0.hasPrefix(prefix) }
            .map { $0.dropFirst(prefix.count) }
        guard let line = lines.last else {
            return .failure(SpoofError("pymobiledevice3 gave no answer"))
        }
        if line.hasPrefix("ERROR ") {
            return .failure(SpoofError(String(line.dropFirst("ERROR ".count))))
        }
        guard line.hasPrefix("IDENTITY "),
              let plist = Data(base64Encoded: String(line.dropFirst("IDENTITY ".count))),
              let record = try? PairingRecord(data: plist),
              let identity = record.remotePairing else {
            return .failure(SpoofError("pymobiledevice3 gave an identity SpoofRemote can't use"))
        }
        return .success(identity)
    }

    static let script: String = #"""
# iosgpsspoof Remote Pairing export.
#
#   python -c <this script> <udid>
#
# Pairs this Mac with the iPhone's remotepairingd over the USB lockdown
# connection and prints the identity for SpoofRemote's pairing file. USB is
# already trusted, so the iPhone asks nothing. If this Mac paired before,
# pymobiledevice3's record is used again.
#
# One line on stdout, prefixed with "@@pairing ":
#
#   IDENTITY <base64 of a property list: public_key, private_key, identifier, alt_irk if known>
#   ERROR <the reason, in plain words>      (exit status 1)

import asyncio
import base64
import inspect
import plistlib
import sys

PREFIX = "@@pairing "
TIMEOUT = 45
KEY_LENGTH = 32


class Failure(Exception):
    """A reason to show the user as it is."""


def emit(line):
    print(PREFIX + line, flush=True)


def describe(error):
    name = type(error).__name__
    if name in ("NoDeviceConnectedError", "DeviceNotFoundError", "ConnectionFailedToUsbmuxdError"):
        return "the iPhone isn't connected with a cable. Plug it in and try again."
    if name == "PasswordRequiredError":
        return "the iPhone is locked. Unlock it and try again."
    if name in ("NotPairedError", "PairingError", "UserDeniedPairingError", "PairingDialogResponsePendingError"):
        return "the iPhone doesn't trust this Mac. Unplug it, plug it back in, tap Trust, then try again."
    if name in ("InvalidServiceError", "StartServiceError"):
        return ("the iPhone didn't start its Remote Pairing service. Check that Developer Mode is on "
                "(Settings > Privacy & Security), then try again.")
    if isinstance(error, asyncio.TimeoutError):
        return "the iPhone didn't answer in time. Unlock it, keep it plugged in and try again."
    text = str(error).strip().splitlines()
    return name + (": " + text[0] if text else "")


async def settle(value):
    """pymobiledevice3 made some calls async over time: take either kind."""
    return await value if inspect.isawaitable(value) else value


async def pair(udid):
    """Pair-verify with the iPhone, pairing first if it's new. Returns (record, identifier)."""
    try:
        from pymobiledevice3.exceptions import RemotePairingCompletedError
        from pymobiledevice3.lockdown import create_using_usbmux
        from pymobiledevice3.remote.tunnel_service import RemotePairingLockdownService
    except Exception as error:
        raise Failure("pymobiledevice3's Remote Pairing isn't available (%s). Update pymobiledevice3: run "
                      "./setup.sh again, or `pipx upgrade pymobiledevice3`." % describe(error))

    # USB only: there the pairing needs no Trust prompt, and newer iOS versions
    # don't answer lockdown over the network at all.
    lockdown = await settle(create_using_usbmux(serial=udid, connection_type="USB", autopair=False))
    try:
        for _ in range(2):
            service = await RemotePairingLockdownService.create(lockdown)
            try:
                await service.connect(autopair=True)
            except RemotePairingCompletedError:
                # Paired just now, and the iPhone closes the channel after
                # that. Go round once more: the next connect only verifies,
                # which shows the iPhone really kept the pairing.
                continue
            finally:
                await settle(service.close())
            record = service.pair_record or {}
            return record, record.get("host_identifier") or service.identifier
        raise Failure("the iPhone paired but then didn't accept the pairing. Try again.")
    finally:
        close = getattr(lockdown, "close", None)
        if close is not None:
            try:
                await settle(close())
            except Exception:
                pass


def public_key_of(private_key):
    from cryptography.hazmat.primitives import serialization
    from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey

    return Ed25519PrivateKey.from_private_bytes(private_key).public_key().public_bytes(
        serialization.Encoding.Raw, serialization.PublicFormat.Raw)


async def identity(udid):
    record, identifier = await pair(udid)
    private_key = record.get("private_key")
    if not isinstance(private_key, bytes) or len(private_key) != KEY_LENGTH:
        raise Failure("pymobiledevice3 kept no usable Remote Pairing record for the iPhone.")
    public_key = record.get("public_key")
    if not isinstance(public_key, bytes) or len(public_key) != KEY_LENGTH:
        public_key = public_key_of(private_key)
    if not identifier:
        raise Failure("pymobiledevice3 has no name for this Mac's Remote Pairing.")
    out = {"public_key": public_key, "private_key": private_key, "identifier": str(identifier)}
    alt_irk = record.get("peer_alt_irk")
    if isinstance(alt_irk, bytes) and len(alt_irk) == 16:
        out["alt_irk"] = alt_irk
    return out


def main(argv):
    if len(argv) != 2:
        emit("ERROR usage: <udid>")
        return 2
    try:
        out = asyncio.run(asyncio.wait_for(identity(argv[1]), TIMEOUT))
    except Failure as failure:
        emit("ERROR " + str(failure))
        return 1
    except Exception as error:
        emit("ERROR " + describe(error))
        return 1
    emit("IDENTITY " + base64.b64encode(plistlib.dumps(out)).decode("ascii"))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
"""#
}
