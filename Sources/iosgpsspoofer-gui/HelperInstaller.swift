import AppKit
import Foundation
import Observation
import SpooferCore

/// Installs, repairs or updates pymobiledevice3 in the app's own Python
/// environment (the one `./setup.sh` makes), so nobody needs Terminal.
@MainActor
@Observable
final class HelperInstaller {
    static let shared = HelperInstaller()

    enum Phase: Equatable {
        case idle
        case working(String)
        /// No Python without Apple's Command Line Tools; install those first.
        case needsDeveloperTools
        case failed(String)
        case finished(version: String)
    }

    var phase: Phase = .idle
    /// The latest line of output, to show that something is happening.
    var detail = ""

    var isWorking: Bool {
        if case .working = phase { return true }
        return false
    }

    private init() {}

    /// Make sure pymobiledevice3 is installed and current. Reuses a working
    /// environment (just upgrading), or builds a fresh one.
    func install() {
        guard !isWorking else { return }
        phase = .working("Looking for Python…")
        detail = ""
        let model = AppModel.shared
        model.appendLog("Installing the iPhone helper (pymobiledevice3)…", level: .info)
        Task {
            let outcome = await Task.detached(priority: .userInitiated) {
                Self.perform(
                    step: { text in Task { @MainActor in HelperInstaller.shared.phase = .working(text) } },
                    output: { line in Task { @MainActor in HelperInstaller.shared.detail = line } })
            }.value
            switch outcome {
            case .installed(let version):
                phase = .finished(version: version)
                detail = ""
                model.appendLog("Installed pymobiledevice3 \(version).", level: .success)
                model.showToast(Toast(symbol: "checkmark.seal.fill", title: "Helper installed",
                                      subtitle: "pymobiledevice3 \(version)", style: .success))
                model.resolveTool()
                await model.refresh()
            case .needsDeveloperTools:
                phase = .needsDeveloperTools
                model.appendLog("Apple's Command Line Tools are needed first (they include Python).", level: .warning)
            case .failed(let message):
                phase = .failed(message)
                model.appendLog("Couldn't install pymobiledevice3: \(message)", level: .error)
            }
        }
    }

    /// Opens Apple's installer for the Command Line Tools.
    func installDeveloperTools() {
        _ = try? ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/xcode-select"), arguments: ["--install"], timeout: 10)
        phase = .idle
        AppModel.shared.showToast(Toast(symbol: "hammer.fill", title: "Follow Apple's installer",
                                        subtitle: "When it's done, click Install again.", style: .info), duration: 6)
    }

    // MARK: - The work (off the main thread)

    enum Outcome: Sendable {
        case installed(String)
        case needsDeveloperTools
        case failed(String)
    }

    nonisolated static func perform(step: @escaping @Sendable (String) -> Void,
                                    output: @escaping @Sendable (String) -> Void) -> Outcome {
        let fm = FileManager.default
        let venv = AppSupport.helperEnvironment
        let python = venv.appendingPathComponent("bin/python3")

        let reuse = fm.isExecutableFile(atPath: python.path)
            && (try? ProcessRunner.run(python, arguments: ["-c", "import sys"], timeout: 30))?.status == 0
        if !reuse {
            let developerTools = hasDeveloperTools()
            guard let base = pickPython(developerTools: developerTools) else {
                return developerTools
                    ? .failed("Python 3.9 or newer wasn't found on this Mac.")
                    : .needsDeveloperTools
            }
            step("Creating a Python environment…")
            try? fm.removeItem(at: venv)
            do {
                try fm.createDirectory(at: venv.deletingLastPathComponent(), withIntermediateDirectories: true)
                let made = try ProcessRunner.run(base, arguments: ["-m", "venv", venv.path], timeout: 180,
                                                 environment: environment)
                guard made.status == 0 else { return .failed(made.errorSummary) }
            } catch {
                return .failed("\(error)")
            }
        }

        step("Updating pip…")
        if case .failure(let failure) = stream(python, ["-m", "pip", "install", "--upgrade", "pip"], output: output) {
            return .failed(failure.message)
        }
        step("Downloading pymobiledevice3…")
        if case .failure(let failure) = stream(python, ["-m", "pip", "install", "--upgrade", "pymobiledevice3"],
                                                output: output) {
            return .failed(failure.message)
        }
        step("Checking it works…")
        guard let result = try? ProcessRunner.run(python, arguments: ["-m", "pymobiledevice3", "version"],
                                                  timeout: 60, environment: environment),
              result.status == 0 else {
            return .failed("pymobiledevice3 was installed but doesn't start.")
        }
        let version = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            .split(separator: "\n").last.map(String.init) ?? "?"
        return .installed(version)
    }

    private nonisolated static var environment: [String: String] {
        var env = Pymobiledevice3.childEnvironment
        env["PIP_DISABLE_PIP_VERSION_CHECK"] = "1"
        env["PIP_NO_INPUT"] = "1"
        return env
    }

    /// `xcode-select -p` points at installed developer tools. (Running
    /// /usr/bin/python3 without them pops up Apple's install prompt.)
    nonisolated static func hasDeveloperTools() -> Bool {
        guard let result = try? ProcessRunner.run(URL(fileURLWithPath: "/usr/bin/xcode-select"), arguments: ["-p"],
                                                  timeout: 10),
              result.status == 0 else { return false }
        let path = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return !path.isEmpty && FileManager.default.fileExists(atPath: path)
    }

    /// The newest Python 3.9+ that can make virtual environments.
    nonisolated static func pickPython(developerTools: Bool) -> URL? {
        var candidates = ["/opt/homebrew/bin/python3", "/usr/local/bin/python3",
                          "/Library/Frameworks/Python.framework/Versions/Current/bin/python3"]
        if developerTools { candidates.append("/usr/bin/python3") }
        var best: (url: URL, minor: Int)?
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            let url = URL(fileURLWithPath: path)
            let probe = "import sys, venv, ensurepip; print(sys.version_info[1] if sys.version_info[0] == 3 else -1)"
            guard let result = try? ProcessRunner.run(url, arguments: ["-c", probe], timeout: 30),
                  result.status == 0,
                  let minor = Int(result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)), minor >= 9 else { continue }
            if minor > (best?.minor ?? -1) { best = (url, minor) }
        }
        return best?.url
    }

    /// Run a command, passing each output line to `output`.
    private nonisolated static func stream(_ executable: URL, _ arguments: [String],
                                           output: @escaping @Sendable (String) -> Void) -> Result<Void, StreamFailure> {
        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        let tail = TailBuffer()
        let lines = LineSplitter { line in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { return }
            tail.append(trimmed)
            output(trimmed)
        }
        lines.attach(to: pipe.fileHandleForReading)
        do {
            try process.run()
        } catch {
            return .failure(StreamFailure(message: "\(error)"))
        }
        process.waitUntilExit()
        lines.waitUntilFinished(timeout: 3)
        guard process.terminationStatus == 0 else {
            let text = tail.text
            let offline = text.contains("Could not find a version") || text.contains("NewConnectionError")
                || text.contains("Failed to establish a new connection") || text.contains("Temporary failure")
            return .failure(StreamFailure(message: offline
                ? "Couldn't download it. Check the Mac's internet connection and try again."
                : text))
        }
        return .success(())
    }

    struct StreamFailure: Error {
        let message: String
    }
}

/// The last few lines of a process's output, for error messages.
private final class TailBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []

    func append(_ line: String) {
        lock.lock()
        lines.append(line)
        if lines.count > 8 { lines.removeFirst(lines.count - 8) }
        lock.unlock()
    }

    var text: String {
        lock.lock()
        defer { lock.unlock() }
        return lines.joined(separator: "\n")
    }
}
