import Foundation

public struct SpoofError: Error, CustomStringConvertible, LocalizedError {
    public let description: String
    public init(_ description: String) { self.description = description }
    public var errorDescription: String? { description }
}

/// Thin wrapper around the `pymobiledevice3` executable.
///
/// The heavy lifting of talking to iOS 17+ developer services (the encrypted
/// CoreDevice RemoteXPC tunnel, DVT / Instruments channels) lives in
/// pymobiledevice3. This type just locates the binary and shells out to it.
public struct Pymobiledevice3: Sendable {
    public let executableURL: URL
    /// Prepended to every invocation — used to run `python3 -m pymobiledevice3`
    /// when only an interpreter (e.g. a bundled venv) is available.
    public let argPrefix: [String]

    public init(executableURL: URL, argPrefix: [String] = []) {
        self.executableURL = executableURL
        self.argPrefix = argPrefix
    }

    /// Human-readable location, e.g. for a settings screen.
    public var displayPath: String {
        argPrefix.isEmpty ? executableURL.path : "\(executableURL.path) \(argPrefix.joined(separator: " "))"
    }

    /// Locate `pymobiledevice3`.
    ///
    /// Order: explicit path, `$PYMOBILEDEVICE3`, a venv bundled in the .app,
    /// the helper environment `setup.sh` installs in Application Support, a
    /// `.venv` beside the cwd / running binary / repo root, `$PATH`, then the
    /// usual install locations (Homebrew, pipx, `pip --user`) — apps launched
    /// from Finder get a minimal `$PATH` that misses all of those.
    public static func resolve(explicit: String? = nil) throws -> Pymobiledevice3 {
        let fm = FileManager.default

        if let explicit, !explicit.isEmpty {
            let path = (explicit as NSString).expandingTildeInPath
            guard fm.isExecutableFile(atPath: path) else {
                throw SpoofError("not an executable file: \(explicit)")
            }
            return fromExecutable(URL(fileURLWithPath: path))
        }

        if let env = ProcessInfo.processInfo.environment["PYMOBILEDEVICE3"],
           fm.isExecutableFile(atPath: env) {
            return fromExecutable(URL(fileURLWithPath: env))
        }

        // A venv bundled in the .app, then the one setup.sh installs: run them
        // as `python3 -m pymobiledevice3`, so a stale script shebang doesn't
        // matter. (`isExecutableFile` follows the venv's python symlink, so a
        // venv whose base Python was removed is skipped.)
        var environments: [URL] = []
        if let resources = Bundle.main.resourceURL {
            environments.append(resources.appendingPathComponent("venv"))
        }
        environments.append(AppSupport.helperEnvironment)
        for venv in environments {
            let py = venv.appendingPathComponent("bin/python3")
            if fm.isExecutableFile(atPath: py.path), hasPymobiledevice3(venv: venv) {
                return Pymobiledevice3(executableURL: py, argPrefix: ["-m", "pymobiledevice3"])
            }
        }

        var candidates: [URL] = []
        let cwd = fm.currentDirectoryPath
        candidates.append(URL(fileURLWithPath: cwd).appendingPathComponent(".venv/bin/pymobiledevice3"))
        if let exeDir = Bundle.main.executableURL?.resolvingSymlinksInPath().deletingLastPathComponent() {
            candidates.append(exeDir.appendingPathComponent(".venv/bin/pymobiledevice3"))
            candidates.append(exeDir.deletingLastPathComponent().deletingLastPathComponent()
                .appendingPathComponent(".venv/bin/pymobiledevice3"))
        }
        #if DEBUG
        // Run from Xcode the binary lives in DerivedData, so also try the
        // checkout it was built from (this file is Sources/SpooferCore/…).
        let checkout = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        candidates.append(checkout.appendingPathComponent(".venv/bin/pymobiledevice3"))
        #endif
        for c in candidates where fm.isExecutableFile(atPath: c.path) {
            return Pymobiledevice3(executableURL: c)
        }
        if let onPath = which("pymobiledevice3") {
            return fromExecutable(URL(fileURLWithPath: onPath))
        }
        for c in wellKnownLocations() where fm.isExecutableFile(atPath: c.path) {
            return fromExecutable(c)
        }
        throw SpoofError("""
            could not find `pymobiledevice3`.
            Install it by running ./setup.sh in the project folder (or `pipx install pymobiledevice3`),
            or set $PYMOBILEDEVICE3 to its path.
            """)
    }

    /// Whether `venv` (a Python virtual environment) has pymobiledevice3 installed.
    static func hasPymobiledevice3(venv: URL) -> Bool {
        let fm = FileManager.default
        guard fm.fileExists(atPath: venv.appendingPathComponent("pyvenv.cfg").path) else { return false }
        let lib = venv.appendingPathComponent("lib")
        let pythons = (try? fm.contentsOfDirectory(atPath: lib.path)) ?? []
        return pythons.contains { name in
            name.hasPrefix("python") && fm.fileExists(atPath: lib.appendingPathComponent(name)
                .appendingPathComponent("site-packages/pymobiledevice3/__init__.py").path)
        }
    }

    /// The environment for pymobiledevice3 processes: the app's own, without
    /// Python's warnings (Apple's Python 3.9 prints one about LibreSSL on every
    /// run, which would otherwise land in the log).
    public static var childEnvironment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PYTHONWARNINGS"] = "ignore"
        return env
    }

    /// A `pymobiledevice3` script, or a Python interpreter (run as `-m pymobiledevice3`).
    private static func fromExecutable(_ url: URL) -> Pymobiledevice3 {
        let name = url.lastPathComponent
        if name.hasPrefix("python") {
            return Pymobiledevice3(executableURL: url, argPrefix: ["-m", "pymobiledevice3"])
        }
        return Pymobiledevice3(executableURL: url)
    }

    static func wellKnownLocations() -> [URL] {
        let home = URL(fileURLWithPath: NSHomeDirectory())
        var urls = [
            URL(fileURLWithPath: "/opt/homebrew/bin/pymobiledevice3"),
            URL(fileURLWithPath: "/usr/local/bin/pymobiledevice3"),
            home.appendingPathComponent(".local/bin/pymobiledevice3"),
        ]
        // `pip install --user` → ~/Library/Python/3.x/bin
        let userPython = home.appendingPathComponent("Library/Python")
        if let versions = try? FileManager.default.contentsOfDirectory(atPath: userPython.path) {
            for v in versions.sorted(by: >) {
                urls.append(userPython.appendingPathComponent(v).appendingPathComponent("bin/pymobiledevice3"))
            }
        }
        return urls
    }

    /// The Python interpreter that runs this pymobiledevice3, needed by the
    /// live helper. Checks a sibling `python3` (venvs, pipx, Homebrew's
    /// libexec), then the script's shebang.
    public var pythonInterpreter: URL? {
        let fm = FileManager.default
        if argPrefix == ["-m", "pymobiledevice3"] { return executableURL }

        let script = executableURL.resolvingSymlinksInPath()
        let dir = script.deletingLastPathComponent()
        for name in ["python3", "python"] {
            let candidate = dir.appendingPathComponent(name)
            if fm.isExecutableFile(atPath: candidate.path) { return candidate }
        }
        guard let handle = try? FileHandle(forReadingFrom: script) else { return nil }
        defer { try? handle.close() }
        let head: Data? = try? handle.read(upToCount: 512)
        guard let head, let text = String(data: head, encoding: .utf8),
              text.hasPrefix("#!"), let firstLine = text.split(separator: "\n").first else { return nil }
        let parts = firstLine.dropFirst(2).split(separator: " ").map(String.init)
        guard let interpreter = parts.first else { return nil }
        if interpreter.hasSuffix("/env"), parts.count > 1, let resolved = which(parts[1]) {
            return URL(fileURLWithPath: resolved)
        }
        return fm.isExecutableFile(atPath: interpreter) ? URL(fileURLWithPath: interpreter) : nil
    }

    // MARK: - Running

    /// Run to completion, capturing stdout. Throws on non-zero exit or timeout.
    @discardableResult
    public func run(_ args: [String], timeout: TimeInterval? = nil) throws -> String {
        let result = try ProcessRunner.run(executableURL, arguments: argPrefix + args, timeout: timeout,
                                           environment: Self.childEnvironment)
        guard result.status == 0 else {
            throw SpoofError("`pymobiledevice3 \(args.joined(separator: " "))` failed (\(result.status))\n\(result.errorSummary)")
        }
        return result.stdout
    }

    /// Async wrapper for `run`, so callers on the main actor don't block.
    public func runAsync(_ args: [String], timeout: TimeInterval? = nil) async throws -> String {
        try await Task.detached(priority: .utility) { try self.run(args, timeout: timeout) }.value
    }

    /// `pymobiledevice3 version`, or nil if it can't be run.
    public func version() -> String? {
        guard let out = try? run(["version"], timeout: 30) else { return nil }
        let v = out.trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? nil : v
    }

    /// Spawn a long-running process (e.g. `simulate-location set`, which holds
    /// the channel open until it receives SIGINT/SIGTERM). `stderr` is streamed
    /// line-by-line to `onOutput`; `stdout` goes to the parent; `onExit` runs
    /// when it terminates. The caller owns the returned `Process`.
    public func spawn(_ args: [String], onOutput: (@Sendable (String) -> Void)? = nil,
                      onExit: (@Sendable (Process) -> Void)? = nil) throws -> Process {
        let process = Process()
        process.executableURL = executableURL
        process.arguments = argPrefix + args
        process.environment = Self.childEnvironment

        if let onOutput {
            let errPipe = Pipe()
            process.standardError = errPipe
            process.standardOutput = FileHandle.nullDevice
            LineSplitter(onOutput).attach(to: errPipe.fileHandleForReading)
        } else {
            process.standardOutput = FileHandle.standardError
            process.standardError = FileHandle.standardError
        }
        // Installed before launch so even an instant exit is reported.
        process.terminationHandler = { p in
            ChildProcessRegistry.shared.remove(p)
            onExit?(p)
        }
        try process.run()
        ChildProcessRegistry.shared.add(process)
        return process
    }
}

/// Result of a finished child process.
public struct ProcessResult: Sendable {
    public let status: Int32
    public let stdout: String
    public let stderr: String

    /// The most useful part of stderr: error lines if any, else the tail.
    public var errorSummary: String {
        let lines = stderr.split(separator: "\n").map { String($0).trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        let errors = lines.filter { $0.contains("ERROR") || $0.contains("Error") || $0.contains("error:") }
        return (errors.isEmpty ? Array(lines.suffix(6)) : Array(errors.suffix(6))).joined(separator: "\n")
    }
}

public enum ProcessRunner {
    /// Run a process to completion without deadlocking on full pipes (both
    /// streams are drained concurrently) and without pumping a run loop.
    public static func run(_ executable: URL, arguments: [String], timeout: TimeInterval? = nil,
                           environment: [String: String]? = nil) throws -> ProcessResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
        process.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        process.standardOutput = out
        process.standardError = err

        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()

        // Attached after a successful launch so the collector's DispatchGroup
        // is never left unbalanced; output just waits in the pipe meanwhile.
        let collector = OutputCollector()
        collector.attach(out.fileHandleForReading, isStdout: true)
        collector.attach(err.fileHandleForReading, isStdout: false)

        let deadline: DispatchTime = timeout.map { .now() + $0 } ?? .distantFuture
        if exited.wait(timeout: deadline) == .timedOut {
            process.interrupt()
            if exited.wait(timeout: .now() + 2) == .timedOut {
                process.terminate()
                if exited.wait(timeout: .now() + 2) == .timedOut { kill(process.processIdentifier, SIGKILL) }
            }
            throw SpoofError("`\(executable.lastPathComponent) \(arguments.joined(separator: " "))` timed out after \(Int(timeout ?? 0))s")
        }
        collector.waitForEOF(timeout: 3)
        let (stdout, stderr) = collector.strings()
        return ProcessResult(status: process.terminationStatus, stdout: stdout, stderr: stderr)
    }
}

/// Accumulates a child's stdout/stderr from readability handlers.
final class OutputCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var out = Data()
    private var err = Data()
    private let group = DispatchGroup()

    func attach(_ handle: FileHandle, isStdout: Bool) {
        group.enter()
        handle.readabilityHandler = { [self] h in
            let data = h.availableData
            if data.isEmpty {
                h.readabilityHandler = nil
                group.leave()
                return
            }
            lock.lock()
            if isStdout { out.append(data) } else { err.append(data) }
            lock.unlock()
        }
    }

    func waitForEOF(timeout: TimeInterval) {
        _ = group.wait(timeout: .now() + timeout)
    }

    func strings() -> (String, String) {
        lock.lock(); defer { lock.unlock() }
        return (String(decoding: out, as: UTF8.self), String(decoding: err, as: UTF8.self))
    }
}

/// Splits a byte stream into lines, delivering each (without the newline) in
/// order. `finish()` flushes a trailing partial line.
public final class LineSplitter: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var finished = false
    private let done = DispatchSemaphore(value: 0)
    private let onLine: @Sendable (String) -> Void

    public init(_ onLine: @escaping @Sendable (String) -> Void) {
        self.onLine = onLine
    }

    public func attach(to handle: FileHandle) {
        handle.readabilityHandler = { [self] h in
            let data = h.availableData
            if data.isEmpty {
                h.readabilityHandler = nil
                finish()
            } else {
                feed(data)
            }
        }
    }

    public func feed(_ data: Data) {
        lock.lock()
        buffer.append(data)
        var lines: [String] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            lines.append(String(decoding: buffer[buffer.startIndex..<newline], as: UTF8.self))
            buffer.removeSubrange(buffer.startIndex...newline)
        }
        lock.unlock()
        for line in lines { onLine(line.hasSuffix("\r") ? String(line.dropLast()) : line) }
    }

    public func finish() {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        let rest = buffer
        buffer = Data()
        lock.unlock()
        if !rest.isEmpty { onLine(String(decoding: rest, as: UTF8.self)) }
        done.signal()
    }

    /// Block until the stream hit EOF (and every line was delivered).
    @discardableResult
    public func waitUntilFinished(timeout: TimeInterval) -> Bool {
        guard done.wait(timeout: .now() + timeout) == .success else { return false }
        done.signal()   // let later waiters through too
        return true
    }
}

/// `which`, without shelling out to a shell.
public func which(_ name: String) -> String? {
    guard let path = ProcessInfo.processInfo.environment["PATH"] else { return nil }
    for dir in path.split(separator: ":") {
        let candidate = "\(dir)/\(name)"
        if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
    }
    return nil
}
