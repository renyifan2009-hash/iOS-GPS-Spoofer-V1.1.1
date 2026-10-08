import Foundation

/// How to reach the iOS 17+ developer services tunnel.
public enum Transport: String, CaseIterable, Sendable, Codable {
    /// Per device: `.userspace` on iOS 17.4 and later, `.native` on iOS
    /// 17.0–17.3 (which can't run the userspace tunnel). The default.
    case automatic
    /// macOS only, no root: piggybacks Apple's `remotepairingd` tunnel. The
    /// device keeps one connection for it, so macOS's own `remoted` and this
    /// tool knock each other off now and then (pymobiledevice3 #1994).
    case native
    /// Uses a running `pymobiledevice3 remote tunneld` (usually started with sudo).
    case tunneld
    /// pymobiledevice3's own tunnel, in-process, no root. Nothing else on the
    /// Mac competes for it. iOS 17.4 and later.
    case userspace

    /// The concrete transport for `device`.
    public func resolved(for device: Device) -> Transport {
        guard self == .automatic else { return self }
        return device.supportsUserspaceTunnel ? .userspace : .native
    }

    /// Flags to append to a `pymobiledevice3 developer …` invocation for `device`.
    public func flags(for device: Device) -> [String] {
        resolved(for: device).flags(udid: device.udid)
    }

    /// Flags for a concrete transport. `.automatic` means pymobiledevice3's
    /// own default, the userspace tunnel; prefer `flags(for:)`.
    public func flags(udid: String) -> [String] {
        switch self {
        case .automatic, .userspace: return ["--userspace"]
        case .native: return ["--native"]
        case .tunneld: return ["--tunnel", udid]
        }
    }

    public var label: String {
        switch self {
        case .automatic: return "Automatic (recommended)"
        case .native: return "Apple's tunnel (no root)"
        case .tunneld: return "tunneld daemon"
        case .userspace: return "Own tunnel (no root)"
        }
    }

    public var detail: String {
        switch self {
        case .automatic:
            return "Uses its own tunnel on iOS 17.4 and later, and Apple's tunnel on iOS 17.0–17.3. No password."
        case .native:
            return "Rides macOS's own device tunnel. Fast, but macOS takes the connection back now and then, which drops it for a moment."
        case .tunneld:
            return "Needs `sudo pymobiledevice3 remote tunneld` running in a terminal."
        case .userspace:
            return "pymobiledevice3's own tunnel, so nothing else on the Mac competes for it. iOS 17.4 and later; no password."
        }
    }
}

/// A few well-known spots for quick-pick menus.
public struct NamedLocation: Identifiable, Sendable, Hashable {
    public var id: String { name }
    public let name: String
    public let latitude: Double
    public let longitude: Double
    /// A small visual for chips and menus.
    public let emoji: String

    public init(_ name: String, _ latitude: Double, _ longitude: Double, emoji: String = "📍") {
        self.name = name; self.latitude = latitude; self.longitude = longitude; self.emoji = emoji
    }

    public var point: GeoPoint { GeoPoint(latitude, longitude) }

    /// The part before the first comma ("Eiffel Tower, Paris" → "Eiffel Tower").
    public var shortName: String {
        name.split(separator: ",").first.map(String.init) ?? name
    }

    public static let presets: [NamedLocation] = [
        .init("Apple Park, Cupertino", 37.334_9, -122.009_0, emoji: "🍎"),
        .init("Golden Gate Bridge, San Francisco", 37.819_9, -122.478_3, emoji: "🌉"),
        .init("Times Square, New York", 40.758_0, -73.985_5, emoji: "🗽"),
        .init("Big Ben, London", 51.500_7, -0.124_6, emoji: "🇬🇧"),
        .init("Eiffel Tower, Paris", 48.858_4, 2.294_5, emoji: "🗼"),
        .init("Brandenburg Gate, Berlin", 52.516_3, 13.377_7, emoji: "🇩🇪"),
        .init("Colosseum, Rome", 41.890_2, 12.492_2, emoji: "🏛️"),
        .init("Burj Khalifa, Dubai", 25.197_2, 55.274_4, emoji: "🏙️"),
        .init("Shibuya Crossing, Tokyo", 35.659_5, 139.700_5, emoji: "🗾"),
        .init("Marina Bay Sands, Singapore", 1.283_4, 103.860_7, emoji: "🇸🇬"),
        .init("Sydney Opera House", -33.856_8, 151.215_3, emoji: "🦘"),
        .init("Christ the Redeemer, Rio de Janeiro", -22.951_9, -43.210_5, emoji: "🇧🇷"),
    ]
}
