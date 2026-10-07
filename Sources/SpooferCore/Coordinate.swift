import Foundation

/// Coordinate parsing, validation and formatting shared by the CLI and GUI.
public enum Coordinate {
    public static func validate(latitude: Double, longitude: Double) throws {
        guard latitude.isFinite, (-90...90).contains(latitude) else {
            throw SpoofError("latitude out of range: \(latitude)")
        }
        guard longitude.isFinite, (-180...180).contains(longitude) else {
            throw SpoofError("longitude out of range: \(longitude)")
        }
    }

    public static func validate(_ point: GeoPoint) throws {
        try validate(latitude: point.latitude, longitude: point.longitude)
    }

    /// Tuple form of `parsePoint`, kept for existing callers.
    public static func parse(_ text: String) -> (latitude: Double, longitude: Double)? {
        guard let p = parsePoint(text) else { return nil }
        return (p.latitude, p.longitude)
    }

    /// Parse a coordinate typed or pasted in almost any common form:
    ///
    /// - decimal pairs: `48.8584, 2.2945` · `48.8584 2.2945` · `(48.8584; 2.2945)`
    /// - degrees/minutes/seconds: `48°51'30"N 2°17'40"E` · `N 48° 51.5' E 2° 17.7'` ·
    ///   `48.8584° N, 2.2945° E` · `40 41 21 N 74 2 40 W`
    /// - links: Google Maps (`@lat,lon`, `!3d…!4d…`, `?q=`), Apple Maps (`?ll=`,
    ///   `?coordinate=`), OpenStreetMap (`mlat`/`mlon`, `#map=z/lat/lon`), Bing
    ///   (`cp=lat~lon`), and `geo:` URIs.
    ///
    /// Range is not checked here — call `validate` for a helpful error.
    public static func parsePoint(_ raw: String) -> GeoPoint? {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text.count < 4096 else { return nil }
        let point = parseLink(text) ?? parseDecimalPair(text) ?? parseSexagesimal(text)
        guard let point, point.latitude.isFinite, point.longitude.isFinite else { return nil }
        return point
    }

    // MARK: - Formatting

    /// `48.858400, 2.294500`
    public static func format(_ point: GeoPoint, precision: Int = 6) -> String {
        "\(fixed(point.latitude, precision)), \(fixed(point.longitude, precision))"
    }

    /// `48°51′30.2″N 2°17′40.2″E`
    public static func formatDMS(_ point: GeoPoint) -> String {
        func dms(_ value: Double, _ positive: String, _ negative: String) -> String {
            let a = abs(value)
            var d = Int(a)
            let minutes = (a - Double(d)) * 60
            var m = Int(minutes)
            var s = ((minutes - Double(m)) * 60 * 10).rounded() / 10
            if s >= 60 { s -= 60; m += 1 }
            if m >= 60 { m -= 60; d += 1 }
            let mm = m < 10 ? "0\(m)" : "\(m)"
            let ss = s < 10 ? "0" + fixed(s, 1) : fixed(s, 1)
            return "\(d)°\(mm)′\(ss)″" + (value < 0 ? negative : positive)
        }
        return dms(point.latitude, "N", "S") + " " + dms(point.longitude, "E", "W")
    }

    static func fixed(_ value: Double, _ digits: Int) -> String {
        String(format: "%.\(digits)f", value)
    }

    // MARK: - Decimal pairs

    private static let number = #"[+-]?(?:\d+(?:\.\d*)?|\.\d+)"#

    static func parseDecimalPair(_ text: String) -> GeoPoint? {
        let pattern = #"^[\(\[]?\s*("# + number + #")\s*(?:[,;]\s*|\s+)("# + number + #")\s*[\)\]]?$"#
        guard let groups = match(pattern, in: text), groups.count == 2,
              let lat = groups[0].flatMap(Double.init), let lon = groups[1].flatMap(Double.init) else { return nil }
        return GeoPoint(lat, lon)
    }

    // MARK: - Links

    static func parseLink(_ text: String) -> GeoPoint? {
        let lower = text.lowercased()
        if lower.hasPrefix("geo:") {
            return parseGeoURI(String(text.dropFirst(4)))
        }
        guard lower.contains("://") || lower.hasPrefix("maps.") || lower.hasPrefix("www.") else { return nil }

        // Google's place pin (`!3d<lat>!4d<lon>`) is more precise than the viewport.
        if let g = match("!3d(" + number + ")!4d(" + number + ")", in: text), g.count == 2,
           let lat = g[0].flatMap(Double.init), let lon = g[1].flatMap(Double.init) {
            return GeoPoint(lat, lon)
        }

        let items = queryItems(of: text)
        for key in ["ll", "coordinate", "q", "query", "center", "sll", "destination", "daddr", "saddr", "cp", "loc"] {
            guard let value = items[key] else { continue }
            var cleaned = value.replacingOccurrences(of: "+", with: " ")
                .replacingOccurrences(of: "~", with: ",")
            if cleaned.lowercased().hasPrefix("loc:") { cleaned = String(cleaned.dropFirst(4)) }
            if let paren = cleaned.firstIndex(of: "(") { cleaned = String(cleaned[..<paren]) }
            if let p = parseDecimalPair(cleaned.trimmingCharacters(in: .whitespaces)) { return p }
        }
        for (latKey, lonKey) in [("mlat", "mlon"), ("lat", "lon"), ("lat", "lng"), ("latitude", "longitude")] {
            if let la = items[latKey].flatMap(Double.init), let lo = items[lonKey].flatMap(Double.init) {
                return GeoPoint(la, lo)
            }
        }
        if let g = match("@(" + number + "),(" + number + ")", in: text), g.count == 2,
           let lat = g[0].flatMap(Double.init), let lon = g[1].flatMap(Double.init) {
            return GeoPoint(lat, lon)
        }
        if let g = match(#"map=\d+(?:\.\d+)?/("# + number + ")/(" + number + ")", in: text), g.count == 2,
           let lat = g[0].flatMap(Double.init), let lon = g[1].flatMap(Double.init) {
            return GeoPoint(lat, lon)
        }
        return nil
    }

    private static func parseGeoURI(_ body: String) -> GeoPoint? {
        var rest = body
        var queryPoint: GeoPoint?
        if let q = rest.firstIndex(of: "?") {
            let query = rest[rest.index(after: q)...]
            for item in query.split(separator: "&") where item.lowercased().hasPrefix("q=") {
                var value = String(item.dropFirst(2)).removingPercentEncoding ?? String(item.dropFirst(2))
                if let paren = value.firstIndex(of: "(") { value = String(value[..<paren]) }
                queryPoint = parseDecimalPair(value)
            }
            rest = String(rest[..<q])
        }
        if let semi = rest.firstIndex(of: ";") { rest = String(rest[..<semi]) }
        let parts = rest.split(separator: ",")
        var pathPoint: GeoPoint?
        if parts.count >= 2, let lat = Double(parts[0]), let lon = Double(parts[1]) {
            pathPoint = GeoPoint(lat, lon)
        }
        // `geo:0,0?q=lat,lon(label)` puts the real point in the query.
        if let queryPoint, pathPoint == nil || pathPoint == GeoPoint(0, 0) { return queryPoint }
        return pathPoint
    }

    private static func queryItems(of text: String) -> [String: String] {
        var result: [String: String] = [:]
        let raw: Substring
        if let q = text.firstIndex(of: "?") {
            raw = text[text.index(after: q)...]
        } else {
            return result
        }
        let query = raw.split(separator: "#", maxSplits: 1).first ?? ""
        for pair in query.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            guard kv.count == 2 else { continue }
            let key = String(kv[0]).lowercased()
            let value = String(kv[1]).replacingOccurrences(of: "+", with: " ")
            if result[key] == nil {
                result[key] = value.removingPercentEncoding ?? value
            }
        }
        return result
    }

    // MARK: - Degrees / minutes / seconds

    private enum Axis { case latitude, longitude }
    private struct Angle { var value: Double; var axis: Axis? }

    static func parseSexagesimal(_ raw: String) -> GeoPoint? {
        var s = raw.uppercased()
        for (word, symbol) in [("DEG", "°"), ("MIN", "'"), ("SEC", "\"")] {
            s = s.replacingOccurrences(of: word, with: symbol)
        }
        let allowed = Set("0123456789.+-NSEW°º˚'′’\"″”,;:")
        guard s.allSatisfy({ allowed.contains($0) || $0.isWhitespace }) else { return nil }

        let hemispheres = s.indices.filter { "NSEW".contains(s[$0]) }
        let components: [String]
        switch hemispheres.count {
        case 0:
            let parts = s.split(whereSeparator: { $0 == "," || $0 == ";" })
            guard parts.count == 2 else { return nil }
            components = parts.map(String.init)
        case 2:
            let first = hemispheres[0], second = hemispheres[1]
            let leading = s[s.startIndex..<first].allSatisfy { $0.isWhitespace }
            if leading {
                components = [String(s[..<second]), String(s[second...])]
            } else {
                let cut = s.index(after: first)
                components = [String(s[..<cut]), String(s[cut...])]
            }
        default:
            return nil
        }

        guard let a = parseAngle(components[0]), let b = parseAngle(components[1]) else { return nil }
        switch (a.axis, b.axis) {
        case (.latitude?, .latitude?), (.longitude?, .longitude?):
            return nil
        case (.longitude?, _), (_, .latitude?):
            return GeoPoint(b.value, a.value)
        default:
            return GeoPoint(a.value, b.value)
        }
    }

    private static func parseAngle(_ raw: String) -> Angle? {
        let trimSet = CharacterSet.whitespacesAndNewlines.union(CharacterSet(charactersIn: ",;"))
        var text = raw.trimmingCharacters(in: trimSet)
        var sign = 1.0
        var axis: Axis?

        func hemisphere(_ c: Character) -> (Double, Axis) {
            switch c {
            case "S": return (-1, .latitude)
            case "E": return (1, .longitude)
            case "W": return (-1, .longitude)
            default: return (1, .latitude)
            }
        }
        if let c = text.first, "NSEW".contains(c) {
            let h = hemisphere(c)
            sign = h.0
            axis = h.1
            text.removeFirst()
        } else if let c = text.last, "NSEW".contains(c) {
            let h = hemisphere(c)
            sign = h.0
            axis = h.1
            text.removeLast()
        }
        text = text.trimmingCharacters(in: trimSet)
        if text.hasPrefix("-") || text.hasPrefix("+") {
            if axis != nil { return nil }   // "-33 S" is ambiguous
            if text.hasPrefix("-") { sign = -1 }
            text.removeFirst()
        }
        guard !text.contains("-"), !text.contains("+") else { return nil }

        let values = matches(#"\d+(?:\.\d+)?|\.\d+"#, in: text).compactMap(Double.init)
        guard (1...3).contains(values.count) else { return nil }
        let degrees = values[0]
        let minutes = values.count > 1 ? values[1] : 0
        let seconds = values.count > 2 ? values[2] : 0
        guard minutes < 60, seconds < 60 else { return nil }
        if values.count > 1, degrees != degrees.rounded(.towardZero) { return nil }
        if values.count > 2, minutes != minutes.rounded(.towardZero) { return nil }
        return Angle(value: sign * (degrees + minutes / 60 + seconds / 3600), axis: axis)
    }

    // MARK: - Regex helpers

    /// Capture groups of the first match, or nil when there is no match.
    private static func match(_ pattern: String, in text: String) -> [String?]? {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let m = regex.firstMatch(in: text, options: [], range: range) else { return nil }
        return (1..<max(1, m.numberOfRanges)).map { i in
            Range(m.range(at: i), in: text).map { String(text[$0]) }
        }
    }

    private static func matches(_ pattern: String, in text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return regex.matches(in: text, options: [], range: range).compactMap {
            Range($0.range, in: text).map { String(text[$0]) }
        }
    }
}
