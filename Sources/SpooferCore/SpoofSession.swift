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
    private let ops = DispatchQueue(label: "SpoofSession.ops", qos: .userInitiated)
    private let teardown = DispatchQueue(label: "SpoofSession.teardown", qos: .userInitiated)
    private let io = DispatchQueue(label: "SpoofSession.io", qos: .userInitiated)

    private let lock = NSLock()
    private var _state: SessionState = .idle
    private var _engine: EngineKind
    private var desired: GeoPoint?
    private var replayJob: ReplayJob?
    private var child: Process?
    private var childStartedAt = Date.distantPast
    private var helperInput: FileHandle?
    private var helperOutput: LineSplitter?
    private var helperReady = false
    private var sawCleared = false
    private var inFlightSince: Date?
    private var pending: GeoPoint?
    private var oneShotRunning = false
    private var stopping = false
    private var started = false
    private var runToken = 0
    private var needsMount = true
    /// The device went missing and we've said so in the log.
    private var waitingForDevice = false
    private var failures = 0
    private var lastError: String?
    private var ownedFiles: [URL] = []

    private struct ReplayJob {
        let gpxPath: String
        let summary: String
    }

    /// - Parameters:
    ///   - engine: `.live` requires `python` (see `Pymobiledevice3.pythonInterpreter`);
    ///     without it the session silently uses `.classic`.
    public init(pmd: Pymobiledevice3, device: Device, transport: Transport = .automatic,
                engine: EngineKind = .classic, python: URL? = nil, callbackQueue: DispatchQueue = .main) {
        self.pmd = pmd
        self.device = device
        self.transport = transport
        self.python = python
        self._engine = (engine == .live && python != nil) ? .live : .classic
        self.callbackQueue = callbackQueue
        signal(SIGPIPE, SIG_IGN)   // a helper dying mid-write must not kill us
    }

    public var state: SessionState { locked { _state } }
    public var engine: EngineKind { locked { _engine } }
    /// Whether the last `stop()` got the real location back (known once the
    /// state is `.idle` again).
    public var restoredOnLastStop: Bool { locked { _restoredOnLastStop } }
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
        let teardownState = beginStop()
        guard teardownState.wasStarted else {
            // Already stopped — or still restoring from an earlier stop(), which
            // will report .idle itself once the location is cleared.
            if state != .stopping { setState(.idle) }
            return
        }
        setState(.stopping)
        teardown.async { [self] in
            finishStop(teardownState, clearLocation: clearLocation, helperWait: 6, clearTimeout: 90)
            setState(.idle)
        }
    }

    /// Synchronous best-effort teardown for app termination.
    public func stopBlocking() {
        let teardownState = beginStop()
        guard teardownState.wasStarted else { return }
        finishStop(teardownState, clearLocation: true, helperWait: 3, clearTimeout: 15)
        locked { _state = .idle }
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
        pending = nil
        oneShotRunning = false
        failures = 0
        lastError = nil
        configure()
        return (runToken, previous)
    }

    private func launch(token: Int) {
        guard isCurrent(token) else { return }

        guard pmd.isPresent(udid: device.udid) else {
            let firstMiss = locked { () -> Bool in
                needsMount = true
                defer { waitingForDevice = true }
                return !waitingForDevice
            }
            if firstMiss {
                emit(.warning, "\(device.deviceName) isn't connected. Waiting for it: plug it in and unlock it.")
            }
            setState(.reconnecting("Waiting for \(device.deviceName) to reconnect…"))
            ops.asyncAfter(deadline: .now() + 3) { [weak self] in self?.launch(token: token) }
            return
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
        do { script = try LiveHelper.installedScriptURL() } catch {
            switchToClassic(reason: "\(error)", token: token)
            return
        }

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
        LineSplitter { [weak self] line in self?.handleToolOutput(line) }.attach(to: errors.fileHandleForReading)

        process.terminationHandler = { [weak self] p in
            ChildProcessRegistry.shared.remove(p)
            self?.childExited(status: p.terminationStatus, token: token, live: true)
        }
        do {
            try process.run()
        } catch {
            setState(.failed("could not start Python (\(python.path)): \(error.localizedDescription)"))
            return
        }
        ChildProcessRegistry.shared.add(process)

        lock.lock()
        guard runToken == token, !stopping else {
            lock.unlock()
            try? input.fileHandleForWriting.close()
            Self.terminate(process, grace: 2)
            return
        }
        child = process
        childStartedAt = Date()
        helperInput = input.fileHandleForWriting
        helperOutput = outLines
        helperReady = false
        lock.unlock()

        setState(.connecting("Opening the location channel…"))
        emit(.info, "opening a live channel to \(device.deviceName) (\(transportLabel))…")
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
            failures = 0
            lastError = nil
            let wanted = desired
            lock.unlock()
            setState(.active)
            emit(.success, "● live channel open — device at \(Format.coordinate(point))")
            deliver(point)
            if let wanted, !wanted.isClose(to: point) { send(wanted) }

        case let .ok(point):
            lock.lock()
            guard runToken == token else { lock.unlock(); return }
            inFlightSince = nil
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
        inFlightSince = Date()
        pending = nil
        lock.unlock()
        let data = Data(LiveHelper.setCommand(point).utf8)
        io.async { try? input.write(contentsOf: data) }
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
                let failures = locked { () -> Int in
                    oneShotRunning = false
                    lastError = detail
                    failures += 1
                    return failures
                }
                guard isCurrent(token) else { return }
                emit(.debug, "\(error)")
                if pmd.isPresent(udid: device.udid) {
                    retryOrFail(failures: failures, lastError: detail, problem: "setting the location failed", token: token)
                } else {
                    locked { needsMount = true }
                    setState(.reconnecting("Waiting for \(device.deviceName) to reconnect…"))
                    ops.asyncAfter(deadline: .now() + 3) { [weak self] in self?.launch(token: token) }
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
        childStartedAt = Date()
        lock.unlock()
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
        // A long, healthy run resets the failure streak.
        if Date().timeIntervalSince(childStartedAt) > 30 { failures = 0 }
        failures += 1
        let failures = self.failures
        let lastError = self.lastError
        let isReplay = replayJob != nil
        lock.unlock()

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
            return
        }
        let delays = [1.0, 2.0, 3.0, 5.0, 8.0, 12.0, 20.0, 30.0, 30.0]
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

    /// The useful part of a failed pymobiledevice3 run: its error lines, not
    /// the command line that `Pymobiledevice3.run` puts first.
    static func toolErrorDetail(_ error: Error) -> String {
        let lines = "\(error)".split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let detail = lines.count > 1 ? lines.dropFirst().last ?? lines[0] : (lines.first ?? "\(error)")
        return cleanLogLine(detail)
    }

    /// A plain-English reading of a pymobiledevice3 error, and whether retrying
    /// can help. Nil when the error isn't one we recognise.
    public static func advice(for error: String) -> (message: String, permanent: Bool)? {
        let e = error.lowercased()
        if e.contains("developermode") || e.contains("developer mode") {
            return ("Developer Mode is off on the iPhone. Turn it on in Settings ▸ Privacy & Security ▸ Developer Mode, then restart the phone.", true)
        }
        if e.contains("userdeniedpairing") {
            return ("The iPhone said Don't Trust. Unplug it, plug it back in and tap Trust, then press Start again.", true)
        }
        // These two the user can fix while we keep retrying.
        if e.contains("passwordrequired") || e.contains("password protected") || e.contains("device is locked") {
            return ("Unlock your iPhone to reconnect…", false)
        }
        if e.contains("notpaired") || e.contains("pairingdialog") || (e.contains("trust") && e.contains("dialog")) {
            return ("Tap Trust on your iPhone (and enter its passcode) to connect…", false)
        }
        if e.contains("no route to host") || e.contains("connectionterminated") || e.contains("terminated abruptly")
            || e.contains("connection reset") || e.contains("broken pipe") || e.contains("timed out")
            || e.contains("connection refused") {
            return ("The connection to the iPhone dropped. Reconnecting…", false)
        }
        if e.contains("developerdiskimage") || e.contains("invalidservice") || e.contains("mount") {
            return ("Couldn't load Apple's developer support onto the iPhone. Keep it unlocked and online; retrying…", false)
        }
        return nil
    }

    /// stderr of pymobiledevice3 (or the helper): surface errors, keep the rest
    /// as debug output.
    private func handleToolOutput(_ line: String) {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
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
        child = nil
        helperInput = nil
        helperOutput = nil
        helperReady = false
        sawCleared = false
        replayJob = nil
        ownedFiles = []
        return state
    }

    private func finishStop(_ s: TeardownState, clearLocation: Bool, helperWait: TimeInterval, clearTimeout: TimeInterval) {
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
        do {
            _ = try pmd.run(clearArguments, timeout: clearTimeout)
            locked { _restoredOnLastStop = true }
            emit(.success, "real location restored")
        } catch {
            emit(.error, "could not clear the simulated location: \(Self.firstLine(of: error)). Restarting the iPhone always clears it.")
        }
    }

    // MARK: - Arguments

    private var transportLabel: String { device.isLegacy ? "lockdown" : transport.resolved(for: device).label }

    private func setArguments(_ p: GeoPoint) -> [String] {
        if device.isLegacy {
            return ["developer", "simulate-location", "set", "--udid", device.udid, "--",
                    String(p.latitude), String(p.longitude)]
        }
        return ["developer", "dvt", "simulate-location", "set"] + transport.flags(for: device)
            + ["--udid", device.udid, "--", String(p.latitude), String(p.longitude)]
    }

    private var clearArguments: [String] {
        if device.isLegacy {
            return ["developer", "simulate-location", "clear", "--udid", device.udid]
        }
        return ["developer", "dvt", "simulate-location", "clear"] + transport.flags(for: device)
            + ["--udid", device.udid]
    }

    private func replayArguments(_ path: String) -> [String] {
        ["developer", "dvt", "simulate-location", "play"] + transport.flags(for: device)
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

    public static func firstLine(of error: Error) -> String {
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
