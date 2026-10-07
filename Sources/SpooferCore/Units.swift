import Foundation

public enum UnitSystem: String, Codable, CaseIterable, Sendable, Identifiable {
    case metric, imperial

    public var id: String { rawValue }
    public var label: String { self == .metric ? "Metric (km, km/h)" : "Imperial (mi, mph)" }
    public var speedUnit: String { self == .metric ? "km/h" : "mph" }

    /// m/s → km/h or mph.
    public func displaySpeed(fromMetresPerSecond mps: Double) -> Double {
        self == .metric ? mps * 3.6 : mps * 2.236_936_292
    }

    /// km/h or mph → m/s.
    public func metresPerSecond(fromDisplaySpeed value: Double) -> Double {
        self == .metric ? value / 3.6 : value / 2.236_936_292
    }
}

/// Human-friendly formatting for distances, speeds and durations.
public enum Format {
    public static func distance(_ metres: Double, units: UnitSystem = .metric) -> String {
        guard metres.isFinite else { return "—" }
        switch units {
        case .metric:
            if metres < 1000 { return "\(Int(metres.rounded())) m" }
            if metres < 10_000 { return String(format: "%.2f km", metres / 1000) }
            if metres < 100_000 { return String(format: "%.1f km", metres / 1000) }
            return grouped(metres / 1000) + " km"
        case .imperial:
            let feet = metres * 3.280_84
            if feet < 1000 { return "\(Int(feet.rounded())) ft" }
            let miles = metres / 1609.344
            if miles < 10 { return String(format: "%.2f mi", miles) }
            if miles < 100 { return String(format: "%.1f mi", miles) }
            return grouped(miles) + " mi"
        }
    }

    public static func speed(_ metresPerSecond: Double, units: UnitSystem = .metric) -> String {
        guard metresPerSecond.isFinite, abs(metresPerSecond) < 1e9 else { return "—" }
        let value = units.displaySpeed(fromMetresPerSecond: metresPerSecond)
        let text = value < 10 ? String(format: "%.1f", value) : String(Int(value.rounded()))
        return "\(text) \(units.speedUnit)"
    }

    /// `45s`, `4m 05s`, `1h 07m`, `2d 3h`.
    public static func duration(_ seconds: TimeInterval) -> String {
        guard seconds.isFinite, seconds >= 0, seconds < 1e12 else { return "—" }
        let total = Int(seconds.rounded())
        if total < 60 { return "\(total)s" }
        let d = total / 86_400, h = (total % 86_400) / 3600, m = (total % 3600) / 60, s = total % 60
        if d > 0 { return "\(d)d \(h)h" }
        if h > 0 { return "\(h)h " + (m < 10 ? "0\(m)m" : "\(m)m") }
        return "\(m)m " + (s < 10 ? "0\(s)s" : "\(s)s")
    }

    /// `48.85840, 2.29450`
    public static func coordinate(_ point: GeoPoint, precision: Int = 5) -> String {
        Coordinate.format(point, precision: precision)
    }

    private static func grouped(_ value: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.maximumFractionDigits = 0
        return f.string(from: NSNumber(value: value.rounded())) ?? String(Int(value.rounded()))
    }
}
