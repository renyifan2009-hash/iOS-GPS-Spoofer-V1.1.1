import Foundation

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

    /// Kill location-simulation processes orphaned by a previous run that was
    /// force-killed (SIGKILL / panic), which this process therefore doesn't
    /// track. Only processes re-parented to launchd (PPID 1) are touched, so a
    /// `pymobiledevice3` you're running yourself in a terminal is left alone.
    /// Returns the number reaped.
    @discardableResult
    public static func sweepStrays() -> Int {
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
        let orphans = pids.filter { $0 != mine && parentPID(of: $0) == 1 }
        for pid in orphans { kill(pid, SIGINT) }
        usleep(400_000)
        for pid in orphans where kill(pid, 0) == 0 { kill(pid, SIGKILL) }
        return orphans.count
    }

    private static func parentPID(of pid: Int32) -> Int32? {
        guard let result = try? ProcessRunner.run(URL(fileURLWithPath: "/bin/ps"),
                                                  arguments: ["-o", "ppid=", "-p", String(pid)], timeout: 5) else {
            return nil
        }
        return Int32(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}
