import Foundation
import RemoteAPI
import SpooferCore

/// What the iPhone's joystick asked for, as the Mac holds it: a heading and a speed that last until the next
/// request. If no request arrives for `RemoteAPI.joystickTimeout` seconds the motion stops by itself, so a
/// dropped connection, a locked iPhone or a crashed app can never leave the location running away.
public struct JoystickMotion: Equatable, Sendable {
    /// Degrees clockwise from true north.
    public var heading: Double
    /// Metres per second.
    public var speed: Double
    /// When the request that set this arrived.
    public var receivedAt: Date

    public init(heading: Double, speed: Double, receivedAt: Date) {
        self.heading = heading
        self.speed = speed
        self.receivedAt = receivedAt
    }

    public init(_ request: JoystickRequest, receivedAt: Date) {
        let safe = request.normalized
        self.init(heading: safe.heading, speed: safe.speed, receivedAt: receivedAt)
    }

    /// No request has arrived for too long.
    public func isExpired(at now: Date, timeout: TimeInterval = RemoteAPI.joystickTimeout) -> Bool {
        now.timeIntervalSince(receivedAt) > timeout
    }

    /// The speed that counts right now: 0 once the request is old.
    public func effectiveSpeed(at now: Date, timeout: TimeInterval = RemoteAPI.joystickTimeout) -> Double {
        isExpired(at: now, timeout: timeout) ? 0 : speed
    }

    /// Where the location is after `dt` seconds at the speed that counts, starting from `point`.
    public func step(from point: GeoPoint, dt: TimeInterval, now: Date) -> GeoPoint {
        let moving = effectiveSpeed(at: now)
        guard moving > 0, dt.isFinite, dt > 0 else { return point }
        return point.moved(by: moving * dt, bearing: heading)
    }
}
