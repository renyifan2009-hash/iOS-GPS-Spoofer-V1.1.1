import Foundation
import RemoteAPI
import SpooferCore

/// Runs the location for the remote server with no UI: what
/// `iosgpsspoof serve` uses. It reuses SpooferCore's session unchanged:
///
/// - start → `Pymobiledevice3.selectDevice(udid:connection:)`, then
///   `SpoofSession(pmd:device:transport:engine:python:callbackQueue:)` and
///   `SpoofSession.start(at:)`
/// - move  → `SpoofSession.move(to:)` (a single message with the live engine)
/// - stop  → `SpoofSession.stop()` (restores the real location)
///
/// `SpoofSession` already waits for an iPhone that went away and re-opens the
/// channel when it returns. On top of that, this restarts a session that gave
/// up (`.failed`) for as long as the iPhone still wants the location held,
/// and keeps the Mac from idle-sleeping meanwhile.
public final class SessionRemoteController: RemoteController, @unchecked Sendable {
    public struct Options: Sendable {
        public var udid: String?
        public var connection: ConnectionFilter
        public var transport: Transport
        public var engine: EngineKind
        public var retryAfterFailure: TimeInterval
        public var serverName: String

        public init(udid: String? = nil, connection: ConnectionFilter = .any, transport: Transport = .native,
                    engine: EngineKind = .classic, retryAfterFailure: TimeInterval = 15,
                    serverName: String = BonjourService.computerName) {
            self.udid = udid
            self.connection = connection
            self.transport = transport
            self.engine = engine
            self.retryAfterFailure = retryAfterFailure
            self.serverName = serverName
        }
    }

    public var onLog: (@Sendable (LogLevel, String) -> Void)?

    private let pmd: Pymobiledevice3
    private let options: Options
    private let queue = DispatchQueue(label: "SessionRemoteController", qos: .userInitiated)
    private let monitorQueue = DispatchQueue(label: "SessionRemoteController.monitor", qos: .utility)

    // Confined to `queue`.
    private var session: SpoofSession?
    private var state: SessionState = .idle
    private var engine: EngineKind?
    private var device: Device?
    private var deviceConnected = false
    private var target: LocationRequest?
    private var position: GeoPoint?
    private var wantsLocation = false
    private var retryScheduled = false
    private var keepAwake: NSObjectProtocol?
    private var monitor: DispatchSourceTimer?

    public init(pmd: Pymobiledevice3, options: Options) {
        self.pmd = pmd
        self.options = options
    }

    /// Check for the iPhone every few seconds, so `/status` can say whether
    /// the Mac sees it even when nothing is being simulated.
    public func startMonitoring(interval: TimeInterval = 5) {
        let timer = DispatchSource.makeTimerSource(queue: monitorQueue)
        timer.schedule(deadline: .now(), repeating: interval)
        timer.setEventHandler { [weak self] in self?.pollDevices() }
        queue.sync { monitor = timer }
        timer.resume()
    }

    /// Synchronous teardown for Ctrl-C / `launchctl` stop: restores the real
    /// location before returning.
    public func shutdown() {
        let running = queue.sync { () -> SpoofSession? in
            wantsLocation = false
            monitor?.cancel()
            monitor = nil
            endKeepAwake()
            return session
        }
        running?.stopBlocking()
    }

    // MARK: - RemoteController

    public func status() async -> RemoteStatus {
        await onQueue { self.makeStatus() }
    }

    public func setLocation(_ request: LocationRequest) async throws -> RemoteStatus {
        try await onQueueThrowing {
            guard request.isValid else { throw RemoteControlError("That isn't a valid coordinate.", status: 400) }
            self.target = request
            if self.wantsLocation, let session = self.session {
                self.log(.info, "moving to \(Self.describe(request))")
                self.apply(request, to: session)
            }
            return self.makeStatus()
        }
    }

    public func start(_ request: LocationRequest?) async throws -> RemoteStatus {
        try await onQueueThrowing {
            if let request {
                guard request.isValid else { throw RemoteControlError("That isn't a valid coordinate.", status: 400) }
                self.target = request
            }
            guard let target = self.target else {
                throw RemoteControlError("Pick a location first.", status: 400)
            }
            if self.state == .stopping {
                throw RemoteControlError("Still restoring the real location. Try again in a moment.")
            }
            if let session = self.session {
                self.wantsLocation = true
                self.beginKeepAwake()
                self.log(.info, "moving to \(Self.describe(target))")
                self.apply(target, to: session)
                return self.makeStatus()
            }
            let device = try self.chooseDevice()
            self.wantsLocation = true
            self.beginKeepAwake()
            let session = self.makeSession(device: device)
            self.session = session
            self.state = .connecting("Preparing \(device.deviceName)…")
            self.log(.info, "holding \(Self.describe(target)) on \(device.deviceName)")
            session.start(at: GeoPoint(target.latitude, target.longitude))
            return self.makeStatus()
        }
    }

    public func stop() async -> RemoteStatus {
        await onQueue {
            self.wantsLocation = false
            self.endKeepAwake()
            if let session = self.session, self.state != .stopping {
                self.log(.info, "stopping, restoring the real location…")
                self.state = .stopping
                session.stop()
            }
            return self.makeStatus()
        }
    }

    // MARK: - Session

    private func apply(_ request: LocationRequest, to session: SpoofSession) {
        let point = GeoPoint(request.latitude, request.longitude)
        if case .failed = state {
            session.start(at: point)     // gave up earlier: start over
        } else {
            session.move(to: point)
        }
    }

    private func chooseDevice() throws -> Device {
        if let found = try? pmd.selectDevice(udid: options.udid, connection: options.connection) {
            device = found
            deviceConnected = true
            return found
        }
        // Known but not connected right now: the session waits for it.
        if let device { return device }
        throw RemoteControlError("No iPhone is connected to the Mac. Connect it with a cable and tap Trust.")
    }

    private func makeSession(device: Device) -> SpoofSession {
        let python = pmd.pythonInterpreter
        let engine: EngineKind = (options.engine == .live && python != nil) ? .live : .classic
        let session = SpoofSession(pmd: pmd, device: device, transport: options.transport, engine: engine,
                                   python: engine == .live ? python : nil, callbackQueue: queue)
        let id = ObjectIdentifier(session)
        session.onStateChange = { [weak self] state in self?.sessionStateChanged(state, id: id) }
        session.onPosition = { [weak self] point in self?.positionApplied(point, id: id) }
        session.onEngineChange = { [weak self] engine in self?.engineChanged(engine, id: id) }
        session.onLog = { [weak self] level, line in self?.log(level, line) }
        self.engine = session.engine
        log(.info, "\(session.engine.label.lowercased()) engine, \(device.modelName), iOS \(device.productVersion)")
        return session
    }

    private func isCurrent(_ id: ObjectIdentifier) -> Bool {
        guard let session else { return false }
        return ObjectIdentifier(session) == id
    }

    // The session's callbacks arrive on `queue`.
    private func sessionStateChanged(_ newState: SessionState, id: ObjectIdentifier) {
        guard isCurrent(id) else { return }
        state = newState
        switch newState {
        case .idle:
            session = nil
            position = nil
            engine = nil
            if !wantsLocation {
                endKeepAwake()
                log(.success, "real location restored")
            }
        case .active:
            retryScheduled = false
        case .failed(let message):
            log(.error, message)
            scheduleRetry(id: id)
        default:
            break
        }
    }

    private func scheduleRetry(id: ObjectIdentifier) {
        guard wantsLocation, !retryScheduled else { return }
        retryScheduled = true
        let delay = options.retryAfterFailure
        log(.warning, "trying again in \(Int(delay)) s")
        queue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            self.retryScheduled = false
            guard self.wantsLocation, self.isCurrent(id), case .failed = self.state,
                  let session = self.session, let target = self.target else { return }
            session.start(at: GeoPoint(target.latitude, target.longitude))
        }
    }

    private func positionApplied(_ point: GeoPoint, id: ObjectIdentifier) {
        guard isCurrent(id) else { return }
        position = point
    }

    private func engineChanged(_ newEngine: EngineKind, id: ObjectIdentifier) {
        guard isCurrent(id) else { return }
        engine = newEngine
        log(.warning, "switched to the \(newEngine.label.lowercased()) engine")
    }

    private func pollDevices() {
        let devices = (try? pmd.listDevices()) ?? []
        let match = devices.first { candidate in
            if let udid = options.udid { return candidate.udid == udid }
            return options.connection.matches(candidate)
        }
        queue.async { [self] in
            let wasConnected = deviceConnected
            deviceConnected = match != nil
            if let match { device = match }
            if wasConnected != deviceConnected {
                let name = device?.deviceName ?? "iPhone"
                log(.info, deviceConnected ? "\(name) connected" : "\(name) disconnected")
            }
        }
    }

    // MARK: - Status

    private func makeStatus() -> RemoteStatus {
        let held = position.map { LocationRequest(latitude: $0.latitude, longitude: $0.longitude) }
            ?? (wantsLocation ? target : nil)
        var placeName: String?
        if let held, let target, abs(held.latitude - target.latitude) < 1e-6,
           abs(held.longitude - target.longitude) < 1e-6 {
            placeName = target.name
        }
        let summary = device.map {
            DeviceSummary(name: $0.deviceName, model: $0.modelName, iosVersion: $0.productVersion,
                          connection: $0.isUSB ? "usb" : "network")
        }
        return RemoteStatus(connected: deviceConnected || state.isEngaged,
                            spoofing: wantsLocation && session != nil,
                            latitude: held?.latitude, longitude: held?.longitude,
                            placeName: placeName,
                            phase: Self.phase(for: state),
                            detail: Self.detail(for: state),
                            device: summary,
                            engine: engine?.label,
                            serverName: options.serverName)
    }

    public static func phase(for state: SessionState) -> SpoofPhase {
        switch state {
        case .idle: return .idle
        case .connecting: return .starting
        case .active, .replaying: return .active
        case .reconnecting: return .reconnecting
        case .stopping: return .stopping
        case .failed: return .failed
        }
    }

    public static func detail(for state: SessionState) -> String? {
        switch state {
        case .connecting(let text), .reconnecting(let text), .failed(let text): return text
        case .stopping: return "Restoring the real location…"
        case .idle, .active, .replaying: return nil
        }
    }

    static func describe(_ request: LocationRequest) -> String {
        let coordinate = String(format: "%.5f, %.5f", request.latitude, request.longitude)
        if let name = request.name, !name.isEmpty { return "\(name) (\(coordinate))" }
        return coordinate
    }

    // MARK: - Helpers

    private func beginKeepAwake() {
        guard keepAwake == nil else { return }
        keepAwake = ProcessInfo.processInfo.beginActivity(
            options: [.idleSystemSleepDisabled, .suddenTerminationDisabled],
            reason: "Holding a simulated iPhone location")
    }

    private func endKeepAwake() {
        guard let activity = keepAwake else { return }
        ProcessInfo.processInfo.endActivity(activity)
        keepAwake = nil
    }

    private func log(_ level: LogLevel, _ message: String) {
        onLog?(level, message)
    }

    private func onQueue<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async { continuation.resume(returning: body()) }
        }
    }

    private func onQueueThrowing<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { continuation.resume(with: Result { try body() }) }
        }
    }
}
