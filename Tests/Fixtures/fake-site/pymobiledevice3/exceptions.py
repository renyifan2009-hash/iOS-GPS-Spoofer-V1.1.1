class PyMobileDevice3Exception(Exception):
    pass


class RemotePairingCompletedError(PyMobileDevice3Exception):
    pass


class NoDeviceConnectedError(PyMobileDevice3Exception):
    pass


class PasswordRequiredError(PyMobileDevice3Exception):
    pass
