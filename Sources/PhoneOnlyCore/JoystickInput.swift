import Foundation

/// How a thumb on the iPhone's joystick becomes a heading and a speed for the Mac.
public struct JoystickInput: Equatable, Sendable {
    /// Degrees clockwise from true north, 0 up to (not including) 360.
    public var heading: Double
    /// Metres per second; 0 when the thumb is at rest.
    public var speed: Double

    public init(heading: Double, speed: Double) {
        self.heading = heading
        self.speed = speed
    }

    public static let idle = JoystickInput(heading: 0, speed: 0)
    public var isIdle: Bool { speed <= 0 }

    /// A thumb this close to the centre counts as at rest, so a resting thumb doesn't drift.
    public static let deadZone = 0.12
    /// The speeds the Mac accepts.
    public static let maxSpeed = 70.0
    public static let minTopSpeed = 0.3

    /// - Parameters:
    ///   - x: sideways, -1 (left) ... 1 (right)
    ///   - y: up and down, -1 (down) ... 1 (up)
    ///   - topSpeed: the speed at full deflection, metres per second
    ///   - mapHeading: how far the map is turned, degrees clockwise (0 with north up)
    ///   - relativeToMap: up means "up on the screen" (turn with the map) instead of "north"
    public static func make(x: Double, y: Double, topSpeed: Double, mapHeading: Double = 0,
                            relativeToMap: Bool = false) -> JoystickInput {
        guard x.isFinite, y.isFinite, topSpeed.isFinite else { return .idle }
        let magnitude = min(1, hypot(x, y))
        guard magnitude > deadZone else { return .idle }
        // Past the dead zone the speed rises smoothly from 0 to the top speed, gently at first.
        let past = (magnitude - deadZone) / (1 - deadZone)
        let eased = past * past * (3 - 2 * past) * 0.5 + past * 0.5
        let top = min(max(topSpeed, minTopSpeed), maxSpeed)
        var heading = atan2(x, y) * 180 / .pi
        if relativeToMap, mapHeading.isFinite { heading += mapHeading }
        return JoystickInput(heading: wrap(heading), speed: min(top * eased, maxSpeed))
    }

    /// "N", "NE", "E" ... for a heading.
    public static func compassPoint(_ heading: Double) -> String {
        let points = ["N", "NE", "E", "SE", "S", "SW", "W", "NW"]
        let index = Int(((wrap(heading) + 22.5) / 45).rounded(.down)) % 8
        return points[index]
    }

    /// 0 up to (not including) 360.
    public static func wrap(_ degrees: Double) -> Double {
        guard degrees.isFinite else { return 0 }
        var h = degrees.truncatingRemainder(dividingBy: 360)
        if h < 0 { h += 360 }
        return h
    }
}

/// The speeds on the joystick's buttons.
public enum JoystickPreset: String, CaseIterable, Identifiable, Sendable {
    case walk, jog, cycle, drive

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .walk: return "Walk"
        case .jog: return "Jog"
        case .cycle: return "Cycle"
        case .drive: return "Drive"
        }
    }

    public var symbol: String {
        switch self {
        case .walk: return "figure.walk"
        case .jog: return "figure.run"
        case .cycle: return "bicycle"
        case .drive: return "car.fill"
        }
    }

    /// Metres per second at full deflection.
    public var metersPerSecond: Double {
        switch self {
        case .walk: return 1.4
        case .jog: return 3.0
        case .cycle: return 6.0
        case .drive: return 14.0
        }
    }

    public static func kmh(fromMetersPerSecond speed: Double) -> Double { speed * 3.6 }
    public static func metersPerSecond(fromKmh kmh: Double) -> Double { kmh / 3.6 }
}

/// A speed as words, in km/h or mph.
public enum SpeedText {
    public static func format(metersPerSecond: Double, imperial: Bool) -> String {
        guard metersPerSecond.isFinite, metersPerSecond > 0 else { return imperial ? "0 mph" : "0 km/h" }
        let value = min(metersPerSecond * (imperial ? 2.2369362921 : 3.6), 9_999)
        return "\(Int(value.rounded())) \(imperial ? "mph" : "km/h")"
    }
}

/// A little geometry for the iPhone's map.
public enum PhoneGeo {
    /// The point `meters` from here toward `bearing` (degrees clockwise from north) along the great circle.
    /// The latitude is held to ±85° (the map has no place for more, and some map calls refuse it).
    public static func moved(latitude: Double, longitude: Double, meters: Double, bearing: Double)
        -> (latitude: Double, longitude: Double) {
        guard latitude.isFinite, longitude.isFinite else { return (0, 0) }
        guard meters.isFinite, meters != 0, bearing.isFinite else { return (clampLatitude(latitude), longitude) }
        let r = 6_371_000.0
        let d = meters / r
        let b = bearing * .pi / 180
        let p1 = latitude * .pi / 180, l1 = longitude * .pi / 180
        let p2 = asin(sin(p1) * cos(d) + cos(p1) * sin(d) * cos(b))
        let l2 = l1 + atan2(sin(b) * sin(d) * cos(p1), cos(d) - sin(p1) * sin(p2))
        var lon = l2 * 180 / .pi
        lon = lon.truncatingRemainder(dividingBy: 360)
        if lon > 180 { lon -= 360 } else if lon < -180 { lon += 360 }
        return (clampLatitude(p2 * 180 / .pi), lon)
    }

    static func clampLatitude(_ latitude: Double) -> Double { min(max(latitude, -85), 85) }
}
