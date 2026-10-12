import Foundation

/// How the session talks to the device.
public enum EngineKind: String, Sendable, Codable, CaseIterable {
    /// One long-lived helper process; moves are a single message (fast).
    case live
    /// One `pymobiledevice3` process per location / GPX replay (compatible).
    case classic

    public var label: String { self == .live ? "Live" : "Classic" }
}

/// What the user asked for in settings.
public enum EnginePreference: String, Sendable, Codable, CaseIterable, Identifiable {
    case automatic, live, classic

    public var id: String { rawValue }
    public var label: String {
        switch self {
        case .automatic: return "Automatic"
        case .live: return "Live"
        case .classic: return "Classic"
        }
    }
}

public enum LogLevel: Int, Sendable, Comparable, CaseIterable {
    case debug, info, success, warning, error

    public static func < (a: LogLevel, b: LogLevel) -> Bool { a.rawValue < b.rawValue }
}

public enum SessionState: Equatable, Sendable {
    case idle
    /// Mounting the disk image / opening the tunnel. The string says which.
    case connecting(String)
    /// The device is at the most recent position (live or classic hold).
    case active
    /// Classic engine replaying a GPX file.
    case replaying
    /// Lost the device or the channel; will retry by itself.
    case reconnecting(String)
    /// Restoring the real location.
    case stopping
    case failed(String)

    /// Something is (or is about to be) holding a simulated location.
    public var isRunning: Bool {
        switch self {
        case .connecting, .active, .replaying, .reconnecting: return true
        case .idle, .stopping, .failed: return false
        }
    }

    /// The device is currently following us.
    public var isEngaged: Bool { self == .active || self == .replaying }
}

/// Drives the location simulation of one device for the lifetime of a
/// spoofing session: opens the channel, keeps it alive while the device stays
/// connected, re-establishes it if the device or tunnel drops, and restores
/// the real location on `stop()`.
///
/// Two engines:
/// - **live**: a `LiveHelper` process holds the channel open; `move(to:)` is a
///   single stdin message and is coalesced (newest position wins).
/// - **classic**: a `simulate-location set` process per position (each move
///   re-opens the tunnel), and GPX `play` for routes. iOS 16 and older use the
///   lockdown service, where a `set` is a quick one-shot command.
///
/// Fully event-driven; callbacks arrive on `callbackQueue` (default: main).
/// Set the callbacks before the first `start`.
public final class SpoofSession: @unchecked Sendable {
    public var onStateChange: (@Sendable (SessionState) -> Void)?
    public var onLog: (@Sendable (LogLevel, String) -> Void)?
    /// A position the device has (to our knowledge) been moved to.
    public var onPosition: (@Sendable (GeoPoint) -> Void)?
    /// The engine changed (the live helper turned out to be incompatible).
    public var onEngineChange: (@Sendable (EngineKind) -> Void)?

    public let device: Device

    private let pmd: Pymobiledevice3
    private let transport: Transport
    private let python: URL?
    private let callbackQueue: DispatchQueue
    private let options: Options
    private let ops = DispatchQueue(label: "SpoofSession.ops", qos: .userInitiated)
    private let teardown = DispatchQueue(label: "SpoofSession.teardown", qos: .userInitiated)
    private let io = DispatchQueue(label: "SpoofSession.io", qos: .userInitiated)
    /// A stop in progress, so quitting can wait for it instead of cutting it short.
    private let teardownGroup = DispatchGroup()

    private let lock = NSLock()
    private var _state: SessionState = .idle
    private var _engine: EngineKind
    private var desired: GeoPoint?
    private var replayJob: ReplayJob?
    private var child: Process?
    private var helperInput: FileHandle?
    private var helperOutput: LineSplitter?
    private var helperReady = false
    private var sawCleared = false
    private var inFlightSince: Date?
    /// When the oldest `set` that nothing has answered yet was sent.
    private var unackedSince: Date?
    /// When the live channel last answered (or opened).
    private var lastOKAt = Date.distantPast
    /// When the current channel or hold started working. A run that stays up
    /// for `healthyRun` clears the failure count when it ends.
    private var healthySince: Date?
    /// Changes whenever the channel being watched changes, so a watchdog
    /// belonging to an earlier channel stops itself.
    private var watchdogGeneration = 0
    private var sleepProbe = SleepProbe()
    /// Set when we end the channel on purpose to open a fresh one (the Mac
    /// woke from sleep). That exit is not a failure.
    private var plannedRestart: String?
    /// Set when the watchdog ended a channel that stopped answering. It is the
    /// reason to remember for that exit, whatever the dying helper then prints.
    private var watchdogVerdict: String?
    /// The second call to `stopBlocking` (the app's last-moment one) must not
    /// wait for the first.
    private var waitedForTeardown = false
    private var pending: GeoPoint?
    private var oneShotRunning = false
    private var stopping = false
    private var started = false
    private var runToken = 0
    private var needsMount = true
    /// The device went missing and we've said so in the log.
    private var waitingForDevice = false
    /// The device list could not be read this many times in a row, and the
    /// reason last given (said once in the log, not at every try).
    private var listFailures = 0
    private var lastListFailure: String?
    /// The iOS version, once a device list gave one for a phone whose version
    /// was unknown when the session was made.
    private var learnedVersion: String?
    private var failures = 0
    private var lastError: String?
    private var ownedFiles: [URL] = []

    private struct ReplayJob {
        let gpxPath: String
        let summary: String
    }

    /// How long the session waits before it decides something is wrong. The
    /// defaults are what the app uses. Tests make them short.
    struct Timing: Sendable {
        /// How often a live channel (or a classic hold) is looked at.
        var tick: TimeInterval = 5
        /// A live channel that has been quiet this long is asked for an answer.
        var idleHeartbeat: TimeInterval = 15
        /// Something was sent and nothing answered for this long: the channel is dead.
        var answerTimeout: TimeInterval = 15
        /// A run that stayed up this long counts as healthy, so a later drop starts the
        /// failure count again.
        var healthyRun: TimeInterval = 30
        /// The Mac slept if the wall clock ran ahead of the awake clock by this much.
        var sleepGap: TimeInterval = 10
        /// Pauses between tries after a failure. More failures than this give up.
        var retryDelays: [TimeInterval] = [1, 2, 3, 5, 8, 12, 20, 30, 30]
        /// The pause between looks at the device list.
        var listRetry: TimeInterval = 3
        /// How many unreadable device lists in a row before giving up.
        var listFailureLimit = 20
    }

    /// What a test can change. The app uses the defaults.
    struct Options {
        var timing = Timing()
        /// Where the live helper script is. The default writes it into the
        /// app's support folder.
        var helperScript: @Sendable () throws -> URL = { try LiveHelper.installedScriptURL() }
    }

    /// - Parameters:
    ///   - engine: `.live` requires `python` (see `Pymobiledevice3.pythonInterpreter`);
    ///     without it the session silently uses `.classic`.
    public convenience init(pmd: Pymobiledevice3, device: Device, transport: Transport = .automatic,
                            engine: EngineKind = .classic, python: URL? = nil, callbackQueue: DispatchQueue = .main) {
        self.init(pmd: pmd, device: device, transport: transport, engine: engine, python: python,
                  callbackQueue: callbackQueue, options: Options())
    }

    init(pmd: Pymobiledevice3, device: Device, transport: Transport, engine: EngineKind, python: URL?,
         callbackQueue: DispatchQueue, options: Options) {
        self.pmd = pmd
        self.device = device
        self.transport = transport
        self.python = python
        self._engine = (engine == .live && python != nil) ? .live : .classic
        self.callbackQueue = callbackQueue
        self.options = options
        signal(SIGPIPE, SIG_IGN)   // a helper dying mid-write must not kill us
    }

    public var state: SessionState { locked { _state } }
    public var engine: EngineKind { locked { _engine } }
    /// Whether the last `stop()` got the real location back (known once the
    /// state is `.idle` again).
    public var restoredOnLastStop: Bool { locked { _restoredOnLastStop } }
    /// The iPhone is unplugged (or out of reach) and the session is waiting
    /// for it to come back.
    public var isWaitingForDevice: Bool { locked { waitingForDevice } }
    private var _restoredOnLastStop = false

    /// Whether frequent `move(to:)` calls are cheap enough to drive a route or a
    /// joystick in real time. False only for the classic engine on iOS 17+,
    /// where routes go through `replay(gpxPath:summary:)` instead.
    public var canStream: Bool { engine == .live || device.isLegacy }

    // MARK: - Control

    /// Begin spoofing at `point` (or restart there).
    public func start(at point: GeoPoint) {
        guard point.isValid else { setState(.failed("invalid coordinate \(point.latitude), \(point.longitude)")); return }
        // Restarting mid-teardown would leave a child running that nothing
        // tracks once the teardown reports `.idle`.
        guard state != .stopping else { return }
        let (token, previous) = resetRun { desired = point; replayJob = nil }
        setState(.connecting("Preparing \(device.deviceName)…"))
        ops.async { [self] in
            if let previous { Self.terminate(previous, grace: 3) }
            launch(token: token)
        }
    }

    /// Move the device. Live: one message, coalesced while one is in flight.
    /// Classic: restarts the holding process (slow). Before `start`, a no-op.
    public func move(to point: GeoPoint) {
        guard point.isValid else { return }
        lock.lock()
        guard started, !stopping else { lock.unlock(); return }
        desired = point
        let engine = _engine
        let ready = helperReady
        let replaying = replayJob != nil
        lock.unlock()

        switch engine {
        case .live:
            if ready { send(point) }   // otherwise applied when the channel opens
        case .classic where device.isLegacy && !replaying:
            lock.lock()
            let busy = oneShotRunning
            oneShotRunning = true
            let token = runToken
            lock.unlock()
            if !busy { ops.async { [self] in runOneShots(token: token) } }
        case .classic:
            let (token, previous) = resetRun { desired = point; replayJob = nil }
            setState(.connecting("Moving…"))
            ops.async { [self] in
                if let previous { Self.terminate(previous, grace: 3) }
                launch(token: token)
            }
        }
    }

    /// Classic engine: replay a timed GPX track with `simulate-location play`.
    /// The session takes ownership of the file and deletes it when done.
    public func replay(gpxPath: String, summary: String) {
        guard state != .stopping else { return }
        let url = URL(fileURLWithPath: gpxPath)
        let (token, previous) = resetRun {
            replayJob = ReplayJob(gpxPath: gpxPath, summary: summary)
            ownedFiles.append(url)
        }
        // Drop older route files now; the current one goes on stop().
        let stale = locked { () -> [URL] in
            let old = ownedFiles.filter { $0 != url }
            ownedFiles = [url]
            return old
        }
        for file in stale { try? FileManager.default.removeItem(at: file) }
        setState(.connecting("Starting the route…"))
        ops.async { [self] in
            if let previous { Self.terminate(previous, grace: 3) }
            launch(token: token)
        }
    }

    /// Stop and (by default) restore the device's real location. Returns
    /// immediately; the state goes `.stopping` → `.idle`.
    public func stop(clearLocation: Bool = true) {
        teardownGroup.enter()
        let teardownState = beginStop()
        guard teardownState.wasStarted else {
            teardownGroup.leave()
            // Already stopped — or still restoring from an earlier stop(), which
            // will report .idle itself once the location is cleared.
            if state != .stopping { setState(.idle) }
            return
        }
        setState(.stopping)
        teardown.async { [self] in
            defer { teardownGroup.leave() }
            finishStop(teardownState, clearLocation: clearLocation, helperWait: 6, clearTimeout: 90, drainTimeout: 15)
            setState(.idle)
        }
    }

    /// Synchronous best-effort teardown for app termination.
    ///
    /// If a `stop()` is already restoring the real location, this waits for it
    /// (for up to 15 seconds) instead of returning at once. Returning at once
    /// would let the app quit in the middle of the restore and leave the
    /// iPhone on its fake location.
    public func stopBlocking() {
        let teardownState = beginStop()
        guard teardownState.wasStarted else {
            let firstCall = locked { () -> Bool in
                let first = !waitedForTeardown
                waitedForTeardown = true
                return first
            }
            if firstCall { _ = teardownGroup.wait(timeout: .now() + 15) }
            return
        }
        finishStop(teardownState, clearLocation: true, helperWait: 3, clearTimeout: 15, drainTimeout: 5)
        locked { _state = .idle }
    }

    /// Every session that is running, so that something which ends the whole
    /// app (a quit signal) can put each iPhone back. Held weakly.
    private static let running = RunningSessions()

    /// Put every running session's iPhone back to its real location and wait
    /// for it. For the signals that end the app without going through its
    /// normal quit path.
    public static func stopAllBlocking() {
        for session in running.all { session.stopBlocking() }
    }

    // MARK: - Launching

    /// Bump the run token (invalidating callbacks from anything older), detach
    /// the current child, and apply `configure` — all under the lock.
    private func resetRun(_ configure: () -> Void) -> (Int, Process?) {
        lock.lock()
        defer { lock.unlock() }
        stopping = false
        started = true
        runToken &+= 1
        let previous = child
        child = nil
        helperInput = nil
        helperOutput = nil
        helperReady = false
        inFlightSince = nil
        unackedSince = nil
        healthySince = nil
        watchdogGeneration &+= 1
        plannedRestart = nil
        watchdogVerdict = nil
        listFailures = 0
        lastListFailure = nil
        pending = nil
        oneShotRunning = false
        failures = 0
        lastError = nil
        waitedForTeardown = false
        Self.running.add(self)
        configure()
        return (runToken, previous)
    }

    private func launch(token: Int) {
        guard isCurrent(token) else { return }

        let listed: Device?
        do {
            listed = try pmd.find(udid: device.udid)
            locked { listFailures = 0; lastListFailure = nil }
        } catch {
            listingFailed(error, token: token)
            return
        }
        guard let listed else {
            let firstMiss = locked { () -> Bool in
                needsMount = true
                defer { waitingForDevice = true }
                return !waitingForDevice
            }
            if firstMiss {
                emit(.warning, "\(device.deviceName) isn't connected. Waiting for it: plug it in and unlock it.")
            }
            setState(.reconnecting("Waiting for \(device.deviceName) to reconnect…"))
            ops.asyncAfter(deadline: .now() + options.timing.listRetry) { [weak self] in self?.launch(token: token) }
            return
        }
        // A phone that was locked when the list was first read had no version.
        if device.majorVersion == 0, listed.majorVersion > 0 {
            locked { learnedVersion = listed.productVersion }
        }
        if locked({ () -> Bool in defer { waitingForDevice = false }; return waitingForDevice }) {
            emit(.info, "\(device.deviceName) is back. Reconnecting…")
        }

        if locked({ () -> Bool in let m = needsMount; needsMount = false; return m }) {
            setState(.connecting("Mounting the developer disk image…"))
            do {
                _ = try pmd.run(["mounter", "auto-mount", "--udid", device.udid], timeout: 120)
                emit(.debug, "developer disk image ready")
            } catch {
                emit(.debug, "auto-mount skipped (\(Self.firstLine(of: error)))")
            }
            guard isCurrent(token) else { return }
        }

        let (engine, replay, point) = locked { (_engine, replayJob, desired) }
        if let replay {
            launchReplay(replay, token: token)
            return
        }
        guard let point else { return }
        switch engine {
        case .live:
            launchHelper(at: point, token: token)
        case .classic where device.isLegacy:
            locked { oneShotRunning = true }
            runOneShots(token: token)
        case .classic:
            launchHold(at: point, token: token)
        }
    }

    // MARK: Live engine

    private func launchHelper(at point: GeoPoint, token: Int) {
        guard let python else { switchToClassic(reason: "no Python interpreter found", token: token); return }
        let script: URL
        do { script = try options.helperScript() } catch {
            switchToClassic(reason: "\(error)", token: token)
            return
        }
        let channelLabel = transportLabel

        let process = Process()
        process.executableURL = python
        process.arguments = ["-u", script.path, "--"] + setArguments(point)
        process.environment = LiveHelper.helperEnvironment()
        let input = Pipe(), output = Pipe(), errors = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = errors

        let outLines = LineSplitter { [weak self] line in self?.handleHelperLine(line, token: token) }
        outLines.attach(to: output.fileHandleForReading)
        let errorLines = LineSplitter { [weak self] line in self?.handleToolOutput(line) }
        errorLines.attach(to: errors.fileHandleForReading)

        process.terminationHandler = { [weak self] p in
            ChildProcessRegistry.shared.remove(p)
            // What it said last is why it stopped: take it in before deciding
            // whether to try again, or the reason can arrive too late.
            outLines.waitUntilFinished(timeout: 1)
            errorLines.waitUntilFinished(timeout: 1)
            self?.childExited(status: p.terminationStatus, token: token, live: true)
        }
        // The channel's pieces are recorded before the helper starts, because
        // the helper can say READY within a few milliseconds of starting.
        lock.lock()
        guard runToken == token, !stopping else {
            lock.unlock()
            try? input.fileHandleForWriting.close()
            return
        }
        child = process
        helperInput = input.fileHandleForWriting
        helperOutput = outLines
        // Said before the helper starts, so it can never come after the helper's
        // own "channel open".
        let connecting = SessionState.connecting("Opening the location channel…")
        _state = connecting
        callbackQueue.async { [onStateChange] in onStateChange?(connecting) }
        emit(.info, "opening a live channel to \(device.deviceName) (\(channelLabel))…")
        do {
            ChildProcessRegistry.shared.add(process)
            try process.run()
        } catch {
            ChildProcessRegistry.shared.remove(process)
            child = nil
            helperInput = nil
            helperOutput = nil
            lock.unlock()
            setState(.failed("could not start Python (\(python.path)): \(error.localizedDescription)"))
            return
        }
        lock.unlock()
    }

    private func handleHelperLine(_ line: String, token: Int) {
        guard let message = LiveHelper.parse(line: line) else {
            if !line.trimmingCharacters(in: .whitespaces).isEmpty { emit(.debug, line) }
            return
        }
        switch message {
        case let .ready(point):
            lock.lock()
            guard runToken == token, !stopping else { lock.unlock(); return }
            helperReady = true
            inFlightSince = nil
            unackedSince = nil
            lastOKAt = Date()
            // Not `failures = 0` here: a channel that opens and drops again within
            // seconds, over and over, is not recovering. The count is cleared when a
            // channel has stayed up for a while (see `childExited`).
            healthySince = Date()
            lastError = nil
            let wanted = desired
            lock.unlock()
            setState(.active)
            emit(.success, "● live channel open — device at \(Format.coordinate(point))")
            deliver(point)
            startWatchdog(token: token)
            if let wanted, !wanted.isClose(to: point) { send(wanted) }

        case let .ok(point):
            lock.lock()
            guard runToken == token else { lock.unlock(); return }
            inFlightSince = nil
            unackedSince = nil
            lastOKAt = Date()
            let next = pending
            pending = nil
            lock.unlock()
            deliver(point)
            if let next { send(next) }

        case .cleared:
            locked { sawCleared = true }

        case let .error(text):
            locked { lastError = text }
            emit(.warning, text)

        case let .incompatible(reason):
            emit(.warning, "live engine unavailable: \(reason)")

        case .pong, .bye, .exit, .probe:
            break
        }
    }

    private func send(_ point: GeoPoint) {
        lock.lock()
        guard helperReady, let input = helperInput else { lock.unlock(); return }
        if let since = inFlightSince, Date().timeIntervalSince(since) < 3 {
            pending = point   // newest wins; sent when the in-flight one is acknowledged
            lock.unlock()
            return
        }
        let now = Date()
        inFlightSince = now
        // The oldest message nothing has answered yet. `inFlightSince` moves on
        // each time a newer message goes out. This one doesn't, so a helper that
        // never answers is noticed however often the position changes.
        if unackedSince == nil { unackedSince = now }
        pending = nil
        lock.unlock()
        let data = Data(LiveHelper.setCommand(point).utf8)
        io.async { try? input.write(contentsOf: data) }
    }

    // MARK: Watching the channel

    /// What the watchdog decides at each look.
    enum WatchdogAction: Equatable {
        case none
        /// Ask the live channel for an answer now by sending the current spot again.
        case heartbeat
        /// The live channel did not answer in time.
        case dead(String)
        /// The Mac slept while a classic hold or route was running.
        case restartAfterSleep
    }

    /// Decide what to do about a channel, from what is known about it. Pure, so
    /// it can be tested without a phone or a clock.
    ///
    /// - A live channel answers every `set` with OK. If one was sent and no OK
    ///   came within `answerTimeout`, the channel is dead (a cable pulled, a
    ///   tunnel that went away, a helper that is stuck).
    /// - A quiet live channel is asked for an answer every `idleHeartbeat`, by
    ///   sending the current spot again, which uses the same path as a move. (A
    ///   bare `ping` would only prove the helper's loop is alive.) After the Mac
    ///   slept, it is asked at once.
    /// - A classic hold or route can't be asked anything, so the only thing known
    ///   is that the Mac slept, which breaks its tunnel.
    static func watchdogAction(engine: EngineKind, now: Date, unackedSince: Date?, lastOKAt: Date,
                               sleptSinceLastLook: Bool, timing: Timing) -> WatchdogAction {
        switch engine {
        case .live:
            if let unackedSince, now.timeIntervalSince(unackedSince) > timing.answerTimeout {
                return .dead("Timed out: the iPhone didn't answer for \(Int(timing.answerTimeout.rounded())) seconds")
            }
            guard unackedSince == nil else { return .none }
            if sleptSinceLastLook || now.timeIntervalSince(lastOKAt) > timing.idleHeartbeat { return .heartbeat }
            return .none
        case .classic:
            return sleptSinceLastLook ? .restartAfterSleep : .none
        }
    }

    /// Watches the channel or hold that is running now, until it ends.
    private func startWatchdog(token: Int) {
        let generation = locked { () -> Int in
            watchdogGeneration &+= 1
            sleepProbe = SleepProbe()
            return watchdogGeneration
        }
        scheduleWatchdog(token: token, generation: generation)
    }

    private func scheduleWatchdog(token: Int, generation: Int) {
        ops.asyncAfter(deadline: .now() + options.timing.tick) { [weak self] in
            self?.watchdogTick(token: token, generation: generation)
        }
    }

    private func watchdogTick(token: Int, generation: Int) {
        let now = Date()
        let look = locked { () -> (EngineKind, Date?, Date, Bool)? in
            guard runToken == token, !stopping, watchdogGeneration == generation, child != nil else { return nil }
            let slept = sleepProbe.sleptSinceLastLook(now: now, awake: ProcessInfo.processInfo.systemUptime,
                                                      gap: options.timing.sleepGap)
            return (_engine, unackedSince, lastOKAt, slept)
        }
        guard let (engine, unacked, lastOK, slept) = look else { return }
        switch Self.watchdogAction(engine: engine, now: now, unackedSince: unacked, lastOKAt: lastOK,
                                   sleptSinceLastLook: slept, timing: options.timing) {
        case .none:
            break
        case .heartbeat:
            if slept { emit(.info, "The Mac woke up. Checking the connection to \(device.deviceName)…") }
            sendCurrentSpot()
        case let .dead(why):
            emit(.warning, "The location channel stopped answering. Reconnecting…")
            let process = locked { () -> Process? in
                guard runToken == token, !stopping, watchdogGeneration == generation else { return nil }
                lastError = why
                watchdogVerdict = why
                watchdogGeneration &+= 1   // this watchdog is done: the exit starts the retry
                return child
            }
            // The exit goes through `childExited`, like any other, and from there
            // through the usual retries.
            if let process { Self.terminate(process, grace: 3) }
            return
        case .restartAfterSleep:
            restartChannel(reason: "The Mac woke up. Re-applying the location on \(device.deviceName)…", token: token)
            return
        }
        scheduleWatchdog(token: token, generation: generation)
    }

    /// Send the spot the iPhone should be at (again).
    private func sendCurrentSpot() {
        guard let point = locked({ desired }) else { return }
        send(point)
    }

    /// End the running channel or hold on purpose and open a new one at the
    /// current spot. Not counted as a failure.
    private func restartChannel(reason: String, token: Int) {
        let process = locked { () -> Process? in
            guard runToken == token, !stopping, let running = child else { return nil }
            plannedRestart = reason
            watchdogGeneration &+= 1
            return running
        }
        guard let process else { return }
        emit(.info, reason)
        Self.terminate(process, grace: 3)
    }

    /// Tell the session its connection to the iPhone may have gone stale: the
    /// Mac woke from sleep, or the iPhone was unplugged and plugged back in.
    ///
    /// A live channel is checked at once (it is asked to answer, and is
    /// replaced if it doesn't). A classic hold or route is restarted, because
    /// it has no way to tell. Does nothing when no channel is open.
    public func channelMayBeStale() {
        let current = locked { () -> (Int, EngineKind)? in
            guard started, !stopping, child != nil else { return nil }
            return (runToken, _engine)
        }
        guard let (token, engine) = current else { return }
        ops.async { [self] in
            switch engine {
            case .live:
                sendCurrentSpot()
            case .classic:
                restartChannel(reason: "The connection to \(device.deviceName) may have been interrupted. Re-applying the location…",
                               token: token)
            }
        }
    }

    private func switchToClassic(reason: String, token: Int) {
        lock.lock()
        guard runToken == token, !stopping else { lock.unlock(); return }
        _engine = .classic
        lock.unlock()
        emit(.warning, "live engine unavailable (\(reason)) — using the classic engine")
        callbackQueue.async { [onEngineChange] in onEngineChange?(.classic) }
        ops.async { [self] in launch(token: token) }
    }

    // MARK: Classic engine

    private func launchHold(at point: GeoPoint, token: Int) {
        let process: Process
        do {
            process = try pmd.spawn(
                setArguments(point),
                onOutput: { [weak self] line in self?.handleToolOutput(line) },
                onExit: { [weak self] p in self?.childExited(status: p.terminationStatus, token: token, live: false) }
            )
        } catch {
            setState(.failed("could not start pymobiledevice3: \(error.localizedDescription)"))
            return
        }
        guard adopt(process, token: token) else { return }
        setState(.active)
        emit(.success, "● holding at \(Format.coordinate(point))")
        deliver(point)
    }

    private func launchReplay(_ job: ReplayJob, token: Int) {
        let process: Process
        do {
            process = try pmd.spawn(
                replayArguments(job.gpxPath),
                onOutput: { [weak self] line in self?.handleToolOutput(line) },
                onExit: { [weak self] p in self?.childExited(status: p.terminationStatus, token: token, live: false) }
            )
        } catch {
            setState(.failed("could not start pymobiledevice3: \(error.localizedDescription)"))
            return
        }
        guard adopt(process, token: token) else { return }
        setState(.replaying)
        emit(.success, "● playing route: \(job.summary)")
    }

    /// iOS ≤ 16: `set` is a quick one-shot over lockdown. Keep applying the
    /// newest `desired` until it sticks.
    private func runOneShots(token: Int) {
        var applied: GeoPoint?
        while true {
            let target: GeoPoint? = locked {
                guard runToken == token, !stopping, let d = desired else { oneShotRunning = false; return nil }
                if let applied, applied.isClose(to: d) { oneShotRunning = false; return nil }
                return d
            }
            guard let target else { return }
            do {
                _ = try pmd.run(setArguments(target), timeout: 60)
            } catch {
                let detail = Self.toolErrorDetail(error)
                let attempt = locked { () -> Int in
                    self.oneShotRunning = false
                    self.lastError = detail
                    self.failures += 1
                    return self.failures
                }
                guard isCurrent(token) else { return }
                emit(.debug, "\(error)")
                // If the list can't be read, take the phone as still there: the
                // failure above is then counted and shown with its real reason.
                let stillListed = (try? pmd.presence(udid: device.udid)) ?? true
                if stillListed {
                    retryOrFail(failures: attempt, lastError: detail, problem: "setting the location failed", token: token)
                } else {
                    locked { needsMount = true }
                    setState(.reconnecting("Waiting for \(device.deviceName) to reconnect…"))
                    ops.asyncAfter(deadline: .now() + options.timing.listRetry) { [weak self] in self?.launch(token: token) }
                }
                return
            }
            guard isCurrent(token) else { return }
            locked { failures = 0 }
            applied = target
            if state != .active {
                setState(.active)
                emit(.success, "● location set to \(Format.coordinate(target))")
            }
            deliver(target)
        }
    }

    /// Record `process` as the current child, or kill it if it's already stale.
    private func adopt(_ process: Process, token: Int) -> Bool {
        lock.lock()
        guard runToken == token, !stopping else {
            lock.unlock()
            Self.terminate(process, grace: 2)
            return false
        }
        child = process
        healthySince = Date()
        lock.unlock()
        // There is nothing to ask a classic hold or route, but the Mac sleeping
        // under one can be told.
        startWatchdog(token: token)
        return true
    }

    // MARK: Exits & retries

    private func childExited(status: Int32, token: Int, live: Bool) {
        lock.lock()
        guard runToken == token, !stopping else { lock.unlock(); return }
        child = nil
        helperInput = nil
        helperReady = false
        inFlightSince = nil
        unackedSince = nil
        watchdogGeneration &+= 1
        let planned = plannedRestart
        plannedRestart = nil
        // The dying helper may print a traceback of its own. The reason we ended
        // it is the one worth keeping.
        if let verdict = watchdogVerdict {
            lastError = verdict
            watchdogVerdict = nil
        }
        // A channel that stayed up for a while was healthy, so the next drop is a
        // first one. (Measured from when it started working, not from when it
        // was started: opening it can take a long time.)
        if planned == nil, let since = healthySince, Date().timeIntervalSince(since) > options.timing.healthyRun {
            failures = 0
        }
        healthySince = nil
        if planned == nil { failures += 1 }
        let failures = self.failures
        let lastError = self.lastError
        let isReplay = replayJob != nil
        lock.unlock()

        if planned != nil {
            // We ended it ourselves to open a fresh one: not a failure.
            setState(.reconnecting("Reconnecting to \(device.deviceName)…"))
            ops.asyncAfter(deadline: .now() + 1) { [weak self] in self?.launch(token: token) }
            return
        }

        if live && status == LiveHelper.incompatibleExitStatus {
            switchToClassic(reason: lastError ?? "the helper could not patch pymobiledevice3", token: token)
            return
        }

        let what = live ? "location channel" : (isReplay ? "route playback" : "location hold")
        retryOrFail(failures: failures, lastError: lastError, problem: "\(what) closed (exit status \(status))",
                    token: token)
    }

    /// After a failure: give up with advice if retrying can't help; otherwise
    /// try again after a growing pause.
    ///
    /// Connections drop now and then (a cable wobble, the phone's tunnel being
    /// re-made). Retrying for about two minutes before giving up lets a long
    /// route survive a hiccup and carry on from where it was.
    private func retryOrFail(failures: Int, lastError: String?, problem: String, token: Int) {
        if let lastError, let advice = Self.advice(for: lastError), advice.permanent {
            emit(.error, advice.message)
            setState(.failed(advice.message))
            if lastError.contains(Self.rejectedCommandMarker) { reportToolVersion() }
            return
        }
        let delays = options.timing.retryDelays
        if failures > delays.count {
            let message = "Lost the connection to \(device.deviceName). Unplug it, plug it back in and unlock it, then press Start again."
            emit(.error, "\(message) (last error: \(lastError ?? problem))")
            setState(.failed(message))
            return
        }
        // After a few tries, check the developer disk image is still mounted.
        if failures >= 3 { locked { needsMount = true } }
        let delay = delays[failures - 1]
        emit(.warning, "\(problem) — retrying in \(Int(delay))s (try \(failures) of \(delays.count))")
        let reason = lastError.flatMap { Self.advice(for: $0)?.message } ?? "Reconnecting to \(device.deviceName)…"
        setState(.reconnecting(reason))
        ops.asyncAfter(deadline: .now() + delay) { [weak self] in self?.launch(token: token) }
    }

    /// The device list could not be read (as opposed to the phone not being in
    /// it). Say why, once, and keep trying for a while. A hiccup in the USB
    /// service after the Mac wakes usually passes.
    private func listingFailed(_ error: Error, token: Int) {
        let reason = Self.firstLine(of: error)
        let (count, isNew) = locked { () -> (Int, Bool) in
            listFailures += 1
            let isNew = lastListFailure != reason
            lastListFailure = reason
            return (listFailures, isNew)
        }
        guard isCurrent(token) else { return }
        if count > options.timing.listFailureLimit {
            let message = "AnyWhere can't read the list of iPhones. \(reason)"
            emit(.error, message)
            setState(.failed(message))
            return
        }
        if isNew { emit(.warning, "Couldn't read the list of iPhones: \(reason). Trying again.") }
        setState(.reconnecting("Couldn't check for \(device.deviceName). Trying again…"))
        ops.asyncAfter(deadline: .now() + options.timing.listRetry) { [weak self] in self?.launch(token: token) }
    }

    /// After pymobiledevice3 refused a command: say which version is installed
    /// and which one this iPhone needs, so the log explains the advice.
    private func reportToolVersion() {
        ops.async { [self] in
            guard let text = pmd.version(), let installed = ToolVersion(text) else { return }
            let needed = tunnelTransport() == .native ? ToolVersion.nativeFloor : ToolVersion.userspaceFloor
            if installed < needed {
                emit(.warning, "pymobiledevice3 \(installed) is installed. \(device.deviceName) needs \(needed) or newer.")
            } else {
                emit(.info, "pymobiledevice3 \(installed) is installed.")
            }
        }
    }

    /// The useful part of a failed pymobiledevice3 run: its error lines, not
    /// the command line that `Pymobiledevice3.run` puts first.
    static func toolErrorDetail(_ error: Error) -> String {
        if let reason = (error as? SpoofError)?.reason { return cleanLogLine(reason) }
        let lines = "\(error)".split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let detail = lines.count > 1 ? lines.dropFirst().last ?? lines[0] : (lines.first ?? "\(error)")
        return cleanLogLine(detail)
    }

    /// A plain-English reading of a pymobiledevice3 error, and whether retrying
    /// can help. Nil when the error isn't one we recognise.
    ///
    /// pymobiledevice3's command line prints plain sentences, not the names of
    /// its exceptions ("User refused to trust this computer"), so both forms
    /// are matched. The names still show up in what the live helper reports
    /// once the channel is open.
    public static func advice(for error: String) -> (message: String, permanent: Bool)? {
        let e = error.lowercased()
        // pymobiledevice3 turned the command down: an option or command this
        // version doesn't have. Trying again can't change that.
        if e.contains(Self.rejectedCommandMarker) || e.contains("no such option") || e.contains("no such command") {
            return ("Your pymobiledevice3 is too old for AnyWhere. In Settings, find the pymobiledevice3 section and click Update. Then press Start again.", true)
        }
        if e.contains("developermode") || e.contains("developer mode") {
            return ("Developer Mode is off on the iPhone. Turn it on in Settings ▸ Privacy & Security ▸ Developer Mode, then restart the phone.", true)
        }
        if e.contains("userdeniedpairing") || e.contains("refused to trust") {
            return ("The iPhone said Don't Trust. Unplug it, plug it back in and tap Trust, then press Start again.", true)
        }
        // These two the user can fix while we keep retrying.
        if e.contains("passwordrequired") || e.contains("password protected") || e.contains("device is locked") {
            return ("Unlock your iPhone to reconnect…", false)
        }
        if e.contains("notpaired") || e.contains("not paired") || e.contains("pairingdialog")
            || e.contains("user dialog approval") || (e.contains("trust") && e.contains("dialog")) {
            return ("Tap Trust on your iPhone (and enter its passcode) to connect…", false)
        }
        if e.contains("no route to host") || e.contains("connectionterminated") || e.contains("terminated abruptly")
            || e.contains("connection reset") || e.contains("broken pipe") || e.contains("timed out")
            || e.contains("connection refused") {
            return ("The connection to the iPhone dropped. Reconnecting…", false)
        }
        if e.contains("developerdiskimage") || e.contains("invalidservice") || e.contains("mount")
            || e.contains("failed to start service") {
            return ("Couldn't load Apple's developer support onto the iPhone. Keep it unlocked and online; retrying…", false)
        }
        return nil
    }

    /// Start of the message kept when pymobiledevice3 refuses a command line.
    static let rejectedCommandMarker = "rejected the command"

    /// Whether `line` says pymobiledevice3 turned the command line down because
    /// an option or command doesn't exist in this version, and if so the
    /// message to keep. Only those cases: a bad value is our bug, not an old tool.
    static func commandRejection(in line: String) -> String? {
        let plain = ToolStderr.stripBox(line)
        let lower = plain.lowercased()
        guard lower.contains("no such option") || lower.contains("no such command")
            || lower.contains("unexpected extra argument") else { return nil }
        return "pymobiledevice3 \(rejectedCommandMarker): \(plain)"
    }

    /// stderr of pymobiledevice3 (or the helper): surface errors, keep the rest
    /// as debug output.
    private func handleToolOutput(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        // A command line pymobiledevice3 doesn't understand is printed as a
        // box (`│ No such option: --userspace │`) with no "ERROR" in it.
        if let rejection = Self.commandRejection(in: trimmed) {
            locked { lastError = rejection }
            emit(.error, rejection)
            return
        }
        if trimmed.contains(" ERROR ") || trimmed.hasPrefix("ERROR") || trimmed.contains("Traceback")
            || trimmed.contains("Exception:") || trimmed.contains("Error:") {
            let message = Self.cleanLogLine(trimmed)
            locked { lastError = message }
            emit(.error, message)
        } else if trimmed.contains(" WARNING ") {
            emit(.warning, Self.cleanLogLine(trimmed))
        } else {
            emit(.debug, Self.cleanLogLine(trimmed))
        }
    }

    // MARK: - Teardown

    private struct TeardownState {
        let wasStarted: Bool
        let process: Process?
        let input: FileHandle?
        let output: LineSplitter?
        let helperWasReady: Bool
        let files: [URL]
    }

    private func beginStop() -> TeardownState {
        lock.lock()
        defer { lock.unlock() }
        let state = TeardownState(wasStarted: started, process: child, input: helperInput, output: helperOutput,
                                  helperWasReady: helperReady, files: ownedFiles)
        stopping = true
        started = false
        runToken &+= 1
        watchdogGeneration &+= 1
        plannedRestart = nil
        watchdogVerdict = nil
        child = nil
        helperInput = nil
        helperOutput = nil
        helperReady = false
        sawCleared = false
        replayJob = nil
        ownedFiles = []
        return state
    }

    /// Wait (for a while at most) for work already queued on `ops`, notably an
    /// iOS 16 `set` that is still running, so the `clear` that follows is the
    /// last thing the iPhone is told. `ops` runs one thing at a time, and
    /// anything from before the stop returns right after its command ends (its
    /// run token is out of date), so one marker is enough. It never waits for a
    /// long time: a stuck `set` must not hold up Stop or quitting.
    private func drainOps(timeout: TimeInterval) {
        let done = DispatchSemaphore(value: 0)
        ops.async { done.signal() }
        _ = done.wait(timeout: .now() + timeout)
    }

    private func finishStop(_ s: TeardownState, clearLocation: Bool, helperWait: TimeInterval, clearTimeout: TimeInterval,
                            drainTimeout: TimeInterval) {
        defer { Self.running.remove(self) }
        var cleared = false
        if let process = s.process, let input = s.input, s.helperWasReady {
            // Ask the helper to clear over the open channel — no new tunnel needed.
            try? input.write(contentsOf: Data((clearLocation ? "quit clear\n" : "quit\n").utf8))
            _ = Self.waitForExit(process, seconds: helperWait)
            s.output?.waitUntilFinished(timeout: 1)
            let confirmed = locked { sawCleared }
            cleared = clearLocation && confirmed
        }
        try? s.input?.close()
        if let process = s.process { Self.terminate(process, grace: 3) }
        for file in s.files { try? FileManager.default.removeItem(at: file) }

        locked { _restoredOnLastStop = false }
        guard clearLocation else { return }
        if cleared {
            locked { _restoredOnLastStop = true }
            emit(.success, "real location restored")
            return
        }
        emit(.info, "restoring the real location…")
        // Anything still running from before the stop (an iOS 16 `set` that was
        // under way, a hold that was just being opened) must finish first. If it
        // ended after the clear, it would put the fake location back.
        drainOps(timeout: drainTimeout)
        do {
            _ = try pmd.run(clearArguments, timeout: clearTimeout)
            locked { _restoredOnLastStop = true }
            emit(.success, "real location restored")
        } catch {
            emit(.error, "Couldn't put the real location back: \(Self.firstLine(of: error)). Restarting the iPhone always clears it.")
        }
    }

    // MARK: - Arguments

    private var transportLabel: String { device.isLegacy ? "lockdown" : tunnelTransport().label }

    /// The iPhone as the tunnel choice sees it. A phone that was locked when
    /// the list was read reports no iOS version. Once a later list gives one,
    /// it is used here.
    private var tunnelDevice: Device {
        guard device.majorVersion == 0, let learned = locked({ learnedVersion }) else { return device }
        return Device(deviceName: device.deviceName, identifier: device.identifier,
                      connectionType: device.connectionType, productType: device.productType,
                      productVersion: learned)
    }

    /// The tunnel for this iPhone. "Automatic" goes by iOS version. When the
    /// version is still unknown it takes the newer tunnel, because a phone
    /// that old (iOS 17.0 to 17.3) is far less likely than a current one, and
    /// Apple's own tunnel keeps being knocked off by macOS.
    private func tunnelTransport() -> Transport {
        let phone = tunnelDevice
        if transport == .automatic, phone.majorVersion == 0 { return .userspace }
        return transport.resolved(for: phone)
    }

    private func setArguments(_ p: GeoPoint) -> [String] {
        if device.isLegacy {
            return ["developer", "simulate-location", "set", "--udid", device.udid, "--",
                    String(p.latitude), String(p.longitude)]
        }
        return ["developer", "dvt", "simulate-location", "set"] + tunnelTransport().flags(udid: device.udid)
            + ["--udid", device.udid, "--", String(p.latitude), String(p.longitude)]
    }

    private var clearArguments: [String] {
        if device.isLegacy {
            return ["developer", "simulate-location", "clear", "--udid", device.udid]
        }
        return ["developer", "dvt", "simulate-location", "clear"] + tunnelTransport().flags(udid: device.udid)
            + ["--udid", device.udid]
    }

    private func replayArguments(_ path: String) -> [String] {
        ["developer", "dvt", "simulate-location", "play"] + tunnelTransport().flags(udid: device.udid)
            + ["--udid", device.udid, path]
    }

    // MARK: - Helpers

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }

    private func isCurrent(_ token: Int) -> Bool {
        locked { runToken == token && !stopping }
    }

    private func setState(_ newValue: SessionState) {
        locked { _state = newValue }
        callbackQueue.async { [onStateChange] in onStateChange?(newValue) }
    }

    private func deliver(_ point: GeoPoint) {
        callbackQueue.async { [onPosition] in onPosition?(point) }
    }

    private func emit(_ level: LogLevel, _ line: String) {
        callbackQueue.async { [onLog] in onLog?(level, line) }
    }

    static func terminate(_ process: Process, grace: TimeInterval) {
        guard process.isRunning else { return }
        process.interrupt()
        if waitForExit(process, seconds: grace * 0.6) { return }
        process.terminate()
        if waitForExit(process, seconds: grace * 0.4) { return }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }

    @discardableResult
    static func waitForExit(_ process: Process, seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if !process.isRunning { return true }
            usleep(50_000)
        }
        return !process.isRunning
    }

    /// What to show a person about `error`: the reason a pymobiledevice3 run
    /// failed (not the command line that `Pymobiledevice3.run` puts first), or
    /// the first line of any other error.
    public static func firstLine(of error: Error) -> String {
        if let reason = (error as? SpoofError)?.reason { return reason }
        let text = "\(error)"
        return text.split(separator: "\n").first.map(String.init) ?? text
    }

    /// Strip the coloredlogs prefix ("2026-01-01 12:00:00 host name[pid] LEVEL ").
    static func cleanLogLine(_ line: String) -> String {
        for level in [" ERROR ", " WARNING ", " INFO ", " DEBUG "] {
            if let r = line.range(of: level) { return String(line[r.upperBound...]) }
        }
        return line
    }
}

/// Tells whether the Mac slept between two looks. The wall clock keeps running
/// while the Mac sleeps and the awake clock (`systemUptime`) doesn't, so a gap
/// between how far each moved is time spent asleep.
struct SleepProbe {
    private var wall: Date
    private var awake: TimeInterval

    init(now: Date = Date(), awake: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        wall = now
        self.awake = awake
    }

    /// True when more than `gap` seconds of sleep passed since the last look.
    mutating func sleptSinceLastLook(now: Date, awake nowAwake: TimeInterval, gap: TimeInterval) -> Bool {
        let wallElapsed = now.timeIntervalSince(wall)
        let awakeElapsed = nowAwake - awake
        wall = now
        awake = nowAwake
        return wallElapsed - awakeElapsed > gap
    }
}

/// The sessions that are running, held weakly. See `SpoofSession.stopAllBlocking`.
private final class RunningSessions: @unchecked Sendable {
    private struct Entry { weak var session: SpoofSession? }
    private let lock = NSLock()
    private var entries: [ObjectIdentifier: Entry] = [:]

    func add(_ session: SpoofSession) {
        lock.lock(); defer { lock.unlock() }
        entries[ObjectIdentifier(session)] = Entry(session: session)
    }

    func remove(_ session: SpoofSession) {
        lock.lock(); defer { lock.unlock() }
        entries[ObjectIdentifier(session)] = nil
    }

    var all: [SpoofSession] {
        lock.lock(); defer { lock.unlock() }
        return entries.values.compactMap { $0.session }
    }
}
