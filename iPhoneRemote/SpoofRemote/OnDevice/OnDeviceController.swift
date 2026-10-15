import CoreLocation
import Foundation
import Network
import Observation
import PhoneOnlyCore

/// The iPhone-only mode: this app changes this iPhone's location by itself,
/// with no Mac, once it has the pairing file (see docs/PHONE-ONLY.md).
@MainActor
@Observable
final class OnDeviceController {
    enum Phase: Equatable {
        case idle
        case connecting
        case stopping
        case active
    }

    private(set) var phase: Phase = .idle
    private(set) var pairing: PairingFile?
    /// Which of this iPhone's developer ports answer through LocalDevVPN. Nil
    /// until checked.
    private(set) var ports: DeveloperPorts?
    private(set) var checkingLoopback = false
    /// Where this iPhone is held, while active.
    private(set) var current: CLLocationCoordinate2D?
    private(set) var currentName: String?
    private(set) var lastError: String?
    /// The small print under `lastError`: the step, the route and idevice's
    /// own words, for a bug report. Nil when there's nothing to add.
    private(set) var lastErrorDetail: String?
    /// Why the last pairing file was turned down, in plain words. The setup
    /// screen shows it right beside the Choose File button. It is kept apart
    /// from `lastError`, which every connection attempt writes over.
    private(set) var importError: String?
    /// How many files have been turned down. The screen gives a cue each time,
    /// even when the same message comes up again.
    private(set) var importFailures = 0
    /// The name and day of the stored pairing file, when known. A file stored
    /// by an older version has none. A reinstall keeps the Keychain item, so
    /// this is what tells the person which file they still have.
    private(set) var pairingSource: PairingFileSource? = PairingFile.loadSource()

    var isSetUp: Bool { pairing != nil }
    var isSpoofing: Bool { phase == .active }
    var isWorking: Bool { phase == .connecting || phase == .stopping }

    /// Whether LocalDevVPN routes this iPhone's own address back to it. Nil
    /// until checked.
    var loopbackReachable: Bool? { ports?.anyAnswered }

    /// LocalDevVPN is on, but this iPhone only answers Remote Pairing and the
    /// pairing file was saved without that identity. A new file fixes it.
    var pairingFileIsTooOld: Bool {
        guard let pairing, let ports else { return false }
        return TunnelPlan.readiness(for: pairing.record, ports: ports, allowLockdown: Self.allowLockdown) == .fileLacksRemotePairing
    }

    /// Remote Pairing is attempted on iOS 17+. CoreDeviceProxy fallback is 17.4+ only.
    /// Eligibility is not a claim that every device/OS build has passed a hardware test.
    static let isSupported = ProcessInfo.processInfo.isOperatingSystemAtLeast(
        OperatingSystemVersion(majorVersion: 17, minorVersion: 0, patchVersion: 0))
    private static let allowLockdown = ProcessInfo.processInfo.isOperatingSystemAtLeast(
        OperatingSystemVersion(majorVersion: 17, minorVersion: 4, patchVersion: 0))
    private(set) var developerImageBuild: String? = UserDefaults.standard.string(forKey: "developerImageBuild")
    private(set) var importingDeveloperImage = false
    private(set) var developerImageError: String?
    private(set) var isUpdatingLocation = false
    @ObservationIgnored private var heartbeat: Task<Void, Never>?
    @ObservationIgnored private var stopTask: Task<Bool, Never>?

    static let pairingFileTooOldMessage = "This pairing file can't be used on this iPhone's iOS. On your Mac, plug this iPhone "
        + "in by cable, unlock it, and choose File ▸ Pairing File for the iPhone App… again. Then open the new file here. "
        + "If it still fails, update AnyWhere on the Mac first."

    private let engine: any OnDeviceOperations
    private let keepAlive: any BackgroundHolding
    @ObservationIgnored private let developerPortProbe: (@Sendable () async -> DeveloperPorts)?
    @ObservationIgnored private let recoveryDelay: Duration
    @ObservationIgnored private let heartbeatInterval: Duration
    /// Counts calls to `stop()`. A `set` that was still running when one came
    /// in must not put its location back on screen: the stop cleared it.
    @ObservationIgnored private var stops = 0

    // Swift 6.1 crashes while lowering actor-isolated default arguments in the App's @State
    // initializer. Construct production dependencies here; test injection remains explicit.
    convenience init() {
        self.init(engine: OnDeviceEngine(), pairing: PairingFile.load(), keepAlive: KeepAlive())
    }

    init(engine: any OnDeviceOperations, pairing: PairingFile?, keepAlive: any BackgroundHolding,
         developerPortProbe: (@Sendable () async -> DeveloperPorts)? = nil,
         heartbeatInterval: Duration = .seconds(15), recoveryDelay: Duration = .seconds(2)) {
        self.engine = engine
        self.pairing = pairing
        self.keepAlive = keepAlive
        self.developerPortProbe = developerPortProbe
        self.heartbeatInterval = heartbeatInterval
        self.recoveryDelay = recoveryDelay
        engine.onAbandonedCallEnded { [weak self] in
            Task { @MainActor in await self?.holdAgain() }
        }
    }

    // MARK: Pairing file

    func importDeveloperImage(from url: URL) async {
        guard phase == .idle, !importingDeveloperImage else { return }
        importingDeveloperImage = true
        developerImageError = nil
        defer { importingDeveloperImage = false }
        do {
            let bundle = try await Task.detached(priority: .userInitiated) {
                try DeveloperImageStore.importFolder(url)
            }.value
            developerImageBuild = bundle.build
            UserDefaults.standard.set(bundle.build, forKey: "developerImageBuild")
        } catch { developerImageError = error.localizedDescription }
    }

    /// Import a pairing file from Files, AirDrop or "Open in". On success the
    /// file is in the Keychain and the copy iOS made for this app is deleted.
    /// On failure `importError` says why.
    @discardableResult
    func importPairingFile(from url: URL) -> Bool {
        importError = nil
        let file: PairingFile
        do {
            file = try PairingFile(contentsOf: url)
        } catch {
            let problem = error as? PairingFile.Problem
            // A file that was read and turned down is no use in the Inbox.
            if problem?.rejectsTheFile == true { Self.discardInboxCopy(of: url) }
            failImport(error.localizedDescription)
            return false
        }
        let source = PairingFileSource(fileName: url.lastPathComponent, importedAt: Date())
        guard file.save(source: source) else {
            // Kept in the Inbox, so that trying again has a file to use.
            failImport("Couldn't keep the pairing file in the Keychain. Try again.")
            return false
        }
        // The Keychain has it now. The copy in the Inbox holds the same
        // private keys in plain view, in a folder that is backed up.
        Self.discardInboxCopy(of: url)
        // A renewal of the file this one replaces has nothing to add.
        _ = engine.takeRenewedPairing()
        pairing = file
        pairingSource = source
        clearError()
        return true
    }

    /// The file picker failed before there was a file to read.
    func reportImportFailure(_ error: Error) {
        // Closing the picker without choosing is not a failure.
        if (error as? CocoaError)?.code == .userCancelled { return }
        failImport("Couldn't open that file: \(error.localizedDescription)")
    }

    func clearImportError() {
        importError = nil
    }

    private func failImport(_ message: String) {
        importError = message
        importFailures += 1
    }

    func removePairingFile() {
        Task {
            await stop()
            _ = engine.takeRenewedPairing()
            PairingFile.delete()
            pairing = nil
            pairingSource = nil
            importError = nil
            // Copies left by earlier imports go with it.
            Self.discardInboxCopies()
        }
    }

    /// Delete the pairing files left in the Inbox, when the Keychain holds one.
    /// Copies from before this version, or from an import that was stopped,
    /// can be there. Called when the app goes to the background, never at
    /// launch: a file opened from AirDrop arrives at launch, and is still
    /// being read.
    func sweepInbox() {
        guard isSetUp, importError == nil else { return }
        Self.discardInboxCopies()
    }

    private static var documents: URL? {
        try? FileManager.default.url(for: .documentDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
    }

    private static func discardInboxCopy(of url: URL) {
        guard let documents else { return }
        InboxCopy.discard(url, documents: documents)
    }

    private static func discardInboxCopies() {
        guard let documents else { return }
        InboxCopy.discardPairingFiles(documents: documents)
    }

    /// While connecting, the iPhone asked to pair again and idevice did: the
    /// identity in the file changed. Keep the new one, or every connection
    /// from now on would ask again. The engine can hold one from a call that
    /// had already timed out (Trust tapped late), so this also runs before
    /// the next connection.
    private func adoptRenewedPairing() {
        guard let renewed = engine.takeRenewedPairing(), pairing != nil else { return }
        let file = PairingFile(record: renewed)
        pairing = file
        file.save()
    }

    // MARK: LocalDevVPN

    @ObservationIgnored private var loopbackCheck: Task<Void, Never>?
    /// remotepairingd's port when it isn't the usual one. Bonjour names it,
    /// and it's kept between launches for as long as it works.
    @ObservationIgnored private var remotePairingPort = RemotePairingPort.remembered

    /// Check now, or wait for the check already running. Either way `ports`
    /// is up to date when this returns: the check itself stores the result,
    /// so whoever waits for it sees it.
    func checkLoopback() async {
        if let running = loopbackCheck {
            await running.value
            return
        }
        checkingLoopback = true
        let known = remotePairingPort
        let check = Task { @MainActor in
            let findings: LoopbackProbe.Findings
            if let probe = self.developerPortProbe {
                findings = LoopbackProbe.Findings(ports: await probe(), remotePairingPort: nil)
            } else {
                findings = await LoopbackProbe.developerPorts(knownRemotePairingPort: known)
            }
            self.ports = findings.ports
            if let port = findings.remotePairingPort { self.rememberRemotePairingPort(port) }
            self.loopbackCheck = nil
            self.checkingLoopback = false
        }
        loopbackCheck = check
        await check.value
    }

    private func rememberRemotePairingPort(_ port: UInt16?) {
        remotePairingPort = port
        RemotePairingPort.remembered = port
    }

    /// The routes that answered at the last check, or all the file allows if
    /// nothing was checked.
    private func knownRoutes(for record: PairingRecord) -> [TunnelRoute] {
        if let ports, case .ready(let routes) = TunnelPlan.readiness(for: record, ports: ports,
                                                                  allowLockdown: Self.allowLockdown) { return routes }
        return TunnelPlan.routes(for: record, discoveredPort: remotePairingPort, allowLockdown: Self.allowLockdown)
    }

    // MARK: The location

    /// Start holding `coordinate`, or move there if already holding one.
    @discardableResult
    func set(_ coordinate: CLLocationCoordinate2D, name: String?) async -> Bool {
        guard CLLocationCoordinate2DIsValid(coordinate), !importingDeveloperImage, !isUpdatingLocation else { return false }
        adoptRenewedPairing()
        guard let pairing else {
            show("Set up this iPhone first: it needs the pairing file from your Mac.")
            return false
        }
        guard phase != .connecting, phase != .stopping else { return false }
        isUpdatingLocation = true
        defer { isUpdatingLocation = false }
        let stopsBefore = stops
        let moving = phase == .active
        let routes: [TunnelRoute]
        if moving {
            // The channel is open and a move just uses it. These are for the
            // engine to connect again by, if the channel has dropped.
            routes = knownRoutes(for: pairing.record)
        } else {
            phase = .connecting
            // Without LocalDevVPN the connection would wait a long time
            // before failing, so check first; it takes a moment.
            await checkLoopback()
            // A cellular/Wi-Fi transition can temporarily remove the VPN route.
            if ports?.anyAnswered != true {
                do { try await Task.sleep(for: recoveryDelay) } catch { return giveUp(nil) }
                guard stops == stopsBefore else { return false }
                await checkLoopback()
            }
            guard stops == stopsBefore else { return false }
            switch TunnelPlan.readiness(for: pairing.record, ports: ports ?? DeveloperPorts(),
                                        allowLockdown: Self.allowLockdown) {
            case .ready(let ready):
                routes = ready
            case .nothingAnswers:
                return giveUp(TunnelFailure.unreachableExplanation)
            case .fileLacksRemotePairing:
                return giveUp(Self.pairingFileTooOldMessage)
            case .remotePairingDoesNotAnswer:
                return giveUp("Can't find this iPhone's pairing service. Turn LocalDevVPN off and on, then try again.")
            }
            // Before the connection, so iOS doesn't suspend the app halfway.
            keepAlive.start()
        }
        do {
            try await connectWithRecovery(coordinate, pairing: pairing.record, routes: routes,
                                          stopsBefore: stopsBefore)
            adoptRenewedPairing()
            settleRemotePairingPort()
            // Stopped meanwhile (Stop, or the pairing file removed): the stop
            // clears the location after this, and the screen is its to set.
            guard stops == stopsBefore else { return false }
            // Again, in case a move that failed meanwhile ended it.
            keepAlive.start()
            phase = .active
            current = coordinate
            currentName = name
            clearError()
            startHeartbeat()
            return true
        } catch {
            // The pairing may have been renewed before a later step failed.
            adoptRenewedPairing()
            guard stops == stopsBefore else { return false }
            // A remembered port that no longer leads anywhere would be tried
            // first every time. Forget it: Bonjour is asked again if needed.
            if remotePairingPort != nil { rememberRemotePairingPort(nil) }
            show(error)
            if moving, error is OnDeviceEngine.TimedOut {
                // The call that's stuck still has the connection, and the
                // location with it, until it returns.
                lastError = "Moving took too long, so AnyWhere stopped. This iPhone may keep the last location "
                    + "for a while. If it stays, close AnyWhere and open it again."
            }
            return giveUp(nil)
        }
    }

    /// Retry only transport failures, with fresh discovery. Never retry pairing/image failures
    /// or restart a location after Stop. Persistent loss still ends the session visibly.
    private func connectWithRecovery(_ coordinate: CLLocationCoordinate2D, pairing: PairingRecord,
                                     routes: [TunnelRoute], stopsBefore: Int) async throws {
        var candidates = routes
        for attempt in 0...2 {
            do {
                try Task.checkCancellation()
                guard stops == stopsBefore else { throw CancellationError() }
                try await connect(coordinate, pairing: self.pairing?.record ?? pairing, routes: candidates)
                return
            } catch let failure as TunnelFailure {
                let failures = [failure] + failure.others
                guard attempt < 2, failures.allSatisfy({ $0.isUnreachable || $0.wasCutOff }),
                      stops == stopsBefore else { throw failure }
                lastError = "Developer connection interrupted. Retrying…"
                lastErrorDetail = failure.detail
                try await Task.sleep(for: recoveryDelay)
                guard stops == stopsBefore else { throw CancellationError() }
                rememberRemotePairingPort(nil)
                await checkLoopback()
                guard stops == stopsBefore else { throw CancellationError() }
                candidates = knownRoutes(for: self.pairing?.record ?? pairing)
            }
        }
    }

    private func connect(_ coordinate: CLLocationCoordinate2D, pairing: PairingRecord,
                         routes: [TunnelRoute]) async throws {
        do {
            try await engine.set(latitude: coordinate.latitude, longitude: coordinate.longitude,
                                 pairing: pairing, routes: routes, developerImage: DeveloperImageStore.directory)
        } catch let failure as TunnelFailure where failure.pointsAtAnotherPort {
            // remotepairingd may not be on the port tried: it's usually
            // 49152, but iOS doesn't promise that. Ask Bonjour, and try once
            // more if it names a port that wasn't tried.
            guard let port = await RemotePairingPort.find(),
                  !routes.contains(.remotePairing(port: port)) else { throw failure }
            // The first try may have paired again: use the file as it is now.
            adoptRenewedPairing()
            try await engine.set(latitude: coordinate.latitude, longitude: coordinate.longitude,
                                 pairing: self.pairing?.record ?? pairing, routes: [.remotePairing(port: port)],
                                 developerImage: DeveloperImageStore.directory)
        }
    }

    /// Remember the port the tunnel opened on, if it isn't the usual one.
    private func settleRemotePairingPort() {
        guard case .remotePairing(let port)? = engine.route else { return }
        let unusual = port == TunnelPlan.usualRemotePairingPort ? nil : port
        if unusual != remotePairingPort { rememberRemotePairingPort(unusual) }
    }

    /// A call the engine had stopped waiting for has ended and closed its
    /// connection. Every connection sets the same iPhone's location, so that
    /// may have changed or cleared the one held now: set it again.
    private func holdAgain() async {
        guard phase == .active, let current else { return }
        await set(current, name: currentName)
    }

    /// Back to the real location.
    @discardableResult
    func stop() async -> Bool {
        stops += 1
        heartbeat?.cancel()
        heartbeat = nil
        if let stopTask { return await stopTask.value }
        guard phase != .idle else { return true }
        phase = .stopping
        let clearing = Task { await engine.clear() }
        stopTask = clearing
        let cleared = await clearing.value
        stopTask = nil
        adoptRenewedPairing()
        keepAlive.stop()
        phase = .idle
        current = nil
        currentName = nil
        if !cleared {
            show("The connection didn't confirm Stop. If Maps still shows the simulated location, restart this iPhone.")
        }
        return cleared
    }

    private func startHeartbeat() {
        guard heartbeat == nil else { return }
        let interval = heartbeatInterval
        heartbeat = Task { [weak self] in
            while !Task.isCancelled {
                do { try await Task.sleep(for: interval) } catch { return }
                guard let self, self.phase == .active else { return }
                guard !self.isUpdatingLocation, let coordinate = self.current else { continue }
                _ = await self.set(coordinate, name: self.currentName)
            }
        }
    }

    // MARK: Errors

    /// Nothing is held (any more). With a message, also say why.
    private func giveUp(_ message: String?) -> Bool {
        heartbeat?.cancel()
        heartbeat = nil
        if let message { show(message) }
        phase = .idle
        current = nil
        currentName = nil
        keepAlive.stop()
        return false
    }

    private func show(_ message: String) {
        lastError = message
        lastErrorDetail = nil
    }

    /// Plain words for what went wrong, with idevice's own in the small print.
    private func show(_ error: Error) {
        if let failure = error as? TunnelFailure {
            lastError = failure.explanation
            lastErrorDetail = failure.detail
        } else {
            show(error.localizedDescription)
        }
    }

    private func clearError() {
        lastError = nil
        lastErrorDetail = nil
    }
}

/// Owns the simulator on one serial queue: its calls block while idevice
/// talks to the iPhone.
///
/// idevice's reads have no timeout, so a call can block for good: the iPhone
/// is asking to trust SpoofRemote and nobody answers, or LocalDevVPN went
/// away mid-handshake. So every call has a time limit, counted from when it
/// starts running. When it passes, the caller gets `TimedOut` and the engine
/// moves to a new queue (a "lane"). The stuck call keeps its old lane. If it
/// ever returns, it only closes what it had open, and whatever was waiting
/// behind it has already been told it failed.
protocol OnDeviceOperations: Sendable {
    var route: TunnelRoute? { get }
    func onAbandonedCallEnded(_ handler: @escaping @Sendable () -> Void)
    func takeRenewedPairing() -> PairingRecord?
    func set(latitude: Double, longitude: Double, pairing: PairingRecord, routes: [TunnelRoute], developerImage: URL?) async throws
    func clear() async -> Bool
}

final class OnDeviceEngine: OnDeviceOperations, @unchecked Sendable {
    struct TimedOut: LocalizedError {
        var errorDescription: String? {
            "Connecting took too long. Check that LocalDevVPN is connected, then try again. "
                + "If this iPhone asks whether to trust AnyWhere, tap Trust."
        }
    }

    /// Long enough to read and answer a Trust prompt.
    private static let connectTimeout: TimeInterval = 60
    private static let clearTimeout: TimeInterval = 10

    /// One call's continuation, resumed by whichever comes first: the work
    /// finishing, its time limit, or its lane being abandoned.
    private final class Attempt: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Void, Error>?

        init(_ continuation: CheckedContinuation<Void, Error>) {
            self.continuation = continuation
        }

        /// The caller has its answer already.
        var isFinished: Bool { lock.withLock { continuation == nil } }

        /// True for the first to call it: that result is the call's.
        func finish(_ result: Result<Void, Error>) -> Bool {
            let continuation = lock.withLock { () -> CheckedContinuation<Void, Error>? in
                defer { self.continuation = nil }
                return self.continuation
            }
            continuation?.resume(with: result)
            return continuation != nil
        }
    }

    /// A serial queue and the simulator it owns.
    private final class Lane: @unchecked Sendable {
        let queue = DispatchQueue(label: "com.iosgpsspoof.remote.on-device", qos: .userInitiated)
        /// Only touched on `queue`.
        var simulator: OnDeviceSimulator?

        private let lock = NSLock()
        /// Both guarded by `lock`. Calls on the queue that haven't started.
        private var waiting: [Attempt] = []
        private var abandoned = false

        /// False if the lane is abandoned: nothing put on its queue would run.
        func wait(_ attempt: Attempt) -> Bool {
            lock.withLock {
                if abandoned { return false }
                waiting.append(attempt)
                return true
            }
        }

        func started(_ attempt: Attempt) {
            lock.withLock { waiting.removeAll { $0 === attempt } }
        }

        /// The call running on this lane is stuck. Whatever waits behind it
        /// would wait for good, so it fails now.
        func abandon() {
            let stranded = lock.withLock { () -> [Attempt] in
                abandoned = true
                defer { waiting = [] }
                return waiting
            }
            for attempt in stranded { _ = attempt.finish(.failure(TimedOut())) }
        }
    }

    private let lock = NSLock()
    /// All guarded by `lock`.
    private var lane = Lane()
    private var renewedPairing: PairingRecord?
    private var liveRoute: TunnelRoute?
    private var abandonedCallEnded: (@Sendable () -> Void)?

    /// The pairing file with a new identity, if a connection since the last
    /// call had to pair again (see `OnDeviceSimulator.init`).
    func takeRenewedPairing() -> PairingRecord? {
        lock.withLock { () -> PairingRecord? in
            defer { self.renewedPairing = nil }
            return self.renewedPairing
        }
    }

    /// The route of the connection that holds the location, if there is one.
    var route: TunnelRoute? { lock.withLock { liveRoute } }

    /// Called when a call that timed out finally ends. It closes its
    /// connection then, and every connection sets the same iPhone's location.
    func onAbandonedCallEnded(_ handler: @escaping @Sendable () -> Void) {
        lock.withLock { abandonedCallEnded = handler }
    }

    func set(latitude: Double, longitude: Double, pairing: PairingRecord, routes: [TunnelRoute],
             developerImage: URL? = nil) async throws {
        let timeout = route == nil ? (developerImage == nil ? Self.connectTimeout : 180) : 10
        try await perform(timeout: timeout) { lane, gaveUp in
            if let simulator = lane.simulator {
                do {
                    try simulator.set(latitude: latitude, longitude: longitude)
                    return
                } catch {
                    // The connection dropped (LocalDevVPN restarted, the
                    // network changed): connect again, once.
                    simulator.close()
                    lane.simulator = nil
                    self.lock.withLock { self.liveRoute = nil }
                }
            }
            // If the caller has stopped waiting, a new connection now would
            // set a location behind its back.
            if gaveUp() { throw TimedOut() }
            let fresh = try OnDeviceSimulator(pairing: pairing, routes: routes, developerImage: developerImage) { renewed in
                self.lock.withLock { self.renewedPairing = renewed }
            }
            do {
                if gaveUp() { throw TimedOut() }
                try fresh.set(latitude: latitude, longitude: longitude)
            } catch {
                fresh.close()
                throw error
            }
            lane.simulator = fresh
            self.lock.withLock { self.liveRoute = fresh.route }
        }
    }

    func clear() async -> Bool {
        do {
            try await perform(timeout: Self.clearTimeout) { lane, _ in
                defer {
                    lane.simulator?.close()
                    lane.simulator = nil
                    self.lock.withLock { self.liveRoute = nil }
                }
                try lane.simulator?.clear()
            }
            return true
        } catch {
            return false
        }
    }

    /// Run `work` on the current lane. `work` gets the lane and a way to ask
    /// whether the caller has stopped waiting (the time limit passed).
    private func perform(timeout: TimeInterval,
                         _ work: @escaping @Sendable (Lane, () -> Bool) throws -> Void) async throws {
        let lane = lock.withLock { self.lane }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            let attempt = Attempt(continuation)
            guard lane.wait(attempt) else {
                // Abandoned between picking it and getting here.
                _ = attempt.finish(.failure(TimedOut()))
                return
            }
            lane.queue.async {
                lane.started(attempt)
                // The clock starts here, not in the queue: a Stop waiting
                // behind a slow move isn't itself slow.
                DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + timeout) {
                    if attempt.finish(.failure(TimedOut())) { self.retire(lane) }
                }
                // Already failed, if this lane was abandoned while it waited.
                let result = attempt.isFinished
                    ? Result<Void, Error>.failure(TimedOut())
                    : Result { try work(lane) { attempt.isFinished } }
                if !attempt.finish(result) {
                    // The caller was told this failed: leave nothing set
                    // behind its back.
                    self.closeAbandoned(lane)
                }
            }
        }
    }

    /// Leave a lane to the call stuck on it.
    private func retire(_ lane: Lane) {
        lane.abandon()
        lock.withLock {
            if self.lane === lane {
                self.lane = Lane()
                self.liveRoute = nil
            }
        }
    }

    /// On the abandoned lane's queue, once its stuck call has returned. The
    /// call may have set or cleared the location on its way out, even with
    /// nothing left open here, so the handler always hears of it.
    private func closeAbandoned(_ lane: Lane) {
        lane.simulator?.close()
        lane.simulator = nil
        let handler = lock.withLock { abandonedCallEnded }
        handler?()
    }
}

/// Is LocalDevVPN on, and which of this iPhone's developer ports answer
/// through it? It routes this iPhone's address (10.7.0.1) back to the iPhone.
/// Older iOS answers on lockdown's port and remotepairingd's; newer iOS only
/// on remotepairingd's, so checking lockdown alone would call LocalDevVPN off
/// when it's on.
enum LoopbackProbe {
    struct Findings: Sendable {
        var ports: DeveloperPorts
        /// remotepairingd's port, when Bonjour had to be asked and named one.
        var remotePairingPort: UInt16?
    }

    static func developerPorts(knownRemotePairingPort: UInt16?, address: String = OnDeviceSimulator.defaultAddress,
                               timeout: TimeInterval = 2) async -> Findings {
        let candidates = TunnelPlan.remotePairingCandidates(discovered: knownRemotePairingPort)
        let open = await answering(candidates + [TunnelPlan.lockdownPort], address: address, timeout: timeout)
        var remotePairing = candidates.filter { open.contains($0) }
        var found: UInt16?
        if remotePairing.isEmpty, let port = await RemotePairingPort.find(), !candidates.contains(port) {
            // remotepairingd isn't where it usually is.
            found = port
            if await answers(address: address, port: port, timeout: timeout) { remotePairing = [port] }
        }
        return Findings(ports: DeveloperPorts(remotePairing: remotePairing,
                                              lockdown: open.contains(TunnelPlan.lockdownPort)),
                        remotePairingPort: found)
    }

    /// The ports that take a TCP connection, all tried at once.
    private static func answering(_ ports: [UInt16], address: String, timeout: TimeInterval) async -> Set<UInt16> {
        await withTaskGroup(of: UInt16?.self) { group in
            for port in ports {
                group.addTask { await answers(address: address, port: port, timeout: timeout) ? port : nil }
            }
            var open = Set<UInt16>()
            for await port in group {
                if let port { open.insert(port) }
            }
            return open
        }
    }

    static func answers(address: String, port: UInt16, timeout: TimeInterval) async -> Bool {
        guard let endpointPort = NWEndpoint.Port(rawValue: port) else { return false }
        return await withCheckedContinuation { continuation in
            let connection = NWConnection(host: NWEndpoint.Host(address), port: endpointPort, using: .tcp)
            let finish = Once { (reachable: Bool) in
                connection.cancel()
                continuation.resume(returning: reachable)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: finish(true)
                case .failed: finish(false)
                case .waiting: break // Network.framework may recover before our deadline.
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

/// Finds the port this iPhone's remotepairingd listens on. It's usually
/// 49152, the first port iOS hands out, and StikDebug connects there without
/// asking. But nothing promises it, and SideStore looks it up. The iPhone
/// advertises the port with Bonjour (`_remotepairing._tcp`, which Info.plist
/// has to list under NSBonjourServices), and an app on the iPhone sees that
/// advertisement on the loopback interface.
enum RemotePairingPort {
    static let serviceType = "_remotepairing._tcp"
    private static let defaultsKey = "phoneOnly.remotePairingPort"

    /// The port Bonjour named last time, to try first after a relaunch.
    static var remembered: UInt16? {
        get { UInt16(exactly: UserDefaults.standard.integer(forKey: defaultsKey)).flatMap { $0 == 0 ? nil : $0 } }
        set { UserDefaults.standard.set(newValue.map { Int($0) } ?? 0, forKey: defaultsKey) }
    }

    /// Ask Bonjour. Nil when this iPhone's advertisement doesn't show up in time.
    static func find(timeout: TimeInterval = 1.5) async -> UInt16? {
        await withCheckedContinuation { continuation in
            Search(continuation).start(timeout: timeout)
        }
    }

    /// How long to wait for this iPhone's own advertisement to show up as
    /// such, before settling for the only one there is.
    private static let settleTime: TimeInterval = 0.5

    /// One browse, then one resolve. Everything after `init` runs on `queue`.
    private final class Search: @unchecked Sendable {
        private let queue = DispatchQueue(label: "com.iosgpsspoof.remote.remote-pairing-port")
        private let browser = NWBrowser(for: .bonjour(type: RemotePairingPort.serviceType, domain: nil), using: .tcp)
        private var results: Set<NWBrowser.Result> = []
        private var settled = false
        private var connection: NWConnection?
        private var continuation: CheckedContinuation<UInt16?, Never>?

        init(_ continuation: CheckedContinuation<UInt16?, Never>) {
            self.continuation = continuation
        }

        func start(timeout: TimeInterval) {
            browser.browseResultsChangedHandler = { results, _ in
                self.results = results
                self.resolve()
            }
            browser.stateUpdateHandler = { state in
                if case .failed = state { self.finish(nil) }
            }
            browser.start(queue: queue)
            queue.asyncAfter(deadline: .now() + RemotePairingPort.settleTime) {
                self.settled = true
                self.resolve()
            }
            // Also the answer when iOS doesn't let the app browse: the
            // browser just waits then.
            queue.asyncAfter(deadline: .now() + timeout) { self.finish(nil) }
        }

        /// Other Apple devices on the Wi-Fi advertise this service too. This
        /// iPhone's own advertisement is the one seen on the loopback
        /// interface. If none is marked that way after a moment and there's
        /// only one, that one is taken to be this iPhone's.
        private func resolve() {
            guard connection == nil, continuation != nil else { return }
            let own = results.first { result in result.interfaces.contains { $0.type == .loopback } }
            guard let service = own ?? (settled && results.count == 1 ? results.first : nil) else { return }
            // Bonjour gives a service's port when it's resolved, and Network
            // resolves when it connects. The connection isn't used.
            let connection = NWConnection(to: service.endpoint, using: .tcp)
            self.connection = connection
            connection.pathUpdateHandler = { path in self.report(path.remoteEndpoint) }
            connection.stateUpdateHandler = { _ in self.report(self.connection?.currentPath?.remoteEndpoint) }
            connection.start(queue: queue)
        }

        private func report(_ endpoint: NWEndpoint?) {
            guard case .hostPort(_, let port)? = endpoint else { return }
            finish(port.rawValue)
        }

        private func finish(_ port: UInt16?) {
            guard let continuation else { return }
            self.continuation = nil
            // The handlers hold this object: let go, so it can be freed.
            browser.browseResultsChangedHandler = nil
            browser.stateUpdateHandler = nil
            browser.cancel()
            connection?.pathUpdateHandler = nil
            connection?.stateUpdateHandler = nil
            connection?.cancel()
            connection = nil
            continuation.resume(returning: port)
        }
    }
}

/// Keeps the app running in the background while it holds a location: the
/// location lasts while the app's connection to the iPhone's developer
/// services stays open, and iOS closes it when it suspends the app. A
/// background location session (the blue pill in the status bar) keeps
/// the app awake.
@MainActor
protocol BackgroundHolding {
    func start()
    func stop()
}

@MainActor
final class KeepAlive: BackgroundHolding {
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
