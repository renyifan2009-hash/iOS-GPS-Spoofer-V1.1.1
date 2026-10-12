import Foundation
import PhoneOnlyCore

/// A paired iOS device as reported by `pymobiledevice3 usbmux list`.
public struct Device: Codable, Identifiable, Hashable, Sendable {
    public let deviceName: String
    public let identifier: String
    public let connectionType: String
    public let productType: String
    public let productVersion: String

    enum CodingKeys: String, CodingKey {
        case deviceName = "DeviceName"
        case identifier = "Identifier"
        case connectionType = "ConnectionType"
        case productType = "ProductType"
        case productVersion = "ProductVersion"
    }

    public init(deviceName: String, identifier: String, connectionType: String,
                productType: String, productVersion: String) {
        self.deviceName = deviceName
        self.identifier = identifier
        self.connectionType = connectionType
        self.productType = productType
        self.productVersion = productVersion
    }

    /// Tolerates missing fields: a device that hasn't been trusted yet reports
    /// little more than its UDID.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        identifier = try c.decode(String.self, forKey: .identifier)
        deviceName = (try? c.decodeIfPresent(String.self, forKey: .deviceName)) ?? "iOS device"
        connectionType = (try? c.decodeIfPresent(String.self, forKey: .connectionType)) ?? "USB"
        productType = (try? c.decodeIfPresent(String.self, forKey: .productType)) ?? "unknown"
        productVersion = (try? c.decodeIfPresent(String.self, forKey: .productVersion)) ?? "0"
    }

    public var id: String { identifier }
    public var udid: String { identifier }

    /// Major iOS version, e.g. `18` for `"18.5"` (0 when unknown).
    public var majorVersion: Int {
        Int(productVersion.split(separator: ".").first ?? "") ?? 0
    }

    /// iOS 16 and older: location simulation goes through the lockdown
    /// `com.apple.dt.simulatelocation` service instead of the CoreDevice tunnel.
    public var isLegacy: Bool { majorVersion > 0 && majorVersion < 17 }

    /// Minor iOS version, e.g. `4` for `"17.4.1"` (0 when unknown).
    public var minorVersion: Int {
        let parts = productVersion.split(separator: ".")
        return parts.count > 1 ? Int(parts[1]) ?? 0 : 0
    }

    /// iOS 17.4 and later can open pymobiledevice3's own (userspace) tunnel.
    public var supportsUserspaceTunnel: Bool {
        majorVersion > 17 || (majorVersion == 17 && minorVersion >= 4)
    }

    public var connectionLabel: String { connectionType.lowercased() }
    public var isUSB: Bool { connectionLabel == "usb" }

    public var summary: String {
        "\(deviceName) — iOS \(productVersion) (\(modelName), \(connectionLabel))"
    }

    /// Marketing name when known ("iPhone 15 Pro"), else the identifier.
    public var modelName: String { DeviceModels.marketingName(for: productType) ?? productType }

    /// SF Symbol for the device family.
    public var symbolName: String {
        if productType.hasPrefix("iPad") { return "ipad" }
        if productType.hasPrefix("iPod") { return "ipodtouch" }
        return "iphone"
    }
}

public enum ConnectionFilter: String, CaseIterable, Sendable {
    case any, usb, network

    public func matches(_ device: Device) -> Bool {
        switch self {
        case .any: return true
        case .usb: return device.connectionType.lowercased() == "usb"
        case .network: return device.connectionType.lowercased() == "network"
        }
    }
}

extension Pymobiledevice3 {
    /// All currently reachable paired devices, de-duplicated by UDID (a device
    /// paired over both USB and Wi-Fi is listed once, preferring the USB link).
    public func listDevices() throws -> [Device] {
        let json = try run(["usbmux", "list"], timeout: 20)
        let trimmed = json.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let data = trimmed.data(using: .utf8) else { return [] }
        let raw = try JSONDecoder().decode([Device].self, from: data)

        var byUDID: [String: Device] = [:]
        for device in raw {
            if let existing = byUDID[device.udid] {
                if !existing.isUSB && device.isUSB { byUDID[device.udid] = device }
            } else {
                byUDID[device.udid] = device
            }
        }
        // Preserve first-seen order.
        var seen = Set<String>()
        return raw.compactMap { d in
            guard seen.insert(d.udid).inserted else { return nil }
            return byUDID[d.udid]
        }
    }

    public func listDevicesAsync() async throws -> [Device] {
        try await Task.detached(priority: .utility) { try self.listDevices() }.value
    }

    /// Pick the target device: the one matching `udid` if given, otherwise the
    /// first that satisfies `connection`.
    public func selectDevice(udid: String?, connection: ConnectionFilter) throws -> Device {
        let devices = try listDevices()
        guard !devices.isEmpty else {
            throw SpoofError("no paired iOS devices found. Connect an iPhone and trust this computer.")
        }
        if let udid {
            guard let match = devices.first(where: { $0.udid == udid }) else {
                let known = devices.map { "  \($0.udid)  \($0.summary)" }.joined(separator: "\n")
                throw SpoofError("no device with UDID \(udid). Known devices:\n\(known)")
            }
            return match
        }
        let filtered = devices.filter { connection.matches($0) }
        guard let chosen = filtered.first else {
            throw SpoofError("no device matches connection filter '\(connection.rawValue)'.")
        }
        return chosen
    }

    /// What `exportPairingFile` saved.
    public struct PairingExport: Sendable {
        public let url: URL
        /// Why the file has no Remote Pairing identity, or nil when it has
        /// one. Without it the file only works where the iPhone still answers
        /// lockdown through LocalDevVPN, which newer iOS versions don't.
        public let remotePairingProblem: String?

        public var worksOnEveryIOSVersion: Bool { remotePairingProblem == nil }
    }

    /// Write the iPhone's pairing file to `url`, for the SpoofRemote app on
    /// the iPhone itself to reach its own developer services (see
    /// docs/PHONE-ONLY.md).
    ///
    /// The file lets whoever holds it act as this Mac towards the iPhone:
    /// give it only to that iPhone. It's saved readable by this user only.
    ///
    /// It holds two identities (`PairingRecord` has the format):
    /// - The lockdown record. Saving it also turns on lockdown's Wi-Fi
    ///   connections, so lockdown listens on the network, which is how the app
    ///   reaches it. Newer iOS versions don't answer lockdown there
    ///   (StikDebug and SideStore moved off it for iOS 26.4).
    /// - A Remote Pairing identity, made over USB, which the app uses to open
    ///   the tunnel through remotepairingd instead. That works on every iOS
    ///   version the iPhone-only mode supports.
    ///
    /// Throws when there's no lockdown record to save. When only the Remote
    /// Pairing identity can't be made, the file is still saved and the result
    /// says why, so the caller can tell the user.
    @discardableResult
    public func exportPairingFile(udid: String, to url: URL) throws -> PairingExport {
        _ = try? run(["lockdown", "wifi-connections", "on", "--udid", udid], timeout: 30)
        try? FileManager.default.removeItem(at: url)
        _ = try run(["lockdown", "save-pair-record", url.path, "--udid", udid], timeout: 30)
        // A key to the iPhone: no other user of this Mac should read it.
        let protect = { _ = try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path) }
        protect()
        // save-pair-record only logs "no pairing record was found" and exits 0.
        guard let data = try? Data(contentsOf: url), !data.isEmpty else {
            try? FileManager.default.removeItem(at: url)
            throw SpoofError("this Mac has no pairing record for the iPhone. Unplug it, plug it back in, tap Trust, then try again.")
        }
        guard let lockdown = try? PairingRecord(data: data), lockdown.hasLockdownRecord else {
            try? FileManager.default.removeItem(at: url)
            throw SpoofError("the pairing record pymobiledevice3 saved for the iPhone is incomplete. Unplug the iPhone, plug it back in, tap Trust, then try again.")
        }
        do {
            let record = try lockdown.settingRemotePairing(try remotePairingIdentity(udid: udid))
            try record.data.write(to: url, options: .atomic)
            // Written as a new file, with the usual permissions again.
            protect()
            return PairingExport(url: url, remotePairingProblem: nil)
        } catch {
            return PairingExport(url: url, remotePairingProblem: SpoofSession.firstLine(of: error))
        }
    }

    /// Pairs this Mac with the iPhone's remotepairingd over USB lockdown (no
    /// Trust prompt, since USB is already trusted) and returns the identity.
    /// Re-uses pymobiledevice3's record if this Mac already paired. The work
    /// is `RemotePairingScript`, run by pymobiledevice3's own Python.
    func remotePairingIdentity(udid: String) throws -> PairingRecord.RemotePairingIdentity {
        guard let python = pythonInterpreter else {
            throw SpoofError("can't find the Python that runs pymobiledevice3")
        }
        let result: ProcessResult
        do {
            result = try ProcessRunner.run(python, arguments: ["-c", RemotePairingScript.script, udid],
                                           timeout: 60, environment: Self.childEnvironment)
        } catch {
            // The runner's own message quotes the whole command, script and all.
            throw SpoofError("pymobiledevice3's Python didn't finish (unlock the iPhone and keep it plugged in)")
        }
        switch RemotePairingScript.parse(result.stdout) {
        case .success(let identity):
            return identity
        case .failure(let reason) where result.stdout.contains(RemotePairingScript.prefix):
            throw reason
        case .failure:
            // The script died before it could say why (a crash on import, say).
            let summary = result.errorSummary
            throw SpoofError(summary.isEmpty ? "pymobiledevice3's Python stopped with status \(result.status)" : summary)
        }
    }

    /// Is a device with this UDID currently reachable?
    public func isPresent(udid: String, connection: ConnectionFilter = .any) -> Bool {
        guard let devices = try? listDevices() else { return false }
        return devices.contains { $0.udid == udid && connection.matches($0) }
    }

    /// The version of SpoofRemote (`com.iosgpsspoof.remote`) installed on the
    /// iPhone, or nil when it isn't installed. The Mac compares it with
    /// `SpoofRemote.expected` to warn when the iPhone app is out of date (see
    /// docs/PHONE-ONLY.md).
    ///
    /// It reads `apps list`, whose JSON is keyed by bundle id and the same on
    /// every pymobiledevice3 version the project supports. That goes through
    /// the lockdown installation-proxy service, so it works whenever the
    /// iPhone is plugged in and trusted, with no developer tunnel.
    ///
    /// Throws when the list can't be read, or an installed SpoofRemote reports
    /// no version: the caller stays quiet and logs it. Not installed is nil,
    /// not an error.
    public func installedSpoofRemoteVersion(udid: String) throws -> SpoofRemoteVersion? {
        let json = try run(["apps", "list", "--udid", udid], timeout: 30)
        guard let data = json.data(using: .utf8),
              let apps = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            throw SpoofError("couldn't read the installed-apps list from the iPhone")
        }
        guard let app = apps[SpoofRemote.bundleID] as? [String: Any] else {
            return nil  // AnyWhere isn't installed: nothing to say.
        }
        let short = Self.appInfoString(app["CFBundleShortVersionString"])
        let build = Self.appInfoString(app["CFBundleVersion"])
        guard !short.isEmpty || !build.isEmpty else {
            throw SpoofError("SpoofRemote is installed but reports no version")
        }
        return SpoofRemoteVersion(marketing: short, build: build)
    }

    /// A value from the apps plist as a string (usually a String, sometimes a
    /// number).
    private static func appInfoString(_ value: Any?) -> String {
        if let string = value as? String { return string }
        if let number = value as? NSNumber { return number.stringValue }
        return ""
    }
}
