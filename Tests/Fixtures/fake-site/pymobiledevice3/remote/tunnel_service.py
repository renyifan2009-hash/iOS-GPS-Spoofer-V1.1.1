from pymobiledevice3 import log, mode
from pymobiledevice3.exceptions import PasswordRequiredError, RemotePairingCompletedError

if mode() == "missing":
    raise ImportError("cannot import name 'RemotePairingLockdownService' from 'pymobiledevice3.remote.tunnel_service'")

# The values aren't real keys. The test suites compare against these.
PUBLIC_KEY = bytes(range(32))
PRIVATE_KEY = bytes(range(100, 132))
PEER_ALT_IRK = bytes(range(200, 216))
IDENTIFIER = "F3B1A0C2-FA4E-3000-8000-00000000FA4E"

# What this Mac has on disk for the iPhone, across services (None: never paired).
_saved_record = None
_connects = 0


class RemotePairingLockdownService:
    SERVICE_NAME = "com.apple.dt.remotepairingdeviced.lockdown"

    def __init__(self, lockdown):
        self.identifier = IDENTIFIER
        self._lockdown = lockdown

    @classmethod
    async def create(cls, lockdown):
        log("lib RemotePairingLockdownService.create udid=%s" % lockdown.udid)
        return cls(lockdown)

    async def connect(self, autopair=True):
        global _saved_record, _connects
        _connects += 1
        log("lib connect #%d autopair=%s" % (_connects, autopair))
        kind = mode()
        if kind == "locked":
            raise PasswordRequiredError()
        if kind == "bare":
            _saved_record = {"private_key": PRIVATE_KEY, "remote_unlock_host_key": ""}
            return
        full = {"public_key": PUBLIC_KEY, "private_key": PRIVATE_KEY, "remote_unlock_host_key": "",
                "peer_alt_irk": PEER_ALT_IRK}
        if kind == "paired" or (kind == "fresh" and _saved_record is not None):
            _saved_record = full
            return
        # Pair-verify failed, so pair: save the record, then the iPhone closes the channel.
        _saved_record = full
        raise RemotePairingCompletedError()

    async def close(self):
        log("lib service.close")

    @property
    def pair_record(self):
        return _saved_record
