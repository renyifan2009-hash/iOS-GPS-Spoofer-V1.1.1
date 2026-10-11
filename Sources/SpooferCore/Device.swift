import Foundation

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

    /// Write the iPhone's lockdown pairing record to `url`, for an app on the
    /// iPhone itself to reach its own developer services (see
    /// docs/PHONE-ONLY.md). It also turns on Wi-Fi connections, so lockdown
    /// listens on the network, which is how such an app reaches it.
    ///
    /// The file lets whoever holds it act as this Mac towards the iPhone:
    /// give it only to that iPhone.
    ///
    /// The file holds two identities. The lockdown record works up to iOS
    /// 26.6. iOS 26.7 and later stop answering lockdown over the network, so
    /// the iPhone app can't reach it through LocalDevVPN any more; for those,
    /// the file also gets a RemotePairing identity (`public_key`,
    /// `private_key`, `identifier`), made over USB, which the app uses to open
    /// the tunnel through remotepairingd instead. Returns false when that part
    /// couldn't be made (an old pymobiledevice3, say); the file then works on
    /// iOS 26.6 and earlier only.
    @discardableResult
    public func exportPairingFile(udid: String, to url: URL) throws -> Bool {
        _ = try? run(["lockdown", "wifi-connections", "on", "--udid", udid], timeout: 30)
        try? FileManager.default.removeItem(at: url)
        _ = try run(["lockdown", "save-pair-record", url.path, "--udid", udid], timeout: 30)
        // save-pair-record only logs "no pairing record was found" and exits 0.
        guard let data = try? Data(contentsOf: url), !data.isEmpty,
              var record = (try? PropertyListSerialization.propertyList(from: data, format: nil)) as? [String: Any] else {
            throw SpoofError("this Mac has no pairing record for the iPhone. Unplug it, plug it back in, tap Trust, then try again.")
        }

        guard let keys = try? remotePairingKeys(udid: udid) else { return false }
        record.merge(keys) { _, new in new }
        let merged = try PropertyListSerialization.data(fromPropertyList: record, format: .xml, options: 0)
        try merged.write(to: url, options: .atomic)
        return true
    }

    /// Pairs this Mac with the iPhone's remotepairingd over USB lockdown (no
    /// Trust prompt, since USB is already trusted) and returns the identity in
    /// the keys idevice's RPPairing file reads. Re-uses the record if this Mac
    /// already paired.
    func remotePairingKeys(udid: String) throws -> [String: Any] {
        guard let python = pythonInterpreter else { throw SpoofError("can't find pymobiledevice3's Python") }
        let result = try ProcessRunner.run(python, arguments: ["-c", Self.remotePairingScript, udid],
                                           timeout: 60, environment: Self.childEnvironment)
        guard result.status == 0,
              let bytes = Data(base64Encoded: result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)),
              let keys = (try? PropertyListSerialization.propertyList(from: bytes, format: nil)) as? [String: Any] else {
            throw SpoofError("RemotePairing over USB failed (\(result.status))\n\(result.errorSummary)")
        }
        return keys
    }

    private static let remotePairingScript = #"""
import asyncio, base64, plistlib, sys
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from pymobiledevice3.exceptions import RemotePairingCompletedError
from pymobiledevice3.lockdown import create_using_usbmux
from pymobiledevice3.remote.tunnel_service import RemotePairingLockdownService

async def main(udid):
    lockdown = create_using_usbmux(serial=udid)
    if asyncio.iscoroutine(lockdown):
        lockdown = await lockdown
    service = await RemotePairingLockdownService.create(lockdown)
    try:
        try:
            await service.connect(autopair=True)
        except RemotePairingCompletedError:
            pass  # the iPhone closes the channel once pair-setup is done; the record is saved
        record = service.pair_record
        if not record:
            sys.exit("no RemotePairing record was saved")
        private_key = record["private_key"]
        public_key = record.get("public_key") or Ed25519PrivateKey.from_private_bytes(private_key).public_key().public_bytes_raw()
        out = {
            "public_key": public_key,
            "private_key": private_key,
            "identifier": record.get("host_identifier") or service.identifier,
        }
        if record.get("peer_alt_irk"):
            out["alt_irk"] = record["peer_alt_irk"]
        print(base64.b64encode(plistlib.dumps(out)).decode())
    finally:
        await service.close()

asyncio.run(main(sys.argv[1]))
"""#

    /// Is a device with this UDID currently reachable?
    public func isPresent(udid: String, connection: ConnectionFilter = .any) -> Bool {
        guard let devices = try? listDevices() else { return false }
        return devices.contains { $0.udid == udid && connection.matches($0) }
    }
}
