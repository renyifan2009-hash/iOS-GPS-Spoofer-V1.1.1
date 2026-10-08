import CoreLocation
import Foundation
import Network
import Observation

/// The iPhone-only mode: this app changes this iPhone's location by itself,
/// with no Mac, once it has the pairing file (see docs/PHONE-ONLY.md).
@MainActor
@Observable
final class OnDeviceController {
    enum Phase: Equatable {
        case idle
        case connecting
        case active
    }

    private(set) var phase: Phase = .idle
    private(set) var pairing: PairingFile? = PairingFile.load()
    /// Whether LocalDevVPN routes this iPhone's own address back to it. Nil
    /// until checked.
    private(set) var loopbackReachable: Bool?
    private(set) var checkingLoopback = false
    /// Where this iPhone is held, while active.
    private(set) var current: CLLocationCoordinate2D?
    private(set) var currentName: String?
    var lastError: String?

    var isSetUp: Bool { pairing != nil }
    var isSpoofing: Bool { phase == .active }
    var isWorking: Bool { phase == .connecting }

    /// CoreDevice's tunnel, which this mode needs, arrived in iOS 17.4.
    static let isSupported = ProcessInfo.processInfo.isOperatingSystemAtLeast(
        OperatingSystemVersion(majorVersion: 17, minorVersion: 4, patchVersion: 0))

    private let engine = OnDeviceEngine()
    private let keepAlive = KeepAlive()

    // MARK: Pairing file

    /// Import a pairing file from Files, AirDrop or "Open in".
    @discardableResult
    func importPairingFile(from url: URL) -> Bool {
        do {
            let file = try PairingFile(contentsOf: url)
            guard file.save() else {
                lastError = "Couldn't keep the pairing file in the Keychain. Try again."
                return false
            }
            pairing = file
            lastError = nil
            return true
        } catch {
            lastError = error.localizedDescription
            return false
        }
    }

    func removePairingFile() {
        Task {
            await stop()
            PairingFile.delete()
            pairing = nil
        }
    }

    // MARK: LocalDevVPN

    @ObservationIgnored private var loopbackCheck: Task<Bool, Never>?

    /// Check now, or wait for the check already running.
    func checkLoopback() async {
        if let running = loopbackCheck {
            _ = await running.value
            return
        }
        checkingLoopback = true
        let check = Task { await LoopbackProbe.lockdownReachable() }
        loopbackCheck = check
        loopbackReachable = await check.value
        loopbackCheck = nil
        checkingLoopback = false
    }

    // MARK: The location

    /// Start holding `coordinate`, or move there if already holding one.
    @discardableResult
    func set(_ coordinate: CLLocationCoordinate2D, name: String?) async -> Bool {
        guard let pairing else {
            lastError = "Set up this iPhone first: it needs the pairing file from your Mac."
            return false
        }
        guard phase != .connecting else { return false }
        let wasActive = phase == .active
        if !wasActive {
            phase = .connecting
            // Without LocalDevVPN the connection would wait a long time
            // before failing, so check first; it takes a moment.
            await checkLoopback()
            guard loopbackReachable == true else {
                phase = .idle
                lastError = "Can't reach this iPhone's developer services. Open LocalDevVPN and tap Connect. "
                    + "If it's on, allow SpoofRemote in Settings ▸ Privacy & Security ▸ Local Network."
                return false
            }
            // Before the connection, so iOS doesn't suspend the app halfway.
            keepAlive.start()
        }
        do {
            try await engine.set(latitude: coordinate.latitude, longitude: coordinate.longitude, pairing: pairing.data)
            phase = .active
            current = coordinate
            currentName = name
            lastError = nil
            return true
        } catch {
            // The engine closed the connection, which ends any location it held.
            lastError = Self.explain(error)
            phase = .idle
            current = nil
            currentName = nil
            keepAlive.stop()
            return false
        }
    }

    /// Back to the real location.
    func stop() async {
        guard phase != .idle else { return }
        await engine.clear()
        keepAlive.stop()
        phase = .idle
        current = nil
        currentName = nil
    }

    /// Plain words for what went wrong.
    private static func explain(_ error: Error) -> String {
        guard let failure = error as? OnDeviceSimulator.Failure else { return error.localizedDescription }
        let message = failure.message.lowercased()
        if message.contains("pair") || message.contains("ssl") || message.contains("tls") || message.contains("certificate") {
            return "The iPhone didn't accept the pairing file. Save a new one from your Mac and open it here."
        }
        if failure.step.hasPrefix("Opening Instruments") || message.contains("image") {
            return "Apple's developer support isn't loaded. Connect this iPhone to your Mac once and open iOS GPS Spoofer."
        }
        if message.contains("developer mode") {
            return "Developer Mode is off. Turn it on in Settings ▸ Privacy & Security ▸ Developer Mode."
        }
        return "\(failure.step) didn't work: \(failure.message)"
    }
}

/// Owns the simulator on one serial queue: its calls block while idevice
/// talks to the iPhone.
final class OnDeviceEngine: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.iosgpsspoof.remote.on-device", qos: .userInitiated)
    /// Only touched on `queue`.
    private var simulator: OnDeviceSimulator?

    func set(latitude: Double, longitude: Double, pairing: Data) async throws {
        try await perform {
            if let simulator = self.simulator {
                do {
                    try simulator.set(latitude: latitude, longitude: longitude)
                    return
                } catch {
                    // The connection dropped (LocalDevVPN restarted, the
                    // network changed): connect again, once.
                    simulator.close()
                    self.simulator = nil
                }
            }
            let fresh = try OnDeviceSimulator(pairingFile: pairing)
            do {
                try fresh.set(latitude: latitude, longitude: longitude)
            } catch {
                fresh.close()
                throw error
            }
            self.simulator = fresh
        }
    }

    func clear() async {
        try? await perform {
            defer {
                self.simulator?.close()
                self.simulator = nil
            }
            try self.simulator?.clear()
        }
    }

    private func perform(_ work: @escaping @Sendable () throws -> Void) async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                do {
                    try work()
                    continuation.resume()
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
}

/// Is LocalDevVPN on? It routes this iPhone's address (10.7.0.1) back to the
/// iPhone, so lockdown answers there.
enum LoopbackProbe {
    static func lockdownReachable(address: String = OnDeviceSimulator.defaultAddress,
                                  timeout: TimeInterval = 2) async -> Bool {
        await withCheckedContinuation { continuation in
            let connection = NWConnection(host: NWEndpoint.Host(address), port: 62078, using: .tcp)
            let finish = Once { (reachable: Bool) in
                connection.cancel()
                continuation.resume(returning: reachable)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(true)
                case .failed, .waiting: finish(false)
                default: break
                }
            }
            let queue = DispatchQueue(label: "com.iosgpsspoof.remote.loopback-probe")
            connection.start(queue: queue)
            queue.asyncAfter(deadline: .now() + timeout) { finish(false) }
        }
    }

    /// Runs its action the first time it's called, from any thread.
    private final class Once<Value>: @unchecked Sendable {
        private let lock = NSLock()
        private var action: ((Value) -> Void)?

        init(_ action: @escaping (Value) -> Void) {
            self.action = action
        }

        func callAsFunction(_ value: Value) {
            lock.lock()
            let action = self.action
            self.action = nil
            lock.unlock()
            action?(value)
        }
    }
}

/// Keeps the app running in the background while it holds a location: the
/// location lasts while the app's connection to the iPhone's developer
/// services stays open, and iOS closes it when it suspends the app. A
/// background location session (the blue pill in the status bar) keeps
/// the app awake.
@MainActor
final class KeepAlive {
    private var session: CLBackgroundActivitySession?
    private var updates: Task<Void, Never>?
    private let manager = CLLocationManager()

    func start() {
        guard session == nil else { return }
        if manager.authorizationStatus == .notDetermined {
            manager.requestWhenInUseAuthorization()
        }
        session = CLBackgroundActivitySession()
        updates = Task {
            do {
                for try await _ in CLLocationUpdate.liveUpdates(.otherNavigation) {
                    if Task.isCancelled { break }
                }
            } catch {}
        }
    }

    func stop() {
        updates?.cancel()
        updates = nil
        session?.invalidate()
        session = nil
    }
}
