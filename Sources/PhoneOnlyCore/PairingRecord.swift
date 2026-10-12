import Foundation

/// The pairing file for SpoofRemote's iPhone-only mode, as both sides read it:
/// the Mac app writes it (File ▸ Pairing File for the iPhone App…) and SpoofRemote
/// opens it on the iPhone. See docs/PHONE-ONLY.md.
///
/// One property list can hold two identities:
///
/// - A **lockdown record**: the certificates the iPhone gave the Mac when you
///   tapped Trust. The app uses it to reach lockdown (port 62078) and open the
///   tunnel with CoreDeviceProxy. Newer iOS versions no longer answer lockdown
///   through LocalDevVPN, so this half alone isn't enough there.
/// - A **Remote Pairing identity**: an Ed25519 key and the name the iPhone
///   knows it by (`public_key`, `private_key`, `identifier`, and sometimes
///   `alt_irk`). The app uses it to pair-verify with remotepairingd and open
///   its tunnel. This is the half newer iOS versions need.
///
/// A file needs at least one of them. idevice reads each half by its own keys
/// and ignores the rest, so the whole file goes to either parser as it is.
public struct PairingRecord: Equatable, Sendable {
    public enum Problem: Error, Equatable, Sendable {
        /// Not a property list with a dictionary at the top.
        case notAPropertyList
        /// A property list, but with neither identity in it.
        case noIdentity
    }

    /// The key an app shows remotepairingd to prove it's a computer the iPhone paired with.
    public struct RemotePairingIdentity: Equatable, Sendable {
        /// Ed25519, 32 bytes.
        public var publicKey: Data
        /// Ed25519 seed, 32 bytes.
        public var privateKey: Data
        /// The name the iPhone filed the key under.
        public var identifier: String
        /// The iPhone's key for recognising it on the network, when known.
        public var altIRK: Data?

        public init(publicKey: Data, privateKey: Data, identifier: String, altIRK: Data? = nil) {
            self.publicKey = publicKey
            self.privateKey = privateKey
            self.identifier = identifier
            self.altIRK = altIRK
        }

        static let keyLength = 32

        /// Nil unless the dictionary has every part, in the type and size idevice wants.
        init?(_ dictionary: [String: Any]) {
            guard let publicKey = dictionary[Key.publicKey] as? Data, publicKey.count == Self.keyLength,
                  let privateKey = dictionary[Key.privateKey] as? Data, privateKey.count == Self.keyLength,
                  let identifier = dictionary[Key.identifier] as? String, !identifier.isEmpty else { return nil }
            self.init(publicKey: publicKey, privateKey: privateKey, identifier: identifier,
                      altIRK: dictionary[Key.altIRK] as? Data)
        }

        var dictionary: [String: Any] {
            var dictionary: [String: Any] = [
                Key.publicKey: publicKey,
                Key.privateKey: privateKey,
                Key.identifier: identifier,
            ]
            if let altIRK { dictionary[Key.altIRK] = altIRK }
            return dictionary
        }
    }

    /// The names idevice's RPPairing file reader looks for.
    enum Key {
        static let publicKey = "public_key"
        static let privateKey = "private_key"
        static let identifier = "identifier"
        static let altIRK = "alt_irk"
        static let remotePairing = [publicKey, privateKey, identifier, altIRK]
    }

    /// What idevice's lockdown pairing file reader requires.
    private static let lockdownData = ["DeviceCertificate", "HostCertificate", "HostPrivateKey",
                                       "RootCertificate", "RootPrivateKey"]
    private static let lockdownStrings = ["HostID", "SystemBUID", "WiFiMACAddress"]

    /// The file's bytes, as given.
    public let data: Data
    public let hasLockdownRecord: Bool
    public let remotePairing: RemotePairingIdentity?

    public var hasRemotePairingIdentity: Bool { remotePairing != nil }

    public init(data: Data) throws {
        let dictionary = try Self.dictionary(from: data)
        let hasLockdownRecord = Self.hasLockdownRecord(dictionary)
        let remotePairing = RemotePairingIdentity(dictionary)
        guard hasLockdownRecord || remotePairing != nil else { throw Problem.noIdentity }
        self.data = data
        self.hasLockdownRecord = hasLockdownRecord
        self.remotePairing = remotePairing
    }

    /// The same file with this Remote Pairing identity in place of whatever it
    /// had. The lockdown record, and anything else in the file, stays.
    public func settingRemotePairing(_ identity: RemotePairingIdentity) throws -> PairingRecord {
        var dictionary = try Self.dictionary(from: data)
        for key in Key.remotePairing { dictionary[key] = nil }
        dictionary.merge(identity.dictionary) { _, new in new }
        return try PairingRecord(data: PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml,
                                                                      options: 0))
    }

    /// For the bytes idevice hands back after trying to connect: it pairs
    /// again by itself when the iPhone no longer knows the identity, and the
    /// new keys have to be kept or the next connection pairs once more.
    /// Returns the updated file, or nil when there's nothing to keep:
    /// `identityFile` has the identity this file already has (the usual
    /// case), or isn't a usable identity, or holds keys the iPhone never
    /// took.
    ///
    /// That last case is for `tunnelOpened == false`. idevice makes the new
    /// keys before it sends them, so after a failure they may be keys nobody
    /// knows. It records the iPhone's `alt_irk` only once the iPhone has
    /// answered with its own identity, which is after it stored the keys. So
    /// without a tunnel, only an identity with an `alt_irk` is kept.
    public func adoptingRemotePairing(from identityFile: Data, tunnelOpened: Bool) -> PairingRecord? {
        guard let dictionary = try? Self.dictionary(from: identityFile),
              let identity = RemotePairingIdentity(dictionary),
              identity.privateKey != remotePairing?.privateKey || identity.identifier != remotePairing?.identifier,
              tunnelOpened || identity.altIRK != nil else { return nil }
        return try? settingRemotePairing(identity)
    }

    private static func dictionary(from data: Data) throws -> [String: Any] {
        guard let dictionary = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any]
        else { throw Problem.notAPropertyList }
        return dictionary
    }

    private static func hasLockdownRecord(_ dictionary: [String: Any]) -> Bool {
        lockdownData.allSatisfy { !((dictionary[$0] as? Data)?.isEmpty ?? true) }
            && lockdownStrings.allSatisfy { !((dictionary[$0] as? String)?.isEmpty ?? true) }
    }
}
