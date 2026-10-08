import Foundation

/// Slowly wandering GPS error (a first-order Gauss–Markov process): each update
/// moves the error a little toward a new random value, so it drifts over tens of
/// seconds like a real receiver's instead of jumping every fix.
public struct GPSDrift: Sendable {
    /// Typical distance from the true position, metres (RMS).
    public var size: Double
    /// Seconds for the error to forget where it was.
    public var timeConstant: TimeInterval
    private var east = 0.0
    private var north = 0.0
    private var rng: SplitMix64

    public init(size: Double, timeConstant: TimeInterval = 30, seed: UInt64 = .random(in: 0 ... .max)) {
        self.size = size
        self.timeConstant = timeConstant
        rng = SplitMix64(seed: seed)
    }

    public mutating func step(dt: TimeInterval) -> (east: Double, north: Double) {
        guard size > 0, dt > 0, timeConstant > 0 else {
            east = 0
            north = 0
            return (0, 0)
        }
        let keep = exp(-dt / timeConstant)
        let fresh = size / 2.0.squareRoot() * (1 - keep * keep).squareRoot()
        east = keep * east + fresh * rng.gaussian()
        north = keep * north + fresh * rng.gaussian()
        return (east, north)
    }

    public mutating func apply(to point: GeoPoint, dt: TimeInterval) -> GeoPoint {
        let offset = step(dt: dt)
        let distance = hypot(offset.east, offset.north)
        guard distance > 0 else { return point }
        return point.moved(by: distance, bearing: atan2(offset.east, offset.north) * 180 / .pi)
    }
}
