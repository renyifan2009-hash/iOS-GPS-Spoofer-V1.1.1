import Foundation

/// A location-simulation process left behind by a run of the app that was
/// killed (so nothing was left to stop it).
public struct StrayProcess: Equatable, Sendable {
    public let pid: Int32
    /// Its full command line.
    public let command: String

    public init(pid: Int32, command: String) {
        self.pid = pid
        self.command = command
    }

    /// The live helper clears the location by itself when the app that started
    /// it goes away (its input closes), so it needs nothing from us.
    public var isLiveHelper: Bool { command.contains("iosgpsspoof-live-helper") }

    /// What a classic hold or route playback was holding. Nil for the live
    /// helper, and for anything that isn't a `simulate-location set` or `play`.
    public var hold: StrayHold? {
        guard !isLiveHelper else { return nil }
        return StrayHold(commandLine: command)
    }
}

/// An iPhone that a killed run left on a fake location, and how to put it back.
public struct StrayHold: Equatable, Sendable {
    public let udid: String
    /// pymobiledevice3 arguments that clear the location the way the run set it
    /// (same service, same tunnel).
    public let clearArguments: [String]

    /// Reads the command line of a `simulate-location set` or `play` that was
    /// started by the app. Nil when it isn't one, or names no iPhone.
    init?(commandLine: String) {
        let tokens = commandLine.split(separator: " ").map(String.init)
        guard let simulate = tokens.firstIndex(of: "simulate-location"), simulate + 1 < tokens.count,
              ["set", "play"].contains(tokens[simulate + 1]),
              let developer = tokens[..<simulate].lastIndex(of: "developer") else { return nil }
        var arguments = Array(tokens[developer...simulate]) + ["clear"]
        var udid: String?
        var i = simulate + 2
        while i < tokens.count {
            let token = tokens[i]
            if token == "--" { break }
            if ["--udid", "--tunnel"].contains(token), i + 1 < tokens.count {
                arguments += [token, tokens[i + 1]]
                if token == "--udid" { udid = tokens[i + 1] }
                i += 2
            } else {
                // Flags (--userspace, --native) are kept. The coordinates and the
                // route file are not part of a clear.
                if token.hasPrefix("--") { arguments.append(token) }
                i += 1
            }
        }
        guard let udid else { return nil }
        self.udid = udid
        self.clearArguments = arguments
    }
}

/// What a sweep for leftover processes found.
public struct SweepReport: Equatable, Sendable {
    /// How many it stopped.
    public let reaped: Int
    /// The iPhones that may still be on a fake location, because what was
    /// holding it was stopped here and could not clear it.
    public let holds: [StrayHold]

    public static let empty = SweepReport(reaped: 0, holds: [])
}

/// Tracks every `pymobiledevice3` child spawned via `Pymobiledevice3.spawn` (and
/// the live helpers), so a front-end can guarantee cleanup on termination
/// (SIGTERM, crash, Cmd-Q) even if the normal `stop()` path didn't run. Without
/// this, a killed parent leaves the child holding the device's location
/// simulation open.
public final class ChildProcessRegistry: @unchecked Sendable {
    public static let shared = ChildProcessRegistry()

    private let lock = NSLock()
    private var processes: [ObjectIdentifier: Process] = [:]

    private init() {}

    func add(_ process: Process) {
        lock.lock(); processes[ObjectIdentifier(process)] = process; lock.unlock()
    }

    func remove(_ process: Process) {
        lock.lock(); processes[ObjectIdentifier(process)] = nil; lock.unlock()
    }

    /// Stop every tracked child within roughly `grace` seconds. Live helpers get
    /// their stdin closed first (they clear the location and exit on EOF); then
    /// SIGINT, then SIGKILL. Safe to call from a dispatch signal-source handler.
    public func terminateAll(grace: TimeInterval = 2) {
        lock.lock()
        let all = Array(processes.values)
        processes.removeAll()
        lock.unlock()

        let deadline = Date().addingTimeInterval(grace)
        for p in all where p.isRunning {
            if let input = p.standardInput as? Pipe {
                try? input.fileHandleForWriting.close()
            }
        }
        let helperDeadline = Date().addingTimeInterval(grace * 0.6)
        while Date() < helperDeadline, all.contains(where: { $0.isRunning && $0.standardInput is Pipe }) {
            usleep(50_000)
        }
        for p in all where p.isRunning { p.interrupt() }
        while Date() < deadline, all.contains(where: { $0.isRunning }) { usleep(50_000) }
        for p in all where p.isRunning { kill(p.processIdentifier, SIGKILL) }
    }

    public var hasRunningChildren: Bool {
        lock.lock(); defer { lock.unlock() }
        return processes.values.contains { $0.isRunning }
    }

    // MARK: - Leftovers of a killed run

    private static let sweepLock = NSLock()
    nonisolated(unsafe) private static var _lastSweep = SweepReport.empty

    /// What the most recent sweep found, for whoever reports it to the person.
    public static var lastSweep: SweepReport {
        sweepLock.lock(); defer { sweepLock.unlock() }
        return _lastSweep
    }

    /// Kill location-simulation processes orphaned by a previous run that was
    /// force-killed (SIGKILL / panic), which this process therefore doesn't
    /// track. Only processes re-parented to launchd (PPID 1) are touched, so a
    /// `pymobiledevice3` you're running yourself in a terminal is left alone.
    /// Returns the number reaped. `lastSweep` says more: in particular which
    /// iPhones may still be on a fake location.
    @discardableResult
    public static func sweepStrays() -> Int {
        sweep().reaped
    }

    /// `sweepStrays`, with the details.
    ///
    /// A classic hold or route playback that is stopped like this has not put
    /// the real location back (only stopping it through the app does), so each
    /// one is reported in `holds`. A live helper does clear by itself when its
    /// parent dies, so it is first given `helperGrace` seconds to finish doing
    /// that before it is interrupted.
    @discardableResult
    public static func sweep(find: () -> [StrayProcess] = findStrays, helperGrace: TimeInterval = 10) -> SweepReport {
        let strays = find()
        guard !strays.isEmpty else {
            sweepLock.lock()
            _lastSweep = .empty
            sweepLock.unlock()
            return .empty
        }

        let helpers = strays.filter { $0.isLiveHelper }
        let deadline = Date().addingTimeInterval(helperGrace)
        while Date() < deadline, helpers.contains(where: { kill($0.pid, 0) == 0 }) { usleep(100_000) }

        for stray in strays { kill(stray.pid, SIGINT) }
        usleep(400_000)
        for stray in strays where kill(stray.pid, 0) == 0 { kill(stray.pid, SIGKILL) }

        var holds: [StrayHold] = []
        for hold in strays.compactMap({ $0.hold }) where !holds.contains(hold) { holds.append(hold) }
        let report = SweepReport(reaped: strays.count, holds: holds)
        sweepLock.lock()
        _lastSweep = report
        sweepLock.unlock()
        return report
    }

    /// The location-simulation processes whose parent is gone (PPID 1).
    public static func findStrays() -> [StrayProcess] {
        var pids = Set<Int32>()
        for pattern in ["pymobiledevice3 developer dvt simulate-location",
                        "pymobiledevice3 developer simulate-location",
                        "iosgpsspoof-live-helper"] {
            guard let out = try? ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/pgrep"),
                                                   arguments: ["-f", pattern], timeout: 10) else { continue }
            for token in out.stdout.split(whereSeparator: { $0 == "\n" || $0 == " " }) {
                if let pid = Int32(token) { pids.insert(pid) }
            }
        }
        let mine = getpid()
        return pids.sorted().filter { $0 != mine && parentPID(of: $0) == 1 }.map {
            StrayProcess(pid: $0, command: commandLine(of: $0) ?? "")
        }
    }

    /// What an iPhone needs after a killed run left it on a fake location.
    public struct Restoration: Sendable {
        /// The iPhones whose real location is back.
        public let restored: [String]
        /// The ones it could not be put back on, with the reason.
        public let failed: [(udid: String, reason: String)]
    }

    /// Put the real location back on each iPhone in `holds`, one clear each.
    public static func restoreLocations(of holds: [StrayHold], using pmd: Pymobiledevice3,
                                        timeout: TimeInterval = 60) -> Restoration {
        var restored: [String] = []
        var failed: [(udid: String, reason: String)] = []
        var done = Set<[String]>()
        for hold in holds where done.insert(hold.clearArguments).inserted {
            do {
                _ = try pmd.run(hold.clearArguments, timeout: timeout)
                if !restored.contains(hold.udid) { restored.append(hold.udid) }
            } catch {
                failed.append((hold.udid, SpoofSession.firstLine(of: error)))
            }
        }
        return Restoration(restored: restored, failed: failed)
    }

    private static func commandLine(of pid: Int32) -> String? {
        guard let result = try? ProcessRunner.run(URL(fileURLWithPath: "/bin/ps"),
                                                  arguments: ["-o", "command=", "-p", String(pid)], timeout: 5) else {
            return nil
        }
        return result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func parentPID(of pid: Int32) -> Int32? {
        guard let result = try? ProcessRunner.run(URL(fileURLWithPath: "/bin/ps"),
                                                  arguments: ["-o", "ppid=", "-p", String(pid)], timeout: 5) else {
            return nil
        }
        return Int32(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
