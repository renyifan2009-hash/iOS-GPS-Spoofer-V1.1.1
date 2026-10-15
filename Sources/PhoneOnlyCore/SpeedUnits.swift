import Foundation

/// Miles or kilometres per hour, by region, and the speed sliders in whichever one is shown. Routes and
/// saved routes keep their speed in km/h; only what a person sees and drags changes.
public struct SpeedUnits: Equatable, Sendable {
    /// The three ways iOS and macOS group regions for measurements.
    public enum Region: Sendable { case us, uk, metric }

    /// Miles per hour (the US and the UK, where road speeds are in mph).
    public let imperial: Bool

    public init(imperial: Bool) { self.imperial = imperial }

    public init(region: Region) { imperial = region != .metric }

    /// The units this device's region uses.
    public static var current: SpeedUnits {
        switch Locale.current.measurementSystem {
        case .us: return SpeedUnits(region: .us)
        case .uk: return SpeedUnits(region: .uk)
        default: return SpeedUnits(region: .metric)
        }
    }

    static let kmPerMile = 1.609344

    public var label: String { imperial ? "mph" : "km/h" }

    /// A speed in km/h, in the shown unit.
    public func display(kmh: Double) -> Double { imperial ? kmh / Self.kmPerMile : kmh }

    /// A speed in the shown unit, in km/h.
    public func kmh(fromDisplay value: Double) -> Double { imperial ? value * Self.kmPerMile : value }

    /// The route speed slider, in the shown unit.
    public func routeRange(driving: Bool) -> ClosedRange<Double> {
        imperial ? (driving ? 5...75 : 1...6) : (driving ? 10...120 : 1...10)
    }

    public func routeStep(driving: Bool) -> Double {
        imperial ? (driving ? 5 : 0.5) : (driving ? 5 : 1)
    }

    /// A town drive or a walk, landing on the slider's steps: 30 mph / 3 mph, or 50 km/h / 5 km/h.
    public func defaultKmh(driving: Bool) -> Double {
        imperial ? kmh(fromDisplay: driving ? 30 : 3) : (driving ? 50 : 5)
    }

    /// The joystick's custom top speed, in the shown unit.
    public var joystickRange: ClosedRange<Double> { imperial ? 1...75 : 1...120 }

    /// "30 mph", "2.5 mph", "50 km/h". Halves show only below 10, where the walking slider uses them.
    public func text(kmh: Double) -> String {
        guard kmh.isFinite, kmh > 0 else { return "0 \(label)" }
        let value = min(display(kmh: kmh), 9_999)
        let half = (value * 2).rounded() / 2
        if value < 10, half != half.rounded() {
            return String(format: "%.1f %@", half, label)
        }
        return "\(Int(value.rounded())) \(label)"
    }

    public func text(metersPerSecond: Double) -> String { text(kmh: metersPerSecond * 3.6) }
}
