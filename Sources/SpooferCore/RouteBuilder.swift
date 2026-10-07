import Foundation

/// One sampled position along a route: a coordinate and how many seconds into
/// the trip the device should be there.
public struct RoutePoint: Sendable, Equatable {
    public let latitude: Double
    public let longitude: Double
    public let offset: TimeInterval

    public init(latitude: Double, longitude: Double, offset: TimeInterval) {
        self.latitude = latitude
        self.longitude = longitude
        self.offset = offset
    }

    public var point: GeoPoint { GeoPoint(latitude, longitude) }
}

/// Builds the time-stamped GPX tracks that `pymobiledevice3 … simulate-location
/// play` replays (the classic engine and the CLI), plus shareable GPX exports.
public enum RouteBuilder {

    public static func distance(_ a: GeoPoint, _ b: GeoPoint) -> Double { Geo.distance(a, b) }

    public static func totalDistance(_ waypoints: [GeoPoint]) -> Double { Geo.length(of: waypoints) }

    /// Resample the polyline through `waypoints` into points spaced ~`sampleInterval`
    /// seconds apart, moving at constant speed so the whole route takes `duration`.
    public static func interpolate(
        waypoints: [GeoPoint],
        duration: TimeInterval,
        sampleInterval: TimeInterval = 0.5
    ) throws -> [RoutePoint] {
        guard waypoints.count >= 2 else {
            throw SpoofError("a route needs at least 2 points")
        }
        guard duration > 0, duration.isFinite else {
            throw SpoofError("route duration must be greater than 0")
        }
        let path = RoutePath(waypoints)
        let steps = max(2, min(3000, Int((duration / max(0.05, sampleInterval)).rounded(.up))))

        // Degenerate: all waypoints coincide — just sit there for the duration.
        guard path.length > 0 else {
            return [
                RoutePoint(latitude: waypoints[0].latitude, longitude: waypoints[0].longitude, offset: 0),
                RoutePoint(latitude: waypoints[0].latitude, longitude: waypoints[0].longitude, offset: duration),
            ]
        }
        return (0...steps).map { k in
            let fraction = Double(k) / Double(steps)
            let p = path.sample(at: fraction * path.length).point
            return RoutePoint(latitude: p.latitude, longitude: p.longitude, offset: fraction * duration)
        }
    }

    /// A timed track at constant `speed` (m/s). Because `simulate-location play`
    /// never exits on its own (it waits for a signal after the last point),
    /// loops and ping-pongs are unrolled into one long file covering at least
    /// `maxDuration` seconds (or one full lap, if a lap is longer than that).
    public static func timedTrack(
        path: RoutePath,
        speed: Double,
        loopMode: LoopMode,
        sampleInterval: TimeInterval = 1,
        maxDuration: TimeInterval = 8 * 3600,
        maxPoints: Int = 40_000
    ) throws -> [RoutePoint] {
        guard path.points.count >= 2 else {
            throw SpoofError("a route needs at least 2 points")
        }
        guard speed > 0, speed.isFinite else {
            throw SpoofError("route speed must be greater than 0")
        }
        var playback = RoutePlayback(path: path, loopMode: loopMode)
        let lapTime = playback.cycleLength / speed
        guard lapTime > 0 else {
            let p = path.start ?? GeoPoint(0, 0)
            return [
                RoutePoint(latitude: p.latitude, longitude: p.longitude, offset: 0),
                RoutePoint(latitude: p.latitude, longitude: p.longitude, offset: 1),
            ]
        }
        let total = loopMode == .once ? lapTime : max(lapTime, maxDuration)
        let interval = max(sampleInterval, total / Double(max(2, maxPoints)))
        let steps = max(1, Int((total / interval).rounded(.up)))

        var points: [RoutePoint] = []
        points.reserveCapacity(steps + 1)
        for k in 0...steps {
            let t = min(Double(k) * interval, total)
            playback.seek(toDistance: t * speed)
            let p = playback.current.point
            points.append(RoutePoint(latitude: p.latitude, longitude: p.longitude, offset: t))
        }
        return points
    }

    /// GPX 1.1 track. `pymobiledevice3` paces between points using the gaps
    /// between their `<time>` stamps, so the absolute base time is irrelevant.
    public static func gpx(_ points: [RoutePoint],
                           name: String = "iosgpsspoof route",
                           base: Date = Date(timeIntervalSince1970: 1_700_000_000)) -> String {
        let iso = ISO8601DateFormatter()
        // Fractional seconds so sub-second point spacing paces smoothly in
        // pymobiledevice3 (gpxpy parses `…T…:20.500Z` fine).
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]

        var body = ""
        body.reserveCapacity(points.count * 96)
        for p in points {
            let time = iso.string(from: base.addingTimeInterval(p.offset))
            body += "   <trkpt lat=\"\(p.latitude)\" lon=\"\(p.longitude)\"><time>\(time)</time></trkpt>\n"
        }
        return """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="iosgpsspoof" xmlns="http://www.topografix.com/GPX/1/1">
         <trk><name>\(xmlEscape(name))</name><trkseg>
        \(body) </trkseg></trk>
        </gpx>
        """
    }

    /// A shareable GPX file: the editable waypoints as a `<rte>`, plus the
    /// (possibly road-following) geometry as a `<trk>` when it differs.
    public static func exportGPX(name: String, waypoints: [GeoPoint], track: [GeoPoint]? = nil) -> String {
        var xml = """
        <?xml version="1.0" encoding="UTF-8"?>
        <gpx version="1.1" creator="iosgpsspoof" xmlns="http://www.topografix.com/GPX/1/1">
         <metadata><name>\(xmlEscape(name))</name></metadata>
         <rte><name>\(xmlEscape(name))</name>

        """
        for (i, p) in waypoints.enumerated() {
            xml += "  <rtept lat=\"\(p.latitude)\" lon=\"\(p.longitude)\"><name>\(i + 1)</name></rtept>\n"
        }
        xml += " </rte>\n"
        if let track, track.count >= 2, track != waypoints {
            xml += " <trk><name>\(xmlEscape(name))</name><trkseg>\n"
            for p in track {
                xml += "  <trkpt lat=\"\(p.latitude)\" lon=\"\(p.longitude)\"/>\n"
            }
            xml += " </trkseg></trk>\n"
        }
        xml += "</gpx>\n"
        return xml
    }

    /// Write a timed track to a temp file, returning its URL. Caller deletes it.
    public static func writeGPX(_ points: [RoutePoint], name: String = "iosgpsspoof route") throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("iosgpsspoof-route-\(UUID().uuidString).gpx")
        try gpx(points, name: name).write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Write a constant-speed track through `waypoints` lasting `duration`.
    public static func writeGPX(waypoints: [GeoPoint], duration: TimeInterval) throws -> URL {
        try writeGPX(interpolate(waypoints: waypoints, duration: duration))
    }

    static func xmlEscape(_ text: String) -> String {
        var out = ""
        out.reserveCapacity(text.count)
        for c in text {
            switch c {
            case "&": out += "&amp;"
            case "<": out += "&lt;"
            case ">": out += "&gt;"
            case "\"": out += "&quot;"
            case "'": out += "&apos;"
            default: out.append(c)
            }
        }
        return out
    }
}
