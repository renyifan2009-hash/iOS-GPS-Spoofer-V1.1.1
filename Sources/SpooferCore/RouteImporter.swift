import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

/// A route read from a GPX or KML file.
public struct ImportedRoute: Sendable, Equatable {
    public var name: String?
    public var points: [GeoPoint]
    /// Per-point timestamps (GPX tracks), aligned with `points`; often all nil.
    public var timestamps: [Date?]
    /// True when the file held hand-placed waypoints (`<rte>`, `<wpt>`, KML
    /// placemarks) rather than a dense recorded track.
    public var isWaypointList: Bool
    /// Positions in the file that were left out because they are not real
    /// places: not a number, or off the map (a latitude past 90, say).
    public var skippedPoints: Int
    /// Separate stretches of the file that were left out because they start far
    /// from where the one before ended (a file with several trips in it, or a
    /// KML outline next to a route). Only the longest group of stretches is kept.
    public var skippedSegments: Int

    public init(name: String?, points: [GeoPoint], timestamps: [Date?], isWaypointList: Bool,
                skippedPoints: Int = 0, skippedSegments: Int = 0) {
        self.name = name
        self.points = points
        self.timestamps = timestamps
        self.isWaypointList = isWaypointList
        self.skippedPoints = skippedPoints
        self.skippedSegments = skippedSegments
    }

    public var length: Double { Geo.length(of: points) }

    /// Elapsed time between the first and last timestamped points.
    public var duration: TimeInterval? {
        guard let first = timestamps.lazy.compactMap({ $0 }).first,
              let last = timestamps.reversed().lazy.compactMap({ $0 }).first else { return nil }
        let d = last.timeIntervalSince(first)
        return d > 0 ? d : nil
    }

    /// Average speed in m/s, when the track is timestamped.
    public var averageSpeed: Double? {
        guard let duration, length > 0 else { return nil }
        return length / duration
    }

    /// A short, plain sentence about what was left out of the file, for the
    /// import message. Nil when the whole file was used.
    public var warning: String? {
        var parts: [String] = []
        if skippedPoints > 0 {
            parts.append(skippedPoints == 1
                ? "Left out 1 position that is not a real place."
                : "Left out \(skippedPoints) positions that are not real places.")
        }
        if skippedSegments > 0 {
            parts.append(skippedSegments == 1
                ? "The file has another stretch far away from this one. Only the longest was used."
                : "The file has \(skippedSegments) other stretches far away from this one. Only the longest was used.")
        }
        return parts.isEmpty ? nil : parts.joined(separator: " ")
    }
}

public enum RouteImporter {
    public static let supportedExtensions = ["gpx", "kml"]

    public static func load(contentsOf url: URL) throws -> ImportedRoute {
        let data = try Data(contentsOf: url)
        var route = try parse(data)
        if route.name == nil || route.name?.isEmpty == true {
            route.name = url.deletingPathExtension().lastPathComponent
        }
        return route
    }

    /// Parse GPX (tracks, routes or waypoints) or KML (LineString, gx:Track or
    /// Point placemarks); the format is sniffed from the root element.
    ///
    /// Positions that are not real places (NaN, infinite, past ±90° / ±180°) are
    /// left out and counted in `skippedPoints`. A file that stops before its
    /// closing tag (a download cut short) is refused rather than half-imported.
    public static func parse(_ data: Data) throws -> ImportedRoute {
        let delegate = RouteXMLDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        let ok = parser.parse()
        // Junk after the closing tag is harmless. A file that ends inside the
        // document is cut off, and what was read before that is only part of it.
        if !ok, !delegate.finishedDocument {
            if delegate.startedDocument {
                throw SpoofError("the route file is cut off or damaged (near line \(parser.lineNumber)), so it can't be used")
            }
            let why = parser.parserError?.localizedDescription ?? "it is not XML"
            throw SpoofError("could not read the route file: \(why)")
        }
        guard let route = delegate.result() else {
            if delegate.skippedPoints > 0 {
                let n = delegate.skippedPoints
                throw SpoofError("the file has no usable positions. \(n) \(n == 1 ? "position is" : "positions are") "
                    + "not a real place (a latitude is between -90 and 90, a longitude between -180 and 180)")
            }
            throw SpoofError("no route points found in the file (expected GPX or KML)")
        }
        return route
    }
}

/// Reads the `<time>` stamps of a GPX file. Foundation's ISO8601DateFormatter
/// takes hundreds of microseconds a call, and a long recording has tens of
/// thousands of stamps, so the fixed layout is read by hand.
enum GPXTime {
    /// `2024-05-01T08:00:00Z`, with optional fractional seconds and a `Z` or
    /// `±hh:mm` / `±hhmm` / `±hh` zone. Nil for anything else.
    static func date(from text: String) -> Date? {
        let b = Array(text.utf8)
        var i = 0
        func number(_ count: Int) -> Int? {
            guard i + count <= b.count else { return nil }
            var value = 0
            for k in 0..<count {
                let c = b[i + k]
                guard c >= 48, c <= 57 else { return nil }
                value = value * 10 + Int(c - 48)
            }
            i += count
            return value
        }
        func skip(_ c: UInt8) -> Bool {
            guard i < b.count, b[i] == c else { return false }
            i += 1
            return true
        }
        guard let year = number(4), skip(45), let month = number(2), skip(45), let day = number(2),
              skip(84), let hour = number(2), skip(58), let minute = number(2), skip(58), let second = number(2),
              (1...12).contains(month), (1...daysIn(month: month, year: year)).contains(day),
              hour < 24, minute < 60, second < 60 else { return nil }

        var fraction = 0.0
        if i < b.count, b[i] == 46 {
            i += 1
            var scale = 0.1
            var any = false
            while i < b.count, b[i] >= 48, b[i] <= 57 {
                fraction += Double(b[i] - 48) * scale
                scale /= 10
                i += 1
                any = true
            }
            guard any else { return nil }
        }

        var offset = 0
        if skip(90) {
            offset = 0
        } else if i < b.count, b[i] == 43 || b[i] == 45 {
            let sign = b[i] == 45 ? -1 : 1
            i += 1
            guard let zoneHour = number(2), zoneHour < 24 else { return nil }
            var zoneMinute = 0
            if i < b.count {
                _ = skip(58)
                guard let m = number(2), m < 60 else { return nil }
                zoneMinute = m
            }
            offset = sign * (zoneHour * 3600 + zoneMinute * 60)
        } else {
            return nil
        }
        guard i == b.count else { return nil }

        let seconds = Double(daysFromCivil(year: year, month: month, day: day)) * 86_400
            + Double(hour * 3600 + minute * 60 + second) + fraction - Double(offset)
        return Date(timeIntervalSince1970: seconds)
    }

    private static func daysIn(month: Int, year: Int) -> Int {
        switch month {
        case 2: return (year % 4 == 0 && year % 100 != 0) || year % 400 == 0 ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }

    /// Days since 1970-01-01 for a date in the proleptic Gregorian calendar.
    private static func daysFromCivil(year: Int, month: Int, day: Int) -> Int {
        let y = month <= 2 ? year - 1 : year
        let era = (y >= 0 ? y : y - 399) / 400
        let yearOfEra = y - era * 400
        let dayOfYear = (153 * ((month + 9) % 12) + 2) / 5 + day - 1
        let dayOfEra = yearOfEra * 365 + yearOfEra / 4 - yearOfEra / 100 + dayOfYear
        return era * 146_097 + dayOfEra - 719_468
    }
}

private final class RouteXMLDelegate: NSObject, XMLParserDelegate {
    private typealias Fix = (point: GeoPoint, time: Date?)

    /// Pieces of a file are one route when each starts within this many metres
    /// of where the one before ended (a recording paused and resumed, a short
    /// gap in the signal). A piece that starts farther away is a different trip.
    static let joinGap = 1_000.0

    private var creator: String?
    private var isKML = false
    private var name: String?
    /// One entry per `<trkseg>` (or `<trk>` that holds points directly).
    private var trackSegments: [[Fix]] = []
    /// One entry per `<rte>`.
    private var routeSegments: [[Fix]] = []
    private var waypoints: [Fix] = []
    /// KML: one entry per LineString, per LinearRing (a polygon's outline) and
    /// per gx:Track.
    private var kmlLines: [[GeoPoint]] = []
    private var kmlRings: [[GeoPoint]] = []
    private var kmlTracks: [[GeoPoint]] = []
    private var kmlPlacemarks: [GeoPoint] = []

    private(set) var skippedPoints = 0
    /// Any element was seen.
    private(set) var startedDocument = false
    /// The outermost element was closed.
    private(set) var finishedDocument = false

    private var stack: [String] = []
    private var text = ""
    private var current: (kind: String, fix: Fix)?
    private var localNames: [String: String] = [:]

    // Foundation's readers are slow but forgiving (`2024-5-1T8:0:0Z`, a trailing
    // space). They only see stamps the fast reader declined, and are dropped
    // once a run of stamps proves a file's stamps are unreadable.
    private lazy var isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private lazy var iso = ISO8601DateFormatter()
    private var unreadableStamps = 0

    private func time(_ value: String) -> Date? {
        if let date = GPXTime.date(from: value) { return date }
        guard unreadableStamps < 64 else { return nil }
        if let date = isoFractional.date(from: value) ?? iso.date(from: value) { return date }
        unreadableStamps += 1
        return nil
    }

    func result() -> ImportedRoute? {
        func fromFixes(_ joined: (items: [Fix], skipped: Int), waypointList: Bool) -> ImportedRoute {
            ImportedRoute(name: name, points: joined.items.map { $0.point }, timestamps: joined.items.map { $0.time },
                          isWaypointList: waypointList, skippedPoints: skippedPoints, skippedSegments: joined.skipped)
        }
        func fromPoints(_ joined: (items: [GeoPoint], skipped: Int), waypointList: Bool) -> ImportedRoute {
            ImportedRoute(name: name, points: joined.items, timestamps: joined.items.map { _ in nil },
                          isWaypointList: waypointList, skippedPoints: skippedPoints, skippedSegments: joined.skipped)
        }
        if isKML {
            // A line to follow beats a polygon's outline, which is only a last resort.
            for pieces in [kmlLines, kmlTracks, kmlRings] {
                let joined = Self.joined(pieces) { $0 }
                if joined.items.count >= 2 { return fromPoints(joined, waypointList: false) }
            }
            if !kmlPlacemarks.isEmpty { return fromPoints((kmlPlacemarks, 0), waypointList: true) }
            return nil
        }
        let route = Self.joined(routeSegments) { $0.point }
        // Our own exports carry the editable waypoints as a <rte>; prefer them.
        if RouteBuilder.isOwnExport(creator: creator), route.items.count >= 2 {
            return fromFixes(route, waypointList: true)
        }
        let track = Self.joined(trackSegments) { $0.point }
        if track.items.count >= 2 { return fromFixes(track, waypointList: false) }
        if !route.items.isEmpty { return fromFixes(route, waypointList: true) }
        if !waypoints.isEmpty { return fromFixes((waypoints, 0), waypointList: true) }
        if track.items.count == 1 { return fromFixes(track, waypointList: true) }
        return nil
    }

    /// Pieces recorded one after another as one list. When some piece starts
    /// more than `joinGap` from the end of the one before, the pieces fall into
    /// separate groups and only the longest group is kept.
    private static func joined<T>(_ pieces: [[T]], point: (T) -> GeoPoint) -> (items: [T], skipped: Int) {
        let pieces = pieces.filter { !$0.isEmpty }
        guard pieces.count > 1 else { return (pieces.first ?? [], 0) }
        var groups: [[[T]]] = [[pieces[0]]]
        for piece in pieces.dropFirst() {
            if let tail = groups[groups.count - 1].last?.last,
               Geo.distance(point(tail), point(piece[0])) <= joinGap {
                groups[groups.count - 1].append(piece)
            } else {
                groups.append([piece])
            }
        }
        guard groups.count > 1 else { return (pieces.flatMap { $0 }, 0) }
        func length(_ group: [[T]]) -> Double { Geo.length(of: group.flatMap { $0 }.map(point)) }
        let lengths = groups.map(length)
        var best = 0
        for (i, l) in lengths.enumerated() where l > lengths[best] { best = i }
        return (groups[best].flatMap { $0 }, pieces.count - groups[best].count)
    }

    private func local(_ name: String) -> String {
        if let cached = localNames[name] { return cached }
        let lowered: String
        if let colon = name.lastIndex(of: ":") {
            lowered = String(name[name.index(after: colon)...]).lowercased()
        } else {
            lowered = name.lowercased()
        }
        localNames[name] = lowered
        return lowered
    }

    /// A place a file names, or nil (counted) when it isn't a real one.
    private func place(_ latitude: Double?, _ longitude: Double?) -> GeoPoint? {
        if let latitude, let longitude {
            let point = GeoPoint(latitude, longitude)
            if point.isValid { return point }
        }
        skippedPoints += 1
        return nil
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let element = local(elementName)
        startedDocument = true
        stack.append(element)
        text = ""
        switch element {
        case "gpx":
            creator = attributeDict["creator"]
        case "kml":
            isKML = true
        case "trk", "trkseg":
            trackSegments.append([])
        case "rte":
            routeSegments.append([])
        case "track":
            kmlTracks.append([])
        case "trkpt", "rtept", "wpt":
            current = nil
            if let point = place(attributeDict["lat"].flatMap(Double.init), attributeDict["lon"].flatMap(Double.init)) {
                current = (kind: element, fix: (point: point, time: nil))
            }
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        text += string
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        text += String(decoding: CDATABlock, as: UTF8.self)
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?) {
        let element = local(elementName)

        switch element {
        case "time":
            if current != nil {
                current?.fix.time = time(text.trimmingCharacters(in: .whitespacesAndNewlines))
            }
        case "trkpt", "rtept", "wpt":
            if let current, current.kind == element {
                switch element {
                case "trkpt":
                    if trackSegments.isEmpty { trackSegments.append([]) }
                    trackSegments[trackSegments.count - 1].append(current.fix)
                case "rtept":
                    if routeSegments.isEmpty { routeSegments.append([]) }
                    routeSegments[routeSegments.count - 1].append(current.fix)
                default:
                    waypoints.append(current.fix)
                }
            }
            current = nil
        case "name":
            let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let parent = stack.count >= 2 ? stack[stack.count - 2] : ""
            if name == nil, !value.isEmpty,
               ["trk", "rte", "metadata", "gpx", "document", "folder", "placemark"].contains(parent) {
                name = value
            }
        case "coordinates":
            let points = kmlCoordinates(text)
            if stack.contains("linestring") {
                kmlLines.append(points)
            } else if stack.contains("linearring") {
                kmlRings.append(points)
            } else if stack.contains("point") {
                kmlPlacemarks += points
            }
        case "coord":
            // gx:coord is "lon lat alt", space-separated.
            let parts = text.split(whereSeparator: { $0.isWhitespace })
            if parts.count >= 2, let point = place(Double(parts[1]), Double(parts[0])) {
                if kmlTracks.isEmpty { kmlTracks.append([]) }
                kmlTracks[kmlTracks.count - 1].append(point)
            } else if parts.count < 2 {
                skippedPoints += 1
            }
        default:
            break
        }
        if !stack.isEmpty {
            stack.removeLast()
            if stack.isEmpty { finishedDocument = true }
        }
        text = ""
    }

    /// KML `<coordinates>`: whitespace-separated `lon,lat[,alt]` tuples. Some
    /// tools write `lon, lat, alt` with spaces after the commas, so a comma
    /// joins the pieces on either side of it into one tuple.
    private func kmlCoordinates(_ text: String) -> [GeoPoint] {
        var tuples: [String] = []
        var pending = ""
        for token in text.split(whereSeparator: { $0.isWhitespace }) {
            if pending.isEmpty {
                pending = String(token)
            } else if pending.hasSuffix(",") || token.hasPrefix(",") {
                pending += token
            } else {
                tuples.append(pending)
                pending = String(token)
            }
        }
        if !pending.isEmpty { tuples.append(pending) }

        var points: [GeoPoint] = []
        points.reserveCapacity(tuples.count)
        for tuple in tuples {
            let parts = tuple.split(separator: ",", omittingEmptySubsequences: false)
            guard parts.count >= 2 else {
                skippedPoints += 1
                continue
            }
            if let point = place(Double(parts[1]), Double(parts[0])) { points.append(point) }
        }
        return points
    }
}
