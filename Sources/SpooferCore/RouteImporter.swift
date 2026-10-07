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

    public init(name: String?, points: [GeoPoint], timestamps: [Date?], isWaypointList: Bool) {
        self.name = name
        self.points = points
        self.timestamps = timestamps
        self.isWaypointList = isWaypointList
    }

    public var length: Double { Geo.length(of: points) }

    /// Elapsed time between the first and last timestamped points.
    public var duration: TimeInterval? {
        guard let first = timestamps.compactMap({ $0 }).first,
              let last = timestamps.compactMap({ $0 }).last else { return nil }
        let d = last.timeIntervalSince(first)
        return d > 0 ? d : nil
    }

    /// Average speed in m/s, when the track is timestamped.
    public var averageSpeed: Double? {
        guard let duration, length > 0 else { return nil }
        return length / duration
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
    public static func parse(_ data: Data) throws -> ImportedRoute {
        let delegate = RouteXMLDelegate()
        let parser = XMLParser(data: data)
        parser.delegate = delegate
        parser.shouldProcessNamespaces = false
        let ok = parser.parse()
        guard let route = delegate.result() else {
            if !ok, let error = parser.parserError {
                throw SpoofError("could not read the route file: \(error.localizedDescription)")
            }
            throw SpoofError("no route points found in the file (expected GPX or KML)")
        }
        return route
    }
}

private final class RouteXMLDelegate: NSObject, XMLParserDelegate {
    private typealias Fix = (point: GeoPoint, time: Date?)

    private var creator: String?
    private var isKML = false
    private var name: String?
    private var track: [Fix] = []
    private var route: [Fix] = []
    private var waypoints: [Fix] = []
    private var kmlLine: [GeoPoint] = []
    private var kmlPlacemarks: [GeoPoint] = []
    private var kmlTrack: [GeoPoint] = []

    private var stack: [String] = []
    private var text = ""
    private var current: (kind: String, fix: Fix)?

    private let isoFractional: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private let iso = ISO8601DateFormatter()

    func result() -> ImportedRoute? {
        func fromFixes(_ fixes: [Fix], waypointList: Bool) -> ImportedRoute {
            ImportedRoute(name: name, points: fixes.map { $0.point }, timestamps: fixes.map { $0.time },
                          isWaypointList: waypointList)
        }
        func fromPoints(_ points: [GeoPoint], waypointList: Bool) -> ImportedRoute {
            ImportedRoute(name: name, points: points, timestamps: points.map { _ in nil },
                          isWaypointList: waypointList)
        }
        if isKML {
            if kmlLine.count >= 2 { return fromPoints(kmlLine, waypointList: false) }
            if kmlTrack.count >= 2 { return fromPoints(kmlTrack, waypointList: false) }
            if !kmlPlacemarks.isEmpty { return fromPoints(kmlPlacemarks, waypointList: true) }
            return nil
        }
        // Our own exports carry the editable waypoints as a <rte>; prefer them.
        if creator?.lowercased().hasPrefix("iosgpsspoof") == true, route.count >= 2 {
            return fromFixes(route, waypointList: true)
        }
        if track.count >= 2 { return fromFixes(track, waypointList: false) }
        if !route.isEmpty { return fromFixes(route, waypointList: true) }
        if !waypoints.isEmpty { return fromFixes(waypoints, waypointList: true) }
        if track.count == 1 { return fromFixes(track, waypointList: true) }
        return nil
    }

    private static func local(_ name: String) -> String {
        guard let colon = name.lastIndex(of: ":") else { return name.lowercased() }
        return String(name[name.index(after: colon)...]).lowercased()
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let element = Self.local(elementName)
        stack.append(element)
        text = ""
        switch element {
        case "gpx":
            creator = attributeDict["creator"]
        case "kml":
            isKML = true
        case "trkpt", "rtept", "wpt":
            if let lat = attributeDict["lat"].flatMap(Double.init),
               let lon = attributeDict["lon"].flatMap(Double.init) {
                current = (kind: element, fix: (point: GeoPoint(lat, lon), time: nil))
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
        let element = Self.local(elementName)
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let parent = stack.count >= 2 ? stack[stack.count - 2] : ""

        switch element {
        case "time":
            if current != nil { current?.fix.time = isoFractional.date(from: value) ?? iso.date(from: value) }
        case "trkpt", "rtept", "wpt":
            if let current, current.kind == element {
                switch element {
                case "trkpt": track.append(current.fix)
                case "rtept": route.append(current.fix)
                default: waypoints.append(current.fix)
                }
            }
            current = nil
        case "name":
            if name == nil, !value.isEmpty,
               ["trk", "rte", "metadata", "gpx", "document", "folder", "placemark"].contains(parent) {
                name = value
            }
        case "coordinates":
            let points = Self.kmlCoordinates(value)
            if stack.contains("linestring") || stack.contains("linearring") {
                kmlLine += points
            } else if stack.contains("point") {
                kmlPlacemarks += points
            }
        case "coord":
            // gx:coord is "lon lat alt", space-separated.
            let parts = value.split(whereSeparator: { $0 == " " || $0 == "\t" }).compactMap { Double($0) }
            if parts.count >= 2 { kmlTrack.append(GeoPoint(parts[1], parts[0])) }
        default:
            break
        }
        if !stack.isEmpty { stack.removeLast() }
        text = ""
    }

    /// KML `<coordinates>`: whitespace-separated `lon,lat[,alt]` tuples.
    private static func kmlCoordinates(_ text: String) -> [GeoPoint] {
        text.split(whereSeparator: { $0.isWhitespace }).compactMap { tuple in
            let parts = tuple.split(separator: ",").compactMap { Double($0) }
            guard parts.count >= 2 else { return nil }
            return GeoPoint(parts[1], parts[0])
        }
    }
}
