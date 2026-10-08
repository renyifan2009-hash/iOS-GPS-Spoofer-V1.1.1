import Foundation

/// The "live" engine: a small Python helper (see `LiveHelperScript.swift`) that
/// runs pymobiledevice3's own `simulate-location set` command but keeps the
/// location channel open, taking new coordinates over stdin. Moving the device
/// then costs one message instead of a whole new tunnel — which is what makes
/// smooth routes, pause/resume and joystick control possible.
public enum LiveHelper {
    public static let linePrefix = "@@spoof "
    public static let incompatibleExitStatus: Int32 = 86

    /// A line the helper printed on stdout.
    public enum Message: Equatable, Sendable {
        case ready(GeoPoint)
        case ok(GeoPoint)
        case cleared
        case pong
        case bye
        case error(String)
        case probe(version: String, protocolVersion: Int)
        case incompatible(String)
        case exit(Int32)
    }

    public static func parse(line: String) -> Message? {
        guard line.hasPrefix(linePrefix) else { return nil }
        let body = line.dropFirst(linePrefix.count).trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = body.split(separator: " ", maxSplits: 1).map(String.init)
        guard let kind = parts.first else { return nil }
        let rest = parts.count > 1 ? parts[1] : ""

        func point() -> GeoPoint? {
            let xy = rest.split(separator: " ").compactMap { Double($0) }
            return xy.count == 2 ? GeoPoint(xy[0], xy[1]) : nil
        }
        switch kind {
        case "READY": return point().map(Message.ready)
        case "OK": return point().map(Message.ok)
        case "CLEARED": return .cleared
        case "PONG": return .pong
        case "BYE": return .bye
        case "ERROR": return .error(rest)
        case "INCOMPATIBLE": return .incompatible(rest)
        case "EXIT": return Int32(rest).map(Message.exit)
        case "PROBE":
            let fields = rest.split(separator: " ").map(String.init)
            guard fields.count == 2, let proto = Int(fields[1]) else { return nil }
            return .probe(version: fields[0], protocolVersion: proto)
        default: return nil
        }
    }

    /// The `set` command line for a coordinate.
    public static func setCommand(_ point: GeoPoint) -> String {
        "set \(point.latitude) \(point.longitude)\n"
    }

    // MARK: - Installation

    /// Writes the script (once per version of its contents) and returns its
    /// path. The file name carries a content hash, so an app update never runs
    /// a stale copy, and `iosgpsspoof-live-helper` lets stray-process sweeps
    /// recognise it.
    public static func installedScriptURL() throws -> URL {
        let name = "iosgpsspoof-live-helper-v\(protocolVersion)-\(contentHash).py"
        var lastError: Error?
        for dir in [AppSupport.directory.appendingPathComponent("helpers", isDirectory: true),
                    FileManager.default.temporaryDirectory] {
            let url = dir.appendingPathComponent(name)
            if let existing = try? String(contentsOf: url, encoding: .utf8), existing == script {
                return url
            }
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                try script.write(to: url, atomically: true, encoding: .utf8)
                return url
            } catch {
                lastError = error
            }
        }
        throw SpoofError("could not install the live helper script: \(lastError.map { "\($0)" } ?? "unknown error")")
    }

    /// FNV-1a of the script, as 8 hex digits.
    static var contentHash: String {
        var hash: UInt32 = 0x811C_9DC5
        for byte in script.utf8 {
            hash ^= UInt32(byte)
            hash = hash &* 0x0100_0193
        }
        let hex = String(hash, radix: 16)
        return String(repeating: "0", count: max(0, 8 - hex.count)) + hex
    }

    // MARK: - Probe

    public enum Availability: Equatable, Sendable {
        /// The live engine can drive this pymobiledevice3.
        case supported(pymobiledevice3Version: String)
        /// It can't; the classic engine will be used.
        case unsupported(reason: String)

        public var isSupported: Bool {
            if case .supported = self { return true }
            return false
        }
    }

    /// Check that `python` can import pymobiledevice3 and that the classes the
    /// helper patches exist. Takes a second or two (pymobiledevice3's import).
    public static func probe(python: URL?, timeout: TimeInterval = 90) -> Availability {
        guard let python else {
            return .unsupported(reason: "couldn't determine which Python runs pymobiledevice3")
        }
        let script: URL
        do { script = try installedScriptURL() } catch {
            return .unsupported(reason: "\(error)")
        }
        let result: ProcessResult
        do {
            result = try ProcessRunner.run(python, arguments: ["-u", script.path, "--probe"], timeout: timeout,
                                           environment: helperEnvironment())
        } catch {
            return .unsupported(reason: "\(error)")
        }
        for line in result.stdout.split(separator: "\n") {
            switch parse(line: String(line)) {
            case let .probe(version, proto)?:
                guard proto == protocolVersion else {
                    return .unsupported(reason: "helper protocol mismatch (\(proto) ≠ \(protocolVersion))")
                }
                return .supported(pymobiledevice3Version: version)
            case let .incompatible(reason)?:
                return .unsupported(reason: reason)
            default:
                continue
            }
        }
        let detail = result.errorSummary.isEmpty ? "exit status \(result.status)" : result.errorSummary
        return .unsupported(reason: "probe failed: \(detail)")
    }

    /// Environment for helper processes: unbuffered UTF-8 I/O, no colour codes.
    public static func helperEnvironment() -> [String: String] {
        var env = Pymobiledevice3.childEnvironment
        env["PYTHONUNBUFFERED"] = "1"
        env["PYTHONIOENCODING"] = "utf-8"
        env["NO_COLOR"] = "1"
        env["TERM"] = "dumb"
        return env
    }
}
