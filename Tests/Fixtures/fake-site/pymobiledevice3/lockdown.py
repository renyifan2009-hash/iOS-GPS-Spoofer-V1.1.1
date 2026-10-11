import os

from pymobiledevice3 import log
from pymobiledevice3.exceptions import NoDeviceConnectedError


class FakeLockdown:
    def __init__(self, udid):
        self.udid = udid

    async def close(self):
        log("lib lockdown.close")


async def create_using_usbmux(serial=None, connection_type=None, autopair=True, **kwargs):
    log("lib create_using_usbmux serial=%s connection_type=%s autopair=%s" % (serial, connection_type, autopair))
    if os.environ.get("FAKE_PMD_NO_DEVICE") == "1":
        raise NoDeviceConnectedError()
    return FakeLockdown(serial)
