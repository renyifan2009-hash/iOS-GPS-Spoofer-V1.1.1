import Darwin
import Foundation
import IDevice
import PhoneOnlyCore

/// Attempts to change this iPhone's location from the iPhone itself (iOS 17 and
/// later), the way a Mac does over USB: a developer tunnel, RSD, then DVT's
/// location simulation channel. The LocalDevVPN app routes the iPhone's own
/// address back to it, which is how an app can reach its own developer
/// services. See docs/PHONE-ONLY.md.
///
/// There are two ways to open the tunnel (`TunnelRoute`), and the pairing
/// file decides which are possible:
/// - **Remote Pairing**: pair-verify with remotepairingd, then its own
///   tunnel. On iOS 17.0–17.3 this path still needs a physical-device test.
/// - **Lockdown**: lockdown with the pairing record, then CoreDeviceProxy.
///   Newer iOS versions don't answer lockdown through LocalDevVPN.
///
/// Every call blocks (idevice runs its own async runtime inside), so use one
/// instance from one background queue.
final class OnDeviceSimulator {
    /// The address LocalDevVPN gives this iPhone (StikDebug and SideStore use
    /// the same one).
    static let defaultAddress = "10.7.0.1"

    /// The name this app gives the iPhone when it has to pair again. The
    /// iPhone shows it in its Trust prompt.
    private static let hostName = "SpoofRemote"

    // Teardown order is the reverse of this list: the simulation client uses
    // the remote server, which borrows the handshake and the tunnel adapter.
    private var adapter: OpaquePointer?
    private var handshake: OpaquePointer?
    private var server: OpaquePointer?
    private var simulation: OpaquePointer?

    /// The route that opened the tunnel.
    private(set) var route: TunnelRoute?

    /// Connect, all the way to the location simulation channel.
    /// - Parameters:
    ///   - pairing: the iPhone's pairing file, saved by the Mac app.
    ///   - routes: the ways to try, in order (`TunnelPlan` picks them). The
    ///     first that opens a tunnel is used. If none does, the error is the
    ///     most telling of their failures.
    ///   - onRenewedPairing: called with the pairing file holding a new
    ///     Remote Pairing identity, when the iPhone no longer knew the old
    ///     one and idevice paired again while connecting (the iPhone asked to
    ///     trust SpoofRemote). Keep that file: with the old one, every
    ///     connection would pair again. It can be called even when the
    ///     connection then fails.
    init(pairing: PairingRecord, routes: [TunnelRoute], address: String = OnDeviceSimulator.defaultAddress,
         developerImage: URL? = nil,
         onRenewedPairing: (PairingRecord) -> Void = { _ in }) throws {
        // The file as it stands: a route that pairs again changes it for the routes after it.
        var pairing = pairing
        var failures: [TunnelFailure] = []
        for candidate in routes {
            do {
                switch candidate {
                case .remotePairing(let port):
                    try openRemotePairingTunnel(pairing, address: address, port: port) { renewed in
                        pairing = renewed
                        onRenewedPairing(renewed)
                    }
                case .lockdown:
                    try openLockdownTunnel(pairing, address: address)
                }
                route = candidate
                break
            } catch {
                failures.append(error as? TunnelFailure
                    ?? TunnelFailure(step: .tunnel, route: candidate, message: error.localizedDescription))
                close()
            }
        }
        guard let route else {
            throw TunnelFailure.mostTelling(failures) ?? TunnelFailure.noRoute
        }

        // Every tunnel ends in the same adapter and RSD handshake. From here
        // on another route wouldn't help: the tunnel is open.
        do {
            if try mountDeveloperSupportIfNeeded(from: developerImage) {
                // Service advertisements were captured before the image was mounted. A fresh
                // tunnel obtains a new RSD handshake containing the newly started developer services.
                close()
                switch route {
                case .remotePairing(let port):
                    try openRemotePairingTunnel(pairing, address: address, port: port) { renewed in
                        pairing = renewed
                        onRenewedPairing(renewed)
                    }
                case .lockdown: try openLockdownTunnel(pairing, address: address)
                }
            }
            try Self.check(.instruments, route, remote_server_connect_rsd(adapter, handshake, &server))
            try Self.check(.simulation, route, location_simulation_new(server, &simulation))
        } catch {
            close()
            throw error
        }
    }

    /// Mount only when RSD has no Instruments service. Never replace developer support that is
    /// already running. Personalization stays in idevice and Apple's signing service.
    private func mountDeveloperSupportIfNeeded(from directory: URL?) throws -> Bool {
        var instrumentsAvailable = false
        try Self.check(.services, route,
                       rsd_service_available(handshake, "com.apple.instruments.dtservicehub", &instrumentsAvailable))
        guard !instrumentsAvailable else { return false }
        guard let directory else {
            throw TunnelFailure(step: .developerImage, route: route,
                                message: "No developer image is stored on this iPhone. Import the Apple DDI folder in Set Up.")
        }
        let bundle: DeveloperImageBundle
        do { bundle = try DeveloperImageBundle(directory: directory) }
        catch { throw TunnelFailure(step: .developerImage, route: route, message: error.localizedDescription) }
        var cryptexAvailable = false
        try Self.check(.services, route,
                       rsd_service_available(handshake, "com.apple.security.cryptexd.remote", &cryptexAvailable))
        if bundle.cryptexPaths != nil, cryptexAvailable {
            var assets: OpaquePointer?
            try Self.check(.developerImage, route, cryptex1_assets_load(directory.path, &assets))
            defer { cryptex1_assets_free(assets) }
            try Self.check(.developerImage, route, cryptexd_install_ddi(adapter, handshake, assets, nil))
            return true
        }

        guard let personalizedPaths = bundle.personalizedPaths else {
            throw TunnelFailure(step: .developerImage, route: route,
                                message: "This folder only contains Cryptex payloads, but this iPhone doesn't advertise the Cryptex service. Import a matching Apple DDI folder.")
        }

        var lockdown: OpaquePointer?
        try Self.check(.developerImage, route, lockdownd_connect_rsd(adapter, handshake, &lockdown))
        defer { lockdownd_client_free(lockdown) }
        var value: plist_t?
        try Self.check(.developerImage, route, lockdownd_get_value(lockdown, "UniqueChipID", nil, &value))
        defer { plist_free(value) }
        var ecid: UInt64 = 0
        plist_get_uint_val(value, &ecid)
        guard ecid != 0 else {
            throw TunnelFailure(step: .developerImage, route: route, message: "This iPhone didn't report its personalization identifier.")
        }
        var mounter: OpaquePointer?
        try Self.check(.developerImage, route, image_mounter_connect_rsd(adapter, handshake, &mounter))
        defer { image_mounter_free(mounter) }
        let image = try DeveloperImageBundle.read(personalizedPaths[0], in: directory,
                                                  limit: DeveloperImageBundle.maxImageBytes)
        let cache = try DeveloperImageBundle.read(personalizedPaths[1], in: directory,
                                                  limit: DeveloperImageBundle.maxImageBytes)
        let manifest = try DeveloperImageBundle.read("BuildManifest.plist", in: directory,
                                                     limit: DeveloperImageBundle.maxManifestBytes)
        let error = image.withUnsafeBytes { imageBytes in
            cache.withUnsafeBytes { cacheBytes in
                manifest.withUnsafeBytes { manifestBytes in
                    image_mounter_mount_personalized_rsd(mounter, adapter, handshake,
                        imageBytes.bindMemory(to: UInt8.self).baseAddress, image.count,
                        cacheBytes.bindMemory(to: UInt8.self).baseAddress, cache.count,
                        manifestBytes.bindMemory(to: UInt8.self).baseAddress, manifest.count, nil, ecid)
                }
            }
        }
        try Self.check(.developerImage, route, error)
        return true
    }

    /// Pair-verify with remotepairingd, then its TLS-PSK tunnel and RSD: one
    /// call in idevice.
    private func openRemotePairingTunnel(_ pairing: PairingRecord, address: String, port: UInt16,
                                         onRenewedPairing: (PairingRecord) -> Void) throws {
        let route = TunnelRoute.remotePairing(port: port)
        // idevice reads the identity's keys and skips the rest of the file.
        var file: OpaquePointer?
        try Self.check(.pairingFile, route, pairing.data.withUnsafeBytes { buffer in
            rp_pairing_file_from_bytes(buffer.bindMemory(to: UInt8.self).baseAddress, UInt(buffer.count), &file)
        })
        // Borrowed by the tunnel call, not taken over.
        defer { rp_pairing_file_free(file) }

        var socketAddress = try Self.socketAddress(address, port: port, route: route)
        var newAdapter: OpaquePointer?
        var newHandshake: OpaquePointer?
        let error = withUnsafePointer(to: &socketAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                tunnel_create_rppairing(address, socklen_t(MemoryLayout<sockaddr_in>.size), Self.hostName,
                                        file, nil, nil, &newAdapter, &newHandshake)
            }
        }
        // When pair-verify fails, idevice pairs from scratch on the same
        // connection and puts the new keys in `file`. Read them back before
        // looking at the error: the pairing can go through and the tunnel
        // still fail, and the iPhone then knows only the new keys.
        let identity = Self.identity(in: file)
        if let renewed = identity.flatMap({ pairing.adoptingRemotePairing(from: $0, tunnelOpened: error == nil) }) {
            onRenewedPairing(renewed)
        }
        try Self.check(.tunnel, route, error)
        adapter = newAdapter
        handshake = newHandshake
    }

    /// The identity idevice now holds, as its property list.
    private static func identity(in file: OpaquePointer?) -> Data? {
        var bytes: UnsafeMutablePointer<UInt8>?
        var count: UInt = 0
        if let error = rp_pairing_file_to_bytes(file, &bytes, &count) {
            idevice_error_free(error)
            return nil
        }
        guard let bytes else { return nil }
        defer { idevice_data_free(bytes, count) }
        return Data(bytes: bytes, count: Int(count))
    }

    private static func socketAddress(_ address: String, port: UInt16, route: TunnelRoute) throws -> sockaddr_in {
        var socketAddress = sockaddr_in()
        socketAddress.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        socketAddress.sin_family = sa_family_t(AF_INET)
        socketAddress.sin_port = in_port_t(port.bigEndian)
        guard inet_pton(AF_INET, address, &socketAddress.sin_addr) == 1 else {
            throw TunnelFailure(step: .reach, route: route, message: "\(address) isn't an IPv4 address")
        }
        return socketAddress
    }

    /// Lockdown with the pairing record, then CoreDeviceProxy. Newer iOS
    /// versions don't answer lockdown through LocalDevVPN, so this fails
    /// there with a connection error.
    private func openLockdownTunnel(_ pairing: PairingRecord, address: String) throws {
        let route = TunnelRoute.lockdown
        // idevice reads the lockdown record's keys and skips the rest of the file.
        var file: OpaquePointer?
        try Self.check(.pairingFile, route, pairing.data.withUnsafeBytes { buffer in
            idevice_pairing_file_from_bytes(buffer.bindMemory(to: UInt8.self).baseAddress, UInt(buffer.count), &file)
        })

        var socketAddress: sockaddr_in
        do {
            socketAddress = try Self.socketAddress(address, port: TunnelPlan.lockdownPort, route: route)
        } catch {
            idevice_pairing_file_free(file)
            throw error
        }

        // The provider takes the pairing file over on success.
        var provider: OpaquePointer?
        let providerError = withUnsafePointer(to: &socketAddress) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { address in
                idevice_tcp_provider_new(address, file, Self.hostName, &provider)
            }
        }
        if providerError != nil { idevice_pairing_file_free(file) }
        try Self.check(.reach, route, providerError)
        defer { idevice_provider_free(provider) }

        // The proxy is consumed by the tunnel adapter, even when that fails.
        var proxy: OpaquePointer?
        try Self.check(.tunnel, route, core_device_proxy_connect(provider, &proxy))
        var rsdPort: UInt16 = 0
        if let error = core_device_proxy_get_server_rsd_port(proxy, &rsdPort) {
            core_device_proxy_free(proxy)
            try Self.check(.services, route, error)
        }
        try Self.check(.services, route, core_device_proxy_create_tcp_adapter(proxy, &adapter))

        // The handshake consumes the stream; the server borrows the adapter
        // and the handshake, so both live until close().
        var stream: OpaquePointer?
        do {
            try Self.check(.services, route, adapter_connect(adapter, rsdPort, &stream))
            try Self.check(.services, route, rsd_handshake_new(stream, &handshake))
        } catch {
            close()
            throw error
        }
    }

    deinit {
        close()
    }

    func set(latitude: Double, longitude: Double) throws {
        try Self.check(.setLocation, route, location_simulation_set(simulation, latitude, longitude))
    }

    /// Back to the real location.
    func clear() throws {
        try Self.check(.clearLocation, route, location_simulation_clear(simulation))
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

    private static func check(_ step: TunnelFailure.Step, _ route: TunnelRoute?,
                              _ error: UnsafeMutablePointer<IdeviceFfiError>?) throws {
        guard let error else { return }
        let failure = TunnelFailure(step: step, route: route, code: error.pointee.code,
                                    subCode: error.pointee.sub_code,
                                    message: error.pointee.message.map { String(cString: $0) } ?? "unknown error")
        idevice_error_free(error)
        throw failure
    }
}
