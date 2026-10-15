import Foundation

/// A local route timeline: travel at the selected speed, wait at stops and repeat without a Mac.
/// Road directions are supplied by the iPhone app; this type never substitutes straight lines for
/// a failed directions request.
public struct StandaloneRoute: Sendable {
    public struct Point: Equatable, Sendable {
        public var latitude: Double
        public var longitude: Double
        public init(_ latitude: Double, _ longitude: Double) { self.latitude = latitude; self.longitude = longitude }
        public var isValid: Bool {
            latitude.isFinite && longitude.isFinite && (-85...85).contains(latitude) && (-180...180).contains(longitude)
        }
    }
    private struct Segment: Sendable {
        var from: Point
        var to: Point
        var start: Double
        var end: Double
        /// Which waypoint a wait is at (0 is the start); nil while travelling.
        var stop: Int? = nil
    }
    private let segments: [Segment]
    public let duration: Double
    public let repeats: Bool
    public let speed: Double
    public let start: Point

    public enum Problem: Error, LocalizedError {
        case invalid
        public var errorDescription: String? { "This route needs distinct map positions, a valid speed and reasonable waits." }
    }

    /// Paths include their endpoints. Waits are in seconds, one per waypoint.
    public init(legs: [[Point]], waits: [Double], speed: Double, repeatMode: String) throws {
        guard !legs.isEmpty, legs.count <= SavedRoute.maxStops, waits.count == legs.count + 1,
              waits.allSatisfy({ $0.isFinite && (0...86400).contains($0) }),
              speed.isFinite, speed > 0, speed <= JoystickInput.maxSpeed,
              ["once", "loop", "pingPong"].contains(repeatMode),
              legs.allSatisfy({ $0.count >= 2 && $0.allSatisfy(\.isValid) }),
              legs.reduce(0, { $0 + $1.count }) <= 100_000 else { throw Problem.invalid }
        for i in 1..<legs.count where legs[i - 1].last != legs[i].first { throw Problem.invalid }
        var segments: [Segment] = []
        var elapsed = 0.0
        func add(_ from: Point, _ to: Point, _ seconds: Double, stop: Int? = nil) {
            guard seconds > 0 else { return }
            segments.append(Segment(from: from, to: to, start: elapsed, end: elapsed + seconds, stop: stop))
            elapsed += seconds
        }
        func travel(_ points: [Point]) {
            for i in 1..<points.count {
                add(points[i - 1], points[i], Self.distance(points[i - 1], points[i]) / speed)
            }
        }
        let first = legs[0][0]
        add(first, first, waits[0], stop: 0)
        for (i, leg) in legs.enumerated() {
            travel(leg)
            let end = leg[leg.count - 1]
            add(end, end, waits[i + 1], stop: i + 1)
        }
        if repeatMode == "pingPong" {
            for i in legs.indices.reversed() {
                let reverse = Array(legs[i].reversed())
                travel(reverse)
                if i > 0 { add(reverse.last!, reverse.last!, waits[i], stop: i) }
            }
        }
        // Loop callers supply a road leg back to the starting point. Refuse a discontinuous jump.
        if repeatMode == "loop", legs.last?.last != first { throw Problem.invalid }
        guard legs.contains(where: { leg in zip(leg, leg.dropFirst()).contains { Self.distance($0, $1) > 0.01 } }),
              elapsed.isFinite, elapsed > 0 else { throw Problem.invalid }
        self.segments = segments; self.duration = elapsed; self.repeats = repeatMode != "once"
        self.speed = speed; self.start = first
    }

    public func sample(at elapsed: Double) -> (point: Point, progress: Double, finished: Bool, moving: Bool) {
        var t = elapsed.isFinite ? max(0, elapsed) : 0
        if repeats { t.formTruncatingRemainder(dividingBy: duration) }
        if t >= duration { return (segments.last!.to, 1, true, false) }
        var low = 0, high = segments.count - 1
        while low < high {
            let mid = (low + high) / 2
            if segments[mid].end <= t { low = mid + 1 } else { high = mid }
        }
        let segment = segments[low]
        let fraction = min(1, max(0, (t - segment.start) / (segment.end - segment.start)))
        let meters = Self.distance(segment.from, segment.to)
        if meters < 0.01 { return (segment.from, t / duration, false, false) }
        let p = PhoneGeo.moved(latitude: segment.from.latitude, longitude: segment.from.longitude,
                               meters: meters * fraction, bearing: Self.bearing(segment.from, segment.to))
        return (Point(p.latitude, p.longitude), t / duration, false, true)
    }

    /// While the route stands at one of its waypoints `elapsed` seconds in: which one (0 is the start, so a wait
    /// there is "leaving in") and how long is left. nil while travelling or after a one-way route ends.
    public func waiting(at elapsed: Double) -> (stop: Int, remaining: Double)? {
        var t = elapsed.isFinite ? max(0, elapsed) : 0
        if repeats { t.formTruncatingRemainder(dividingBy: duration) }
        guard t < duration else { return nil }
        guard let segment = segments.first(where: { t >= $0.start && t < $0.end }), let stop = segment.stop else { return nil }
        return (stop, segment.end - t)
    }

    public static func distance(_ a: Point, _ b: Point) -> Double {
        let p1 = a.latitude * .pi / 180, p2 = b.latitude * .pi / 180
        let dp = p2 - p1, dl = (b.longitude - a.longitude) * .pi / 180
        let h = pow(sin(dp / 2), 2) + cos(p1) * cos(p2) * pow(sin(dl / 2), 2)
        return 6_371_000 * 2 * asin(sqrt(min(1, max(0, h))))
    }

    private static func bearing(_ a: Point, _ b: Point) -> Double {
        let p1 = a.latitude * .pi / 180, p2 = b.latitude * .pi / 180
        let dl = (b.longitude - a.longitude) * .pi / 180
        return atan2(sin(dl) * cos(p2), cos(p1) * sin(p2) - sin(p1) * cos(p2) * cos(dl)) * 180 / .pi
    }
}
