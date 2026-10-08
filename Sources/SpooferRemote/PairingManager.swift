import CryptoKit
import Foundation
import SpooferCore

/// One-time pairing codes, and the tokens they are exchanged for.
///
/// The Mac shows a 6-digit code. An iPhone that sends it to `POST /pair` gets a
/// random 256-bit token, which it keeps in its Keychain and sends with every
/// request. The Mac stores only the SHA-256 of each token (in a file readable
/// by this user alone), so nothing on disk can be replayed to control it.
///
/// Codes are single-use and rotate after a successful pairing. Five wrong
/// codes within five minutes lock pairing for the rest of that window and
/// burn the current code, so guessing the million possibilities is hopeless.
public final class PairingManager: @unchecked Sendable {
    public struct PairedClient: Codable, Sendable, Identifiable, Equatable {
        /// The iPhone's own stable identifier.
        public var id: String
        public var name: String
        public var tokenHash: String
        public var pairedAt: Date
        public var lastSeen: Date?
    }

    public enum PairingError: Error, Equatable, CustomStringConvertible {
        case wrongCode(attemptsLeft: Int)
        case lockedOut(retryAfter: TimeInterval)

        public var description: String {
            switch self {
            case .wrongCode(let left) where left > 0:
                return "That code isn't right. Check the code shown on the Mac (\(left) attempt\(left == 1 ? "" : "s") left)."
            case .wrongCode:
                return "Too many wrong codes. The Mac has made a new one; try again in a few minutes."
            case .lockedOut(let seconds):
                return "Too many wrong codes. Try again in \(Int(seconds.rounded(.up))) seconds."
            }
        }
    }

    private struct Stored: Codable {
        var serverID: String
        var clients: [PairedClient]
    }

    public static let maxAttempts = 5
    public static let lockoutWindow: TimeInterval = 300

    /// Stable across restarts and shared by the CLI helper and the Mac app,
    /// so a paired iPhone recognises this Mac whichever one is running.
    public let serverID: String
    /// The code rotated or the list of paired iPhones changed.
    public var onChange: (@Sendable () -> Void)?

    private let lock = NSLock()
    private let fileURL: URL
    private var code: String
    private var clients: [PairedClient]
    private var failures: [Date] = []
    private var lastSeenSaved = Date.distantPast

    public static var defaultFileURL: URL {
        AppSupport.directory.appendingPathComponent("remote-pairing.json")
    }

    public init(fileURL: URL = PairingManager.defaultFileURL) {
        self.fileURL = fileURL
        let stored = Self.load(from: fileURL)
        serverID = stored?.serverID ?? UUID().uuidString
        clients = stored?.clients ?? []
        code = Self.makeCode()
        if stored == nil { save() }
    }

    // MARK: - Reading

    public var currentCode: String { locked { code } }

    /// "482 913": easier to read off a screen.
    public var formattedCode: String {
        let c = currentCode
        guard c.count == 6 else { return c }
        return "\(c.prefix(3)) \(c.suffix(3))"
    }

    public var pairedClients: [PairedClient] { locked { clients } }

    // MARK: - Pairing

    /// Exchange a code for a token. Throws `PairingError` for a wrong code.
    public func pair(code attempt: String, clientName: String, clientID: String, now: Date = Date()) throws -> String {
        enum Outcome { case paired(String), wrong(Int, rotated: Bool), locked(TimeInterval) }
        let token = Self.makeToken()
        let outcome = locked { () -> Outcome in
            failures.removeAll { now.timeIntervalSince($0) > Self.lockoutWindow }
            if failures.count >= Self.maxAttempts, let oldest = failures.first {
                return .locked(max(1, Self.lockoutWindow - now.timeIntervalSince(oldest)))
            }
            let digits = String(attempt.filter(\.isNumber))
            guard Self.constantTimeEquals(digits, code) else {
                failures.append(now)
                let left = Self.maxAttempts - failures.count
                if left <= 0 { code = Self.makeCode() }
                return .wrong(max(0, left), rotated: left <= 0)
            }
            failures.removeAll()
            code = Self.makeCode()
            let id = clientID.isEmpty ? UUID().uuidString : String(clientID.prefix(80))
            let name = clientName.trimmingCharacters(in: .whitespacesAndNewlines)
            clients.removeAll { $0.id == id }
            clients.append(PairedClient(id: id, name: name.isEmpty ? "iPhone" : String(name.prefix(64)),
                                        tokenHash: Self.hash(token), pairedAt: now, lastSeen: now))
            return .paired(token)
        }
        switch outcome {
        case .paired(let token):
            save()
            onChange?()
            return token
        case .wrong(let left, let rotated):
            if rotated { onChange?() }
            throw PairingError.wrongCode(attemptsLeft: left)
        case .locked(let seconds):
            throw PairingError.lockedOut(retryAfter: seconds)
        }
    }

    /// The paired iPhone this token belongs to, if any.
    public func authorize(token: String, now: Date = Date()) -> PairedClient? {
        let hashed = Self.hash(token)
        var shouldSave = false
        let client = locked { () -> PairedClient? in
            guard let index = clients.firstIndex(where: { Self.constantTimeEquals($0.tokenHash, hashed) }) else {
                return nil
            }
            clients[index].lastSeen = now
            if now.timeIntervalSince(lastSeenSaved) > 600 {
                lastSeenSaved = now
                shouldSave = true
            }
            return clients[index]
        }
        if shouldSave { save() }
        return client
    }

    @discardableResult
    public func regenerateCode() -> String {
        let new = locked { () -> String in
            code = Self.makeCode()
            failures.removeAll()
            return code
        }
        onChange?()
        return new
    }

    public func revoke(clientID: String) {
        locked { clients.removeAll { $0.id == clientID } }
        save()
        onChange?()
    }

    public func revoke(token: String) {
        let hashed = Self.hash(token)
        locked { clients.removeAll { Self.constantTimeEquals($0.tokenHash, hashed) } }
        save()
        onChange?()
    }

    public func revokeAll() {
        locked { clients.removeAll() }
        save()
        onChange?()
    }

    // MARK: - Storage

    private static func load(from url: URL) -> Stored? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return try? decoder.decode(Stored.self, from: data)
    }

    private func save() {
        let snapshot = locked { Stored(serverID: serverID, clients: clients) }
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        do {
            let fm = FileManager.default
            try fm.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try encoder.encode(snapshot).write(to: fileURL, options: .atomic)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: fileURL.path)
        } catch {
            FileHandle.standardError.write(Data("warning: could not save remote pairing: \(error)\n".utf8))
        }
    }

    // MARK: - Secrets

    static func makeCode() -> String {
        var generator = SystemRandomNumberGenerator()
        return String(format: "%06d", Int.random(in: 0..<1_000_000, using: &generator))
    }

    static func makeToken() -> String {
        var generator = SystemRandomNumberGenerator()
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }

    static func hash(_ token: String) -> String {
        SHA256.hash(data: Data(token.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    static func constantTimeEquals(_ a: String, _ b: String) -> Bool {
        let x = Array(a.utf8), y = Array(b.utf8)
        guard x.count == y.count else { return false }
        var difference: UInt8 = 0
        for i in x.indices { difference |= x[i] ^ y[i] }
        return difference == 0
    }

    private func locked<T>(_ body: () throws -> T) rethrows -> T {
        lock.lock()
        defer { lock.unlock() }
        return try body()
    }
}
