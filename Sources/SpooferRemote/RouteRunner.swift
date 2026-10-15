import Foundation
import RemoteAPI
import SpooferCore

public enum RouteRunnerError: LocalizedError {
    case invalid
    case degenerate

    public var errorDescription: String? {
        switch self {
        case .invalid: return "That route isn't valid — it needs two or more points and a known mode."
        case .degenerate: return "The route's points are all in the same place."
        }
    }
}

/// Turns a `RouteRequest` from the iPhone into a time-stamped track and plays
/// it: `position(at:)` gives the coordinate the device should be at after N
/// seconds, which the remote controller sends on. It reuses SpooferCore's trip
/// engine the same way the CLI's `--realistic` does.
///
/// For now the legs between waypoints are straight lines; `realistic` adds
/// gradual speeding up and braking, slowing for corners, and waits at the stops
/// you set. Road-snapping and OpenStreetMap lights/signs/limits are a later
/// enhancement (they need map data the phone doesn't send yet). There's no UI
/// and no device here — just geometry and timing — so it's testable on its own.
public struct RouteRunner: Sendable, Equatable {
    /// The played track, sorted by time offset.
    public let track: [RoutePoint]
    /// loop or ping-pong: after the track's end, time wraps and it repeats.
    public let wraps: Bool
    public let name: String?
    /// When the track leaves the start: after the one-off wait there before leaving (0 without one). A
    /// looping route's later laps begin here, so that wait isn't repeated, and progress counts from here.
    public let leaves: TimeInterval

    /// Seconds for one pass (one-way) or one unrolled cycle (loops), the first wait at the start included.
    public var duration: TimeInterval { track.last?.offset ?? 0 }
    public var start: GeoPoint { track.first?.point ?? GeoPoint(0, 0) }

    public init(track: [RoutePoint], wraps: Bool, name: String?, leaves: TimeInterval = 0) {
        self.track = track
        self.wraps = wraps
        self.leaves = leaves
        self.name = name
    }

    public static func build(from request: RouteRequest, now: Date = Date()) throws -> RouteRunner {
        guard request.isValid else { throw RouteRunnerError.invalid }
        let points = request.waypoints.map { GeoPoint($0.latitude, $0.longitude) }
        let loop = LoopMode(rawValue: request.loopMode) ?? .once
        let path = RoutePath(points)
        guard path.length > 0 else { throw RouteRunnerError.degenerate }

        let track: [RoutePoint]
        // Waits need the trip engine, so a route with any runs on it even with realistic trips off
        // (then without lights, turns or breaks: just the waits).
        let hasWaits = request.waypoints.contains { ($0.wait ?? 0) > 0 }
        if request.realistic || hasWaits {
            let top = max(0.1, request.speed)
            let profile = MotionProfile.forSpeed(top)
            // Time-of-day traffic slows driving only.
            let traffic = (request.timeOfDayTraffic && profile.kind == .drive) ? Congestion.factor(at: now) : 1
            let settings = request.realistic
                ? TripSettings(topSpeed: top, profile: profile, trafficFactor: traffic,
                               // No OSM data here: let sharp turns stand in for junctions
                               // when the user asked to follow roads.
                               guessJunctions: request.followRoads)
                : TripSettings(topSpeed: top, profile: profile, trafficLights: false, stopSigns: false,
                               slowForTurns: false, speedLimits: false, breaks: false)
            let played = RoutePlayback(path: path, loopMode: loop).path
            let stops = waypointStops(points: points, path: path, waits: request.waypoints.map(\.wait))
            let planner = TripPlanner(path: played, loopMode: loop, settings: settings,
                                      features: .none, waypointStops: stops)
            let trip = TripController(planner: planner)
            track = try RouteBuilder.timedTrack(path: trip.planner.path, loopMode: loop, trip: trip)
        } else {
            track = try RouteBuilder.timedTrack(path: path, speed: max(0.01, request.speed), loopMode: loop)
        }
        // Waiting at the start before leaving: the track stands at its first point until then.
        var leaves: TimeInterval = 0
        if (request.waypoints.first?.wait ?? 0) > 0, let first = track.first,
           let moving = track.firstIndex(where: { $0.point.distance(to: first.point) > 0.05 }), moving > 0 {
            leaves = track[moving - 1].offset
        }
        return RouteRunner(track: track, wraps: loop != .once, name: request.name, leaves: leaves)
    }

    /// Your stops with a wait, by distance along the route.
    static func waypointStops(points: [GeoPoint], path: RoutePath, waits: [Double?]) -> [WaypointStop] {
        guard waits.contains(where: { ($0 ?? 0) > 0 }) else { return [] }
        let distances = RouteMatcher(path: path).distances(ofWaypoints: points)
        return points.indices.compactMap { i in
            guard let wait = waits[i], wait > 0, i < distances.count else { return nil }
            return WaypointStop(index: i, distance: distances[i], wait: wait)
        }
    }

    /// How far along one pass or lap the route is `elapsed` seconds in, 0...1. A looping route starts over.
    public func progress(at elapsed: TimeInterval) -> Double {
        let lap = duration - leaves
        guard lap > 0, elapsed.isFinite, elapsed > leaves else { return 0 }   // still waiting to leave
        let moving = elapsed - leaves
        if wraps { return moving.truncatingRemainder(dividingBy: lap) / lap }
        return min(1, moving / lap)
    }

    /// The point to be at `elapsed` seconds in, and whether a one-way route has
    /// reached its destination (after which it holds there). A looping route
    /// wraps and never reports finished.
    public func position(at elapsed: TimeInterval) -> (point: GeoPoint, finished: Bool) {
        guard !track.isEmpty else { return (GeoPoint(0, 0), true) }
        let total = duration
        var t = max(0, elapsed)
        if wraps, total > 0 {
            // Later laps start where the first one left the start, so the wait before leaving happens once.
            let lap = total - leaves
            if t > total { t = lap > 0 ? leaves + (t - leaves).truncatingRemainder(dividingBy: lap) : t.truncatingRemainder(dividingBy: total) }
        } else if t >= total {
            return (track[track.count - 1].point, true)
        }
        // The last track point at or before t (the track is sorted by offset).
        var lo = 0, hi = track.count - 1, found = 0
        while lo <= hi {
            let mid = (lo + hi) / 2
            if track[mid].offset <= t { found = mid; lo = mid + 1 } else { hi = mid - 1 }
        }
        return (track[found].point, false)
    }
}
