import Darwin
import Foundation
import IDevice

/// Changes this iPhone's location from the iPhone itself (iOS 17.4 and
/// later), the way a Mac does over USB: lockdown with the pairing file, the
/// CoreDevice tunnel, RSD, then DVT's location simulation channel. The
/// LocalDevVPN app routes the iPhone's own address back to it, which is how
/// an app can reach its own lockdown. See docs/PHONE-ONLY.md.
///
/// Every call blocks (idevice runs its own async runtime inside), so use one
/// instance from one background queue.
final class OnDeviceSimulator {
    struct Failure: LocalizedError {
        let step: String
        let code: Int32
        let message: String

        var errorDescription: String? { "\(step) failed: \(message)" }
    }

    /// The address LocalDevVPN gives this iPhone (StikDebug and SideStore use
    /// the same one).
    static let defaultAddress = "10.7.0.1"

    // Teardown order is the reverse of this list: the simulation client uses
    // the remote server, which borrows the handshake and the tunnel adapter.
    private var adapter: OpaquePointer?
    private var handshake: OpaquePointer?
    private var server: OpaquePointer?
    private var simulation: OpaquePointer?

    /// remotepairingd's port. Unlike lockdown (62078), it still answers over
    /// the network on iOS 26.7 and later (StikDebug uses the same one).
    static let remotePairingPort: UInt16 = 49152

    /// Connect, all the way to the location simulation channel.
    /// - Parameter pairingFile: the iPhone's pairing record, exported by the Mac app.
    init(pairingFile: Data, address: String = OnDeviceSimulator.defaultAddress) throws {
        // Remote Pairing when the file has that identity (any iOS 17+),
        // otherwise lockdown + CoreDeviceProxy (iOS 17.4 to 26.6 only).
        if PairingFile.hasRemotePairingIdentity(pairingFile) {
            try openRemotePairingTunnel(pairingFile, address: address)
        } else {
            try openLockdownTunnel(pairingFile, address: address)
        }

        // Both tunnels end in the same adapter + RSD handshake.
        do {
            try Self.check("Opening Instruments (is the developer disk image mounted?)",
                           remote_server_connect_rsd(adapter, handshake, &server))
            try Self.check("Opening location simulation", location_simulation_new(server, &simulation))
        } catch {
            close()
            throw error
        }
    }

    /// pair-verify with remotepairingd, then its TLS-PSK tunnel and RSD.
    private func openRemotePairingTunnel(_ pairingFile: Data, address: String) throws {
        var pairing: OpaquePointer?
        try Self.check("Reading the pairing file", pairingFile.withUnsafeBytes { buffer in
            rp_pairing_file_from_bytes(buffer.bindMemory(to: UInt8.self).baseAddress, UInt(buffer.count), &pairing)
        })
        defer { rp_pairing_file_free(pairing) }

        var socketAddress = try Self.socketAddress(address, port: Self.remotePairingPort)
        var newAdapter: OpaquePointer?
        var newHandshake: OpaquePointer?
        let error = withUnsafePointer(to: &socketAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                tunnel_create_rppairing(address, socklen_t(MemoryLayout<sockaddr_in>.size), "SpoofRemote",
                                        pairing, nil, nil, &newAdapter, &newHandshake)
            }
        }
        try Self.check("Opening the developer tunnel (is LocalDevVPN on?)", error)
        adapter = newAdapter
        handshake = newHandshake
    }

    private static func socketAddress(_ address: String, port: UInt16) throws -> sockaddr_in {
        var socketAddress = sockaddr_in()
        socketAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        socketAddress.sin_family = sa_family_t(AF_INET)
        socketAddress.sin_port = in_port_t(port.bigEndian)
        guard inet_pton(AF_INET, address, &socketAddress.sin_addr) == 1 else {
            throw Failure(step: "Reaching the iPhone", code: -1, message: "\(address) isn't an IPv4 address")
        }
        return socketAddress
    }

    /// The original path: lockdown with the pairing record, then CoreDeviceProxy.
    /// iOS 26.7 and later don't answer lockdown over the network, so this
    /// fails there with a connection error.
    private func openLockdownTunnel(_ pairingFile: Data, address: String) throws {
        var pairing: OpaquePointer?
        try Self.check("Reading the pairing file", pairingFile.withUnsafeBytes { buffer in
            idevice_pairing_file_from_bytes(buffer.bindMemory(to: UInt8.self).baseAddress, UInt(buffer.count), &pairing)
        })

        var socketAddress: sockaddr_in
        do {
            socketAddress = try Self.socketAddress(address, port: UInt16(LOCKDOWN_PORT))
        } catch {
            idevice_pairing_file_free(pairing)
            throw error
        }

        // The provider takes the pairing file over on success.
        var provider: OpaquePointer?
        let providerError = withUnsafePointer(to: &socketAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                idevice_tcp_provider_new(address, pairing, "SpoofRemote", &provider)
            }
        }
        if providerError != nil { idevice_pairing_file_free(pairing) }
        try Self.check("Reaching the iPhone's lockdown (is LocalDevVPN on?)", providerError)
        defer { idevice_provider_free(provider) }

        // The proxy is consumed by the tunnel adapter, even when that fails.
        var proxy: OpaquePointer?
        try Self.check("Opening the developer tunnel", core_device_proxy_connect(provider, &proxy))
        var rsdPort: UInt16 = 0
        if let error = core_device_proxy_get_server_rsd_port(proxy, &rsdPort) {
            core_device_proxy_free(proxy)
            try Self.check("Finding the developer services", error)
        }
        try Self.check("Starting the tunnel's network stack", core_device_proxy_create_tcp_adapter(proxy, &adapter))

        // The handshake consumes the stream; the server borrows the adapter
        // and the handshake, so both live until close().
        var stream: OpaquePointer?
        do {
            try Self.check("Connecting to the developer services", adapter_connect(adapter, rsdPort, &stream))
            try Self.check("Greeting the developer services", rsd_handshake_new(stream, &handshake))
        } catch {
            close()
            throw error
        }
    }

    deinit {
        close()
    }

    func set(latitude: Double, longitude: Double) throws {
        try Self.check("Setting the location", location_simulation_set(simulation, latitude, longitude))
    }

    /// Back to the real location.
    func clear() throws {
        try Self.check("Restoring the real location", location_simulation_clear(simulation))
    }

    /// Close the channel. On iOS 17 and later that also ends the simulation.
    func close() {
        if let simulation { location_simulation_free(simulation) }
        if let server { remote_server_free(server) }
        if let handshake { rsd_handshake_free(handshake) }
        if let adapter { adapter_free(adapter) }
        simulation = nil
        server = nil
        handshake = nil
        adapter = nil
    }

    private static func check(_ step: String, _ error: UnsafeMutablePointer<IdeviceFfiError>?) throws {
        guard let error else { return }
        let failure = Failure(step: step, code: error.pointee.code,
                              message: error.pointee.message.map { String(cString: $0) } ?? "unknown error")
        idevice_error_free(error)
        throw failure
    }
}
