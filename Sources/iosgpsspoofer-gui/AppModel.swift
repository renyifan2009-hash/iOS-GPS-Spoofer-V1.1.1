import AppKit
import CoreLocation
import Foundation
import Observation
import SpooferCore

struct LogEntry: Identifiable, Equatable {
    let id = UUID()
    let date: Date
    let level: LogLevel
    let text: String
}

struct Waypoint: Identifiable, Equatable, Codable {
    var id = UUID()
    var point: GeoPoint
}

/// A one-shot request for the map to move its camera.
struct MapFocusRequest: Equatable {
    enum Kind: Equatable {
        case point(GeoPoint, zoomIn: Bool)
        case fit([GeoPoint])
    }
    let id = UUID()
    let kind: Kind
}

@MainActor
@Observable
final class AppModel {
    static let shared = AppModel()

    enum Mode: String, CaseIterable, Identifiable {
        case teleport, route, joystick
        var id: String { rawValue }
        var label: String {
            switch self {
            case .teleport: return "Teleport"
            case .route: return "Route"
            case .joystick: return "Joystick"
            }
        }
        var symbolName: String {
            switch self {
            case .teleport: return "mappin.and.ellipse"
            case .route: return "point.topleft.down.to.point.bottomright.curvepath"
            case .joystick: return "gamecontroller"
            }
        }
    }

    /// What the device is doing in the current session.
    enum Activity: Equatable { case none, holding, routing, joystick }

    enum EngineStatus: Equatable {
        case checking
        case live(version: String)
        case classicOnly(reason: String)
    }

    enum DirectionsState: Equatable {
        case idle, computing
        case partial(failedLegs: Int)
    }

    enum RoutePacing: String, CaseIterable, Identifiable {
        case speed, time
        var id: String { rawValue }
        var label: String { self == .speed ? "Speed" : "Duration" }
    }

    // MARK: Tooling
    var pmd: Pymobiledevice3?
    var setupError: String?
    var pymobiledevice3Version: String?
    var engineStatus: EngineStatus = .checking
    @ObservationIgnored var probeTask: Task<LiveHelper.Availability, Never>?

    // MARK: Devices
    var devices: [Device] = []
    var selectedUDID: String?
    var isRefreshing = false
    var hasRefreshedOnce = false

    // MARK: Mode & teleport target
    var mode: Mode = .teleport {
        didSet {
            guard mode != oldValue else { return }
            UserDefaults.standard.set(mode.rawValue, forKey: StateKey.mode)
            fitMap()
        }
    }
    var latitudeText = "37.334900" { didSet { if latitudeText != oldValue { targetTextChanged() } } }
    var longitudeText = "-122.009000" { didSet { if longitudeText != oldValue { targetTextChanged() } } }
    /// Reverse-geocoded name of the target.
    var placeName: String?
    /// Name supplied by a search / favorite (wins over `placeName`).
    var targetName: String?

    // MARK: Session
    var session: SpoofSession?
    var sessionState: SessionState = .idle
    var sessionEngine: EngineKind?
    var activity: Activity = .none
    var isStarting = false
    @ObservationIgnored var startCancelled = false
    var devicePosition: GeoPoint?
    var deviceHeading: Double?
    /// Current movement speed, m/s.
    var deviceSpeed: Double = 0
    var devicePlaceName: String?
    var sessionStartedAt: Date?

    // MARK: Route
    var waypoints: [Waypoint] = [] { didSet { if waypoints != oldValue { routeInputsChanged() } } }
    var followRoads = false { didSet { if followRoads != oldValue { routeInputsChanged() } } }
    var travelMode: TravelMode = .walking { didSet { if travelMode != oldValue { routeInputsChanged() } } }
    var loopMode: LoopMode = .once { didSet { saveRouteDraft() } }
    var pacing: RoutePacing = .speed { didSet { saveRouteDraft() } }
    /// m/s, when pacing by speed.
    var routeSpeed: Double = 1.4 { didSet { saveRouteDraft() } }
    /// Seconds for one pass, when pacing by duration.
    var routeDuration: TimeInterval = 600 { didSet { saveRouteDraft() } }
    /// Name of the route being edited (from the library or an imported file).
    var routeName: String?
    /// Library entry the route was loaded from, so "Save" updates it.
    var savedRouteID: UUID?
    /// The polyline actually followed: straight lines or road-following legs.
    var routeGeometry: [GeoPoint] = []
    var directionsState: DirectionsState = .idle
    var playback: RoutePlayback?
    var isPaused = false
    @ObservationIgnored var playbackSignature: String?
    @ObservationIgnored var replayStartedAt: Date?
    @ObservationIgnored var replaySpeed: Double = 1.4
    @ObservationIgnored var announcedArrival = false

    // MARK: Joystick
    /// On-screen pad deflection, x right / y up, magnitude ≤ 1.
    var padVector: CGVector = .zero
    var pressedKeys: Set<UInt16> = []
    var sprinting = false

    // MARK: Map & UI
    var mapFocus: MapFocusRequest?
    /// The map camera's heading (degrees), so the joystick's "up" is screen-up.
    var mapHeading: Double = 0
    var searchFocusRequest = 0
    var showInspector = true

    // MARK: Log
    var log: [LogEntry] = []

    // MARK: Internals
    @ObservationIgnored var refreshTask: Task<Void, Never>?
    @ObservationIgnored var motionTask: Task<Void, Never>?
    @ObservationIgnored var geocodeTask: Task<Void, Never>?
    @ObservationIgnored var directionsTask: Task<Void, Never>?
    @ObservationIgnored var lastTick: ContinuousClock.Instant?
    @ObservationIgnored var speedNoise = 0.0
    @ObservationIgnored var keyMonitor: Any?
    @ObservationIgnored var resignObserver: NSObjectProtocol?
    @ObservationIgnored let geocoder = CLGeocoder()
    @ObservationIgnored let deviceGeocoder = CLGeocoder()
    @ObservationIgnored var lastDeviceGeocode: (point: GeoPoint, date: Date)?
    @ObservationIgnored var didBootstrap = false
    @ObservationIgnored var restoring = false
    @ObservationIgnored var autoStart: GeoPoint?
    @ObservationIgnored var didAutoStart = false
    @ObservationIgnored var startupSweepDone = false

    enum StateKey {
        static let mode = "lastMode"
        static let target = "lastTarget"
        static let routeDraft = "routeDraft"
    }

    var prefs: Preferences { Preferences.shared }
    var library: LibraryStore { LibraryStore.shared }

    private init() {
        // Keep this trivial: it runs during the first SwiftUI body evaluation.
        // Everything else happens in `bootstrap()`.
        let env = ProcessInfo.processInfo.environment
        if let s = env["SPOOF_START"], let p = Coordinate.parsePoint(s), p.isValid { autoStart = p }
        if let udid = env["SPOOF_UDID"] { selectedUDID = udid }
        resolveTool()
    }

    /// Restore state, probe the engine, start watching devices. Idempotent.
    func bootstrap() {
        guard !didBootstrap else { return }
        didBootstrap = true
        restoreState()
        if let autoStart { setTarget(autoStart) }
        routeInputsChanged()
        startEngineProbe()
        startAutoRefresh()
        installKeyboardMonitor()
        scheduleGeocode()
        fitMap()
    }

    /// Called from `applicationDidFinishLaunching` once stray children are reaped.
    func completeStartupSweep(reaped: Int) {
        startupSweepDone = true
        if reaped > 0 {
            appendLog("Cleaned up \(reaped) leftover pymobiledevice3 process(es) from a previous run.", level: .info)
        }
    }

    // MARK: - Tooling

    func resolveTool() {
        let explicit = Preferences.shared.pymobiledevice3Path
        do {
            pmd = try Pymobiledevice3.resolve(explicit: explicit.isEmpty ? nil : explicit)
            setupError = nil
        } catch {
            pmd = nil
            setupError = "\(error)"
        }
        if didBootstrap { startEngineProbe() }
    }

    func startEngineProbe() {
        guard let pmd else {
            probeTask = nil
            engineStatus = .classicOnly(reason: "pymobiledevice3 not found")
            pymobiledevice3Version = nil
            return
        }
        engineStatus = .checking
        let task = Task.detached(priority: .utility) { () -> LiveHelper.Availability in
            LiveHelper.probe(python: pmd.pythonInterpreter)
        }
        probeTask = task
        Task { [weak self] in
            let result = await task.value
            guard let self, self.probeTask == task else { return }
            if case .checking = self.engineStatus { self.applyProbe(result) }
        }
        Task.detached(priority: .utility) {
            let version = pmd.version()
            await MainActor.run { AppModel.shared.pymobiledevice3Version = version }
        }
    }

    func applyProbe(_ availability: LiveHelper.Availability) {
        switch availability {
        case .supported(let version):
            engineStatus = .live(version: version)
            appendLog("Live engine ready (pymobiledevice3 \(version)).", level: .debug)
        case .unsupported(let reason):
            engineStatus = .classicOnly(reason: reason)
            appendLog("Live engine unavailable — using the classic engine. (\(reason))", level: .warning)
        }
    }

    /// The engine a new session should use, waiting for the probe if needed.
    func resolvedEngine() async -> EngineKind {
        if prefs.enginePreference == .classic { return .classic }
        if case .checking = engineStatus, let probeTask {
            applyProbe(await probeTask.value)
        }
        if case .live = engineStatus { return .live }
        return .classic
    }

    // MARK: - Devices

    var selectedDevice: Device? {
        devices.first { $0.udid == selectedUDID }
            ?? (session?.device.udid == selectedUDID ? session?.device : nil)
    }

    /// The device being spoofed, else the selected one.
    var activeDevice: Device? { session?.device ?? selectedDevice }

    struct SidebarDevice: Identifiable {
        let device: Device
        let connected: Bool
        var id: String { device.udid }
    }

    /// Connected devices, plus the session's device if it's currently missing.
    var sidebarDevices: [SidebarDevice] {
        var rows = devices.map { SidebarDevice(device: $0, connected: true) }
        if let d = session?.device, !devices.contains(where: { $0.udid == d.udid }) {
            rows.append(SidebarDevice(device: d, connected: false))
        }
        return rows
    }

    func startAutoRefresh() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.refresh()
                let interval = self?.prefs.autoRefreshInterval ?? 3
                try? await Task.sleep(for: .seconds(interval))
            }
        }
    }

    func refresh() async {
        guard let pmd, !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false; hasRefreshedOnce = true }
        do {
            let list = try await pmd.listDevicesAsync()
            if list != devices { devices = list }
            let keepSelection = session?.device.udid == selectedUDID && selectedUDID != nil
            if !keepSelection, selectedUDID == nil || !list.contains(where: { $0.udid == selectedUDID }) {
                selectedUDID = list.first?.udid
            }
        } catch {
            appendLog("Device refresh failed: \(SpoofSession.firstLine(of: error))", level: .debug)
        }

        if let autoStart, startupSweepDone, !didAutoStart, session == nil, selectedDevice != nil {
            didAutoStart = true
            teleport(to: autoStart, name: nil)
        }
    }

    // MARK: - Session lifecycle

    var hasSession: Bool { session != nil || isStarting }
    var isEngaged: Bool { sessionState.isEngaged }
    var canStream: Bool { session?.canStream ?? false }

    /// Return the running session, or create one (deciding the engine first).
    /// `requireStreaming` refuses to create a classic iOS 17+ session, which
    /// can't do real-time movement.
    func obtainSession(requireStreaming: Bool) async -> (session: SpoofSession, isNew: Bool)? {
        if let session {
            if requireStreaming && !session.canStream { warnStreamingUnavailable(); return nil }
            return (session, false)
        }
        guard !isStarting else { return nil }
        guard pmd != nil else {
            appendLog("pymobiledevice3 wasn't found — see the setup instructions.", level: .error)
            return nil
        }
        guard let device = selectedDevice else {
            appendLog("Connect and select an iPhone first.", level: .warning)
            return nil
        }
        isStarting = true
        startCancelled = false
        sessionState = .connecting("Checking the live engine…")
        let engine = await resolvedEngine()
        isStarting = false
        if startCancelled {
            sessionState = .idle
            return nil
        }
        if let session { return (session, false) }
        if requireStreaming && engine == .classic && !device.isLegacy {
            sessionState = .idle
            warnStreamingUnavailable()
            return nil
        }
        guard let s = makeSession(device: device, engine: engine) else {
            sessionState = .idle
            return nil
        }
        session = s
        sessionEngine = s.engine
        sessionStartedAt = Date()
        devicePosition = nil
        devicePlaceName = nil
        startMotionLoop()
        let how = device.isLegacy ? "lockdown service" : prefs.transport.label
        appendLog("Starting a \(s.engine.label.lowercased())-engine session on \(device.deviceName) (\(device.modelName), iOS \(device.productVersion), \(how)).", level: .info)
        return (s, true)
    }

    private func warnStreamingUnavailable() {
        appendLog("That needs the live engine, which isn't available with this pymobiledevice3. Check Settings ▸ Engine.", level: .warning)
    }

    private func makeSession(device: Device, engine: EngineKind) -> SpoofSession? {
        guard let pmd else { return nil }
        let s = SpoofSession(pmd: pmd, device: device, transport: prefs.transport, engine: engine,
                             python: engine == .live ? pmd.pythonInterpreter : nil)
        let id = ObjectIdentifier(s)
        s.onStateChange = { [weak self] state in
            MainActor.assumeIsolated { self?.sessionStateChanged(state, id: id) }
        }
        s.onLog = { [weak self] level, line in
            MainActor.assumeIsolated { self?.appendLog(line, level: level) }
        }
        s.onPosition = { [weak self] point in
            MainActor.assumeIsolated { self?.positionApplied(point, id: id) }
        }
        s.onEngineChange = { [weak self] engine in
            MainActor.assumeIsolated { self?.engineChanged(engine, id: id) }
        }
        return s
    }

    private func isCurrentSession(_ id: ObjectIdentifier) -> Bool {
        guard let session else { return false }
        return ObjectIdentifier(session) == id
    }

    private func sessionStateChanged(_ state: SessionState, id: ObjectIdentifier) {
        guard isCurrentSession(id) else { return }
        let previous = sessionState
        sessionState = state
        switch state {
        case .idle:
            endSession()
        case .replaying:
            if previous != .replaying { replayStartedAt = Date() }
        case .reconnecting, .failed:
            deviceSpeed = 0
        default:
            break
        }
    }

    private func positionApplied(_ point: GeoPoint, id: ObjectIdentifier) {
        guard isCurrentSession(id) else { return }
        // While streaming movement, the motion loop already shows where we sent
        // the device; acknowledgements would make the marker lag behind.
        let streaming = (activity == .routing || activity == .joystick) && canStream
        if !streaming || devicePosition == nil {
            devicePosition = point
        }
        geocodeDeviceIfNeeded()
    }

    private func engineChanged(_ engine: EngineKind, id: ObjectIdentifier) {
        guard isCurrentSession(id) else { return }
        sessionEngine = engine
        if case .live = engineStatus {
            engineStatus = .classicOnly(reason: "the live helper failed on this device")
        }
        guard let session, !session.canStream else { return }
        switch activity {
        case .routing:
            appendLog("Restarting the route with the classic engine…", level: .info)
            startRoute()
        case .joystick:
            activity = .holding
            appendLog("Joystick control needs the live engine; holding the current position.", level: .warning)
        default:
            break
        }
    }

    private func endSession() {
        session = nil
        sessionEngine = nil
        activity = .none
        playback = nil
        isPaused = false
        devicePosition = nil
        deviceHeading = nil
        deviceSpeed = 0
        devicePlaceName = nil
        sessionStartedAt = nil
        sessionState = .idle
        pressedKeys.removeAll()
        padVector = .zero
        stopMotionLoop()
    }

    /// Stop everything and restore the real location.
    func stop() {
        if isStarting { startCancelled = true }
        guard let session else { return }
        activity = .none
        playback = nil
        isPaused = false
        deviceSpeed = 0
        padVector = .zero
        pressedKeys.removeAll()
        appendLog("Stopping — restoring the real location…", level: .info)
        session.stop()
    }

    /// The big button: start whatever the current mode does, or stop.
    func primaryAction() {
        if hasSession { stop(); return }
        switch mode {
        case .teleport: teleportToTarget()
        case .route: startRoute()
        case .joystick: startJoystick()
        }
    }

    var canStart: Bool {
        guard pmd != nil, selectedDevice != nil, !isStarting else { return false }
        switch mode {
        case .teleport, .joystick: return target != nil || devicePosition != nil
        case .route: return routeGeometry.count >= 2 && effectiveRouteSpeed > 0
        }
    }

    // MARK: - Teleport

    /// The typed/picked teleport destination, if valid.
    var target: GeoPoint? {
        guard let lat = Double(latitudeText.trimmingCharacters(in: .whitespaces)),
              let lon = Double(longitudeText.trimmingCharacters(in: .whitespaces)) else { return nil }
        let p = GeoPoint(lat, lon)
        return p.isValid ? p : nil
    }

    var targetLabel: String? { targetName ?? placeName }

    /// The device is somewhere other than the target (offer "Move here").
    var targetDiffersFromDevice: Bool {
        guard let target, let devicePosition else { return target != nil }
        return Geo.distance(target, devicePosition) > 0.5
    }

    func setTarget(_ point: GeoPoint, name: String? = nil, focus: Bool = false) {
        latitudeText = String(format: "%.6f", point.latitude)
        longitudeText = String(format: "%.6f", point.longitude)
        targetName = name
        if focus { self.focus(on: point) }
    }

    private func targetTextChanged() {
        targetName = nil
        scheduleGeocode()
        if !restoring, let t = target {
            UserDefaults.standard.set("\(t.latitude),\(t.longitude)", forKey: StateKey.target)
        }
    }

    func teleportToTarget() {
        guard let point = target else {
            appendLog("Enter a valid latitude (−90…90) and longitude (−180…180).", level: .warning)
            return
        }
        teleport(to: point, name: targetLabel)
    }

    /// Move the device to `point` — starting a session if needed.
    func teleport(to point: GeoPoint, name: String?) {
        guard point.isValid else { return }
        playback = nil
        isPaused = false
        if let session {
            if let from = devicePosition {
                let jump = Geo.distance(from, point)
                if jump > 1 { appendLog("Teleporting \(Format.distance(jump, units: prefs.units)) to \(name ?? Format.coordinate(point)).", level: .info) }
            }
            session.move(to: point)
            activity = .holding
            deviceSpeed = 0
            deviceHeading = nil
            if session.canStream { devicePosition = point }
            recordRecent(point, name: name)
            return
        }
        Task {
            guard let obtained = await obtainSession(requireStreaming: false) else { return }
            if obtained.isNew { obtained.session.start(at: point) } else { obtained.session.move(to: point) }
            activity = .holding
            recordRecent(point, name: name)
        }
    }

    func recordRecent(_ point: GeoPoint, name: String?) {
        guard prefs.recordRecents else { return }
        let isTarget = target.map { $0.isClose(to: point, tolerance: 1e-6) } ?? false
        let label = name ?? (isTarget ? targetLabel : nil)
        library.recordRecent(name: label ?? Format.coordinate(point, precision: 4), point: point)
    }

    // MARK: - Map

    func focus(on point: GeoPoint, zoomIn: Bool = false) {
        mapFocus = MapFocusRequest(kind: .point(point, zoomIn: zoomIn))
    }

    /// Frame whatever matters in the current mode.
    func fitMap() {
        var points: [GeoPoint] = []
        switch mode {
        case .teleport, .joystick:
            if let target { points.append(target) }
        case .route:
            points += waypoints.map(\.point)
        }
        if let devicePosition { points.append(devicePosition) }
        if points.count > 1 {
            mapFocus = MapFocusRequest(kind: .fit(points))
        } else if let p = points.first {
            mapFocus = MapFocusRequest(kind: .point(p, zoomIn: false))
        }
    }

    /// A map click, interpreted for the current mode.
    func mapClicked(_ point: GeoPoint) {
        switch mode {
        case .teleport:
            setTarget(point)
            if prefs.instantTeleport, session != nil, canStream { teleport(to: point, name: nil) }
        case .route:
            addWaypoint(point)
        case .joystick:
            if activity == .joystick, canStream {
                teleport(to: point, name: nil)
                activity = .joystick
            } else {
                setTarget(point)
            }
        }
    }

    // MARK: - Log

    func appendLog(_ text: String, level: LogLevel = .info) {
        log.append(LogEntry(date: Date(), level: level, text: text))
        if log.count > 1000 { log.removeFirst(log.count - 1000) }
    }

    func clearLog() { log.removeAll() }

    var logText: String {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss"
        return log.map { "[\(f.string(from: $0.date))] \($0.text)" }.joined(separator: "\n")
    }

    // MARK: - Geocoding

    /// Reverse-geocode the target into a place name (debounced).
    func scheduleGeocode() {
        geocodeTask?.cancel()
        guard let point = target else { placeName = nil; return }
        geocodeTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            guard !Task.isCancelled, let self else { return }
            self.placeName = await self.reverseGeocode(point, using: self.geocoder)
        }
    }

    /// Name the device's surroundings, at most every 10 s / 150 m.
    func geocodeDeviceIfNeeded() {
        guard let point = devicePosition else { return }
        if let last = lastDeviceGeocode {
            let moved = Geo.distance(last.point, point)
            let elapsed = Date().timeIntervalSince(last.date)
            // A teleport-sized jump renames at once; gradual movement is throttled.
            guard moved >= 2000 || (moved >= 150 && elapsed >= 10) else { return }
        }
        lastDeviceGeocode = (point, Date())
        Task { [weak self] in
            guard let self else { return }
            let name = await self.reverseGeocode(point, using: self.deviceGeocoder)
            if self.session != nil { self.devicePlaceName = name }
        }
    }

    private func reverseGeocode(_ point: GeoPoint, using geocoder: CLGeocoder) async -> String? {
        if geocoder.isGeocoding { geocoder.cancelGeocode() }
        do {
            let placemarks = try await geocoder.reverseGeocodeLocation(
                CLLocation(latitude: point.latitude, longitude: point.longitude))
            guard let p = placemarks.first else { return nil }
            var seen = Set<String>()
            let parts = [p.name, p.locality, p.administrativeArea, p.country]
                .compactMap { $0 }
                .filter { seen.insert($0).inserted }
            return parts.prefix(3).joined(separator: ", ")
        } catch {
            return nil   // over water, offline, or rate-limited
        }
    }

    // MARK: - Persistence

    private func restoreState() {
        restoring = true
        defer { restoring = false }
        let d = UserDefaults.standard
        if let m = d.string(forKey: StateKey.mode).flatMap(Mode.init(rawValue:)) { mode = m }
        if let s = d.string(forKey: StateKey.target), let p = Coordinate.parsePoint(s), p.isValid {
            latitudeText = String(format: "%.6f", p.latitude)
            longitudeText = String(format: "%.6f", p.longitude)
        }
        routeSpeed = prefs.defaultRouteSpeed
        if let data = d.data(forKey: StateKey.routeDraft),
           let draft = try? JSONDecoder().decode(RouteDraft.self, from: data) {
            waypoints = draft.waypoints.map { Waypoint(point: $0) }
            followRoads = draft.followRoads
            travelMode = draft.travelMode
            loopMode = draft.loopMode
            pacing = draft.pacing.flatMap(RoutePacing.init(rawValue:)) ?? .speed
            if draft.speed > 0 { routeSpeed = draft.speed }
            if draft.duration > 0 { routeDuration = draft.duration }
        }
    }

    struct RouteDraft: Codable {
        var waypoints: [GeoPoint]
        var followRoads: Bool
        var travelMode: TravelMode
        var loopMode: LoopMode
        var pacing: String?
        var speed: Double
        var duration: Double
    }

    func saveRouteDraft() {
        guard !restoring else { return }
        let draft = RouteDraft(waypoints: waypoints.map(\.point), followRoads: followRoads, travelMode: travelMode,
                               loopMode: loopMode, pacing: pacing.rawValue, speed: routeSpeed, duration: routeDuration)
        if let data = try? JSONEncoder().encode(draft) {
            UserDefaults.standard.set(data, forKey: StateKey.routeDraft)
        }
    }
}

extension Duration {
    var inSeconds: Double {
        Double(components.seconds) + Double(components.attoseconds) * 1e-18
    }
}
