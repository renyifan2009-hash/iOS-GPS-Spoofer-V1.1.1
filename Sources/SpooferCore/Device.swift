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

    /// Is a device with this UDID currently reachable?
    public func isPresent(udid: String, connection: ConnectionFilter = .any) -> Bool {
        guard let devices = try? listDevices() else { return false }
        return devices.contains { $0.udid == udid && connection.matches($0) }
    }
}
