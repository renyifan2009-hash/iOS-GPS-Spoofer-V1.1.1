import Foundation

public struct SpoofError: Error, CustomStringConvertible, LocalizedError {
    public let description: String
    /// For an error whose text starts with a long technical line (a command
    /// line), the short plain reason a person should read instead. Nil when
    /// `description` already reads that way.
    public let reason: String?
    public init(_ description: String, reason: String? = nil) {
        self.description = description
        self.reason = reason
    }
    public var errorDescription: String? { reason ?? description }
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
            guard isRunnableFile(path) else {
                throw SpoofError("not an executable file: \(explicit)")
            }
            return fromExecutable(URL(fileURLWithPath: path))
        }

        if let env = ProcessInfo.processInfo.environment["PYMOBILEDEVICE3"],
           isRunnableFile(env) {
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
        // An earlier version's environment, under the product's old name.
        environments.append(AppSupport.legacyHelperEnvironment)
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

    /// A file (not a folder: folders carry the "executable" bit too) that can be run.
    static func isRunnableFile(_ path: String) -> Bool {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory), !isDirectory.boolValue else {
            return false
        }
        return FileManager.default.isExecutableFile(atPath: path)
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
            for v in newestFirst(versions) {
                urls.append(userPython.appendingPathComponent(v).appendingPathComponent("bin/pymobiledevice3"))
            }
        }
        return urls
    }

    /// Python version folder names ("3.9", "3.13") newest first. Plain string
    /// order would put "3.9" above "3.13".
    static func newestFirst(_ versions: [String]) -> [String] {
        versions.sorted { $0.compare($1, options: .numeric) == .orderedDescending }
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
        let head: Data? = try? handle.read(upToCount: 1024)
        guard let head, let text = String(data: head, encoding: .utf8),
              text.hasPrefix("#!"), let firstLine = text.split(separator: "\n").first else { return nil }
        let parts = firstLine.dropFirst(2).split(separator: " ").map(String.init)
        guard let interpreter = parts.first else { return nil }
        if interpreter.hasSuffix("/env"), parts.count > 1, let resolved = which(parts[1]) {
            return URL(fileURLWithPath: resolved)
        }
        if Self.shells.contains(URL(fileURLWithPath: interpreter).lastPathComponent) {
            // pip writes `#!/bin/sh` for an environment whose path has a space
            // in it, and has the real Python started on the next line. A shell
            // is never the answer: running the helper with it would fail.
            return Self.interpreter(fromShellScript: text)
        }
        return fm.isExecutableFile(atPath: interpreter) ? URL(fileURLWithPath: interpreter) : nil
    }

    private static let shells: Set<String> = ["sh", "bash", "zsh", "dash", "ksh"]

    /// The Python named by the second line of a pip console script that starts
    /// with a shell line: `'''exec' "/path with spaces/python3" "$0" "$@"`.
    static func interpreter(fromShellScript text: String) -> URL? {
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.count > 1 else { return nil }
        let marker = "'''exec' \""
        let second = lines[1].trimmingCharacters(in: .whitespaces)
        guard second.hasPrefix(marker) else { return nil }
        let rest = second.dropFirst(marker.count)
        guard let end = rest.firstIndex(of: "\"") else { return nil }
        let path = String(rest[rest.startIndex..<end])
        guard !shells.contains(URL(fileURLWithPath: path).lastPathComponent),
              FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return URL(fileURLWithPath: path)
    }

    // MARK: - Running

    /// Run to completion, capturing stdout. Throws on non-zero exit or timeout.
    @discardableResult
    public func run(_ args: [String], timeout: TimeInterval? = nil) throws -> String {
        let result = try ProcessRunner.run(executableURL, arguments: argPrefix + args, timeout: timeout,
                                           environment: Self.childEnvironment)
        guard result.status == 0 else {
            // The text keeps the command line (it helps in a bug report). What a
            // person reads is `reason`: see `SpoofSession.firstLine(of:)`.
            throw SpoofError("`pymobiledevice3 \(args.joined(separator: " "))` failed (\(result.status))\n\(result.errorSummary)",
                             reason: result.errorReason ?? "pymobiledevice3 stopped with status \(result.status)")
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

        var errorLines: LineSplitter?
        if let onOutput {
            let errPipe = Pipe()
            process.standardError = errPipe
            process.standardOutput = FileHandle.nullDevice
            let splitter = LineSplitter(onOutput)
            splitter.attach(to: errPipe.fileHandleForReading)
            errorLines = splitter
        } else {
            process.standardOutput = FileHandle.standardError
            process.standardError = FileHandle.standardError
        }
        // Installed before launch so even an instant exit is reported.
        process.terminationHandler = { [errorLines] p in
            ChildProcessRegistry.shared.remove(p)
            // The last thing a failing command prints is why it failed. Let it
            // arrive before the exit is reported, or the reason can be missed.
            errorLines?.waitUntilFinished(timeout: 1)
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

    public init(status: Int32, stdout: String, stderr: String) {
        self.status = status
        self.stdout = stdout
        self.stderr = stderr
    }

    /// The most useful part of stderr: error lines if any, else the tail.
    /// Rich error boxes (how pymobiledevice3 prints a bad command line) are
    /// read as the plain lines inside them.
    public var errorSummary: String {
        let reading = ToolStderr.read(stderr)
        let errors = reading.lines.filter { reading.panel.contains($0) || ToolStderr.looksLikeError($0) }
        return (errors.isEmpty ? Array(reading.lines.suffix(6)) : Array(errors.suffix(6))).joined(separator: "\n")
    }

    /// One plain line saying what went wrong, or nil when stderr says nothing.
    /// A person can read it as it is: no command line, no log prefix.
    public var errorReason: String? {
        let reading = ToolStderr.read(stderr)
        if !reading.panel.isEmpty { return reading.panel.joined(separator: " ") }
        let line = reading.lines.last(where: { ToolStderr.looksLikeError($0) }) ?? reading.lines.last
        guard let line else { return nil }
        let cleaned = SpoofSession.cleanLogLine(line).trimmingCharacters(in: .whitespaces)
        return cleaned.isEmpty ? nil : cleaned
    }
}

/// Reads what pymobiledevice3 prints on stderr.
///
/// Its command-line errors (`No such option: --bogus`) come as a Rich box:
///
///     ╭─ Error ─────────────────╮
///     │ No such option: --bogus │
///     ╰─────────────────────────╯
///
/// Those rows hold the reason but contain no word like "ERROR", so a plain
/// keyword filter drops them. The same box is drawn with `+`, `-` and `|`
/// when the terminal can't show the line-drawing characters.
enum ToolStderr {
    private static let boxTop: [Character] = ["╭", "┌", "┏", "╔"]
    private static let boxBottom: [Character] = ["╰", "└", "┗", "╚"]
    private static let boxSide: [Character] = ["│", "┃", "║", "|"]
    private static let boxDrawing = CharacterSet(charactersIn: "─━│┃║╭╮╰╯┌┐└┘┏┓┗┛╔╗╚╝|+ \t\r")

    /// - lines: every non-empty line, trimmed, with the rows of an error box
    ///   turned into plain lines (other boxes, like help text, are skipped).
    /// - panel: just the rows that came from an error box.
    static func read(_ stderr: String) -> (lines: [String], panel: [String]) {
        enum Box { case none, error, other }
        var box = Box.none
        var lines: [String] = []
        var panel: [String] = []
        for raw in stderr.split(whereSeparator: { $0 == "\n" }) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard let first = line.first else { continue }
            if boxTop.contains(first) || (line.hasPrefix("+-") && box == .none) {
                box = line.lowercased().contains("error") ? .error : .other
                continue
            }
            if boxBottom.contains(first) || (line.hasPrefix("+-") && box != .none) {
                box = .none
                continue
            }
            if box != .none, boxSide.contains(first) {
                let inner = line.trimmingCharacters(in: boxDrawing)
                if box == .error, !inner.isEmpty {
                    panel.append(inner)
                    lines.append(inner)
                }
                continue
            }
            lines.append(line)
        }
        return (lines, panel)
    }

    static func looksLikeError(_ line: String) -> Bool {
        line.contains("ERROR") || line.contains("Error") || line.contains("error:")
    }

    /// A line with any box-drawing characters at its ends removed.
    static func stripBox(_ line: String) -> String {
        line.trimmingCharacters(in: boxDrawing)
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
            let seconds = Int(timeout ?? 0)
            throw SpoofError("`\(executable.lastPathComponent) \(arguments.joined(separator: " "))` timed out after \(seconds)s",
                             reason: "\(executable.lastPathComponent) didn't answer within \(seconds == 1 ? "1 second" : "\(seconds) seconds")")
        }
        collector.waitForEOF(timeout: 3)
        let (stdout, stderr) = collector.strings()
        return ProcessResult(status: process.terminationStatus, stdout: stdout, stderr: stderr)
    }

    /// What `stream` saw.
    public struct StreamResult: Sendable {
        public let status: Int32
        /// The last few lines the command printed (both streams, trimmed).
        public let tail: [String]
        /// It ran past the deadline and was stopped.
        public let timedOut: Bool
    }

    /// Run a process, passing each output line (stdout and stderr together) to
    /// `onLine` as it arrives, and stop it if it runs longer than `timeout`.
    /// Throws only when the process can't be started.
    public static func stream(_ executable: URL, arguments: [String], environment: [String: String]? = nil,
                              timeout: TimeInterval,
                              onLine: @escaping @Sendable (String) -> Void) throws -> StreamResult {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        if let environment { process.environment = environment }
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe

        let tail = LineTail(limit: 8)
        let lines = LineSplitter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return }
            tail.append(trimmed)
            onLine(trimmed)
        }
        lines.attach(to: pipe.fileHandleForReading)
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        try process.run()

        var timedOut = false
        if exited.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            process.interrupt()
            if exited.wait(timeout: .now() + 3) == .timedOut {
                process.terminate()
                if exited.wait(timeout: .now() + 2) == .timedOut { kill(process.processIdentifier, SIGKILL) }
            }
        }
        lines.waitUntilFinished(timeout: 3)
        return StreamResult(status: process.isRunning ? -1 : process.terminationStatus, tail: tail.lines, timedOut: timedOut)
    }
}

/// The last few lines of a stream, for error messages.
final class LineTail: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: [String] = []
    private let limit: Int

    init(limit: Int) { self.limit = limit }

    func append(_ line: String) {
        lock.lock()
        stored.append(line)
        if stored.count > limit { stored.removeFirst(stored.count - limit) }
        lock.unlock()
    }

    var lines: [String] {
        lock.lock()
        defer { lock.unlock() }
        return stored
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

/// A pymobiledevice3 version such as `11.25.0`.
public struct ToolVersion: Comparable, Sendable, CustomStringConvertible {
    public let parts: [Int]

    /// Reads the first dotted number in `text` (so "pymobiledevice3 11.25.0\n"
    /// works too). Nil when there isn't one.
    public init?(_ text: String) {
        for word in text.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }) {
            let numbers = word.split(separator: ".", omittingEmptySubsequences: false).map { Int($0) }
            if numbers.count >= 2, numbers.allSatisfy({ $0 != nil }) {
                parts = numbers.compactMap { $0 }
                return
            }
        }
        return nil
    }

    public var description: String { parts.map(String.init).joined(separator: ".") }

    public static func < (a: ToolVersion, b: ToolVersion) -> Bool {
        for i in 0..<max(a.parts.count, b.parts.count) {
            let x = i < a.parts.count ? a.parts[i] : 0
            let y = i < b.parts.count ? b.parts[i] : 0
            if x != y { return x < y }
        }
        return false
    }

    public static func == (a: ToolVersion, b: ToolVersion) -> Bool { !(a < b) && !(b < a) }

    /// The oldest release that has `--userspace` (its own tunnel, used for
    /// iOS 17.4 and later).
    public static let userspaceFloor = ToolVersion("9.30.0")!
    /// The oldest release that has `--native` (Apple's tunnel, used for iOS
    /// 17.0 to 17.3).
    public static let nativeFloor = ToolVersion("11.0.0")!
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
