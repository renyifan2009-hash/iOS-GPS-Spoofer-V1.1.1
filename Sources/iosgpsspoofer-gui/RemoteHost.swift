import Foundation
import Observation
import RemoteAPI
import SpooferCore
import SpooferRemote

/// Settings ▸ iPhone Remote: runs the remote server inside the app, so the
/// SpoofRemote iPhone app drives this window's session and you see on the
/// Mac whatever the iPhone does. (`iosgpsspoof serve` is the headless
/// alternative; run one or the other, they share the port.)
@MainActor
@Observable
final class RemoteHost {
    static let shared = RemoteHost()
    private static let enabledKey = "remoteControlEnabled"

    enum ServerState: Equatable {
        case off
        case starting
        case running
        case failed(String)
    }

    var isEnabled: Bool = UserDefaults.standard.bool(forKey: RemoteHost.enabledKey) {
        didSet {
            guard isEnabled != oldValue else { return }
            UserDefaults.standard.set(isEnabled, forKey: Self.enabledKey)
            if isEnabled { start() } else { stop() }
        }
    }

    private(set) var state: ServerState = .off
    private(set) var pairingCode = ""
    private(set) var clients: [PairingManager.PairedClient] = []
    private(set) var addresses: [BonjourService.LocalAddress] = []
    let serverName = BonjourService.computerName
    let port = RemoteAPI.defaultPort

    @ObservationIgnored private var server: MacRemoteServer?
    @ObservationIgnored private var pairing: PairingManager?
    @ObservationIgnored private let bridge = AppRemoteBridge()

    /// At launch: start the server if the setting is on.
    func bootstrap() {
        if isEnabled { start() }
    }

    func start() {
        guard server == nil else { return }
        let pairing = PairingManager()
        let server = MacRemoteServer(name: serverName, port: port, controller: bridge, pairing: pairing)
        pairing.onChange = {
            Task { @MainActor in RemoteHost.shared.refreshPairing() }
        }
        server.onStateChange = { state in
            Task { @MainActor in RemoteHost.shared.serverStateChanged(state) }
        }
        server.onLog = { line in
            Task { @MainActor in AppModel.shared.appendLog("iPhone Remote: \(line)", level: .debug) }
        }
        server.onCommand = { what, client in
            Task { @MainActor in RemoteHost.shared.commandReceived(what, from: client.name) }
        }
        self.pairing = pairing
        self.server = server
        refreshPairing()
        addresses = BonjourService.localIPv4Addresses()
        state = .starting
        do {
            try server.start()
        } catch {
            self.server = nil
            state = .failed("\(error)")
        }
    }

    func stop() {
        server?.stop()
        server = nil
        pairing = nil
        state = .off
    }

    func newCode() {
        pairing?.regenerateCode()
    }

    func unpair(_ client: PairingManager.PairedClient) {
        pairing?.revoke(clientID: client.id)
    }

    func refreshAddresses() {
        addresses = BonjourService.localIPv4Addresses()
    }

    private func refreshPairing() {
        guard let pairing else { return }
        pairingCode = pairing.formattedCode
        clients = pairing.pairedClients.sorted { $0.pairedAt > $1.pairedAt }
    }

    private func serverStateChanged(_ newState: MacRemoteServer.State) {
        guard server != nil else { return }
        switch newState {
        case .starting:
            state = .starting
        case .ready:
            state = .running
            AppModel.shared.appendLog("iPhone Remote is on: pair with code \(pairingCode).", level: .info)
        case .failed(let message):
            state = .failed(message)
            server = nil
            AppModel.shared.appendLog("iPhone Remote couldn't start: \(message)", level: .error)
        case .stopped:
            break
        }
    }

    private func commandReceived(_ what: String, from name: String) {
        refreshPairing()
        AppModel.shared.showToast(Toast(symbol: "iphone.radiowaves.left.and.right", title: "From \(name)",
                                        subtitle: what.prefix(1).uppercased() + what.dropFirst(), style: .info))
    }
}

/// Lets the remote server drive the app's own model. Fixed-point only:
/// start and move call `AppModel.teleport(to:name:)`, exactly like the
/// Teleport button (which creates the `SpoofSession` or moves it), and stop
/// calls `AppModel.stop()`.
@MainActor
final class AppRemoteBridge: RemoteController {
    func status() async -> RemoteStatus {
        Self.makeStatus(AppModel.shared)
    }

    func setLocation(_ request: LocationRequest) async throws -> RemoteStatus {
        let model = AppModel.shared
        let point = GeoPoint(request.latitude, request.longitude)
        guard point.isValid else { throw RemoteControlError("That isn't a valid coordinate.", status: 400) }
        model.setTarget(point, name: request.name, focus: true)
        if model.session != nil {
            model.mode = .teleport
            model.teleport(to: point, name: request.name)
        }
        return Self.makeStatus(model)
    }

    func start(_ request: LocationRequest?) async throws -> RemoteStatus {
        let model = AppModel.shared
        if let request {
            let point = GeoPoint(request.latitude, request.longitude)
            guard point.isValid else { throw RemoteControlError("That isn't a valid coordinate.", status: 400) }
            model.setTarget(point, name: request.name, focus: true)
        }
        guard let point = model.target else {
            throw RemoteControlError("Pick a location first.", status: 400)
        }
        guard model.pmd != nil else {
            throw RemoteControlError("The Mac app can't find pymobiledevice3. Finish its setup on the Mac.")
        }
        guard model.session != nil || model.selectedDevice != nil else {
            throw RemoteControlError("No iPhone is connected to the Mac. Connect it with a cable and tap Trust.")
        }
        guard model.sessionState != .stopping else {
            throw RemoteControlError("Still restoring the real location. Try again in a moment.")
        }
        model.mode = .teleport
        model.teleport(to: point, name: request?.name ?? model.targetName)
        return Self.makeStatus(model)
    }

    func stop() async -> RemoteStatus {
        AppModel.shared.stop()
        return Self.makeStatus(AppModel.shared)
    }

    static func makeStatus(_ model: AppModel) -> RemoteStatus {
        let spoofing = model.session != nil || model.isStarting
        let position = model.devicePosition ?? (spoofing ? model.target : nil)
        let device = model.activeDevice
        let connected = device.map { d in model.devices.contains { $0.udid == d.udid } } ?? false
        var phase = SessionRemoteController.phase(for: model.sessionState)
        if model.isStarting && model.session == nil { phase = .starting }
        return RemoteStatus(
            connected: connected,
            spoofing: spoofing,
            latitude: position?.latitude,
            longitude: position?.longitude,
            placeName: spoofing ? (model.devicePlaceName ?? model.targetName) : nil,
            phase: phase,
            detail: SessionRemoteController.detail(for: model.sessionState),
            device: device.map {
                DeviceSummary(name: $0.deviceName, model: $0.modelName, iosVersion: $0.productVersion,
                              connection: $0.isUSB ? "usb" : "network")
            },
            engine: model.sessionEngine?.label,
            serverName: RemoteHost.shared.serverName)
    }
}
