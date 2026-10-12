import Foundation

/// Coordinates typed into the search field, such as "37.3349, -122.0090".
///
/// Only text that is nothing but a latitude and a longitude counts. An
/// address that happens to hold two small numbers ("Pier 39 San Francisco 37")
/// is not a coordinate, and is left for the place search.
public enum CoordinateText {
    public struct Point: Equatable, Sendable {
        public var latitude: Double
        public var longitude: Double

        public init(latitude: Double, longitude: Double) {
            self.latitude = latitude
            self.longitude = longitude
        }
    }

    /// The point `text` names, or nil if it isn't just two coordinates.
    ///
    /// These forms work: `37.3349, -122.0090`, `37.3349 -122.0090`,
    /// `(37.3349, -122.0090)`, `37.3349° N, 122.0090° W`, `N 37.3349 W 122.0090`
    /// and, with a decimal comma, `37,3349 -122,0090`.
    public static func parse(_ text: String) -> Point? {
        var cleaned = text
        for mark in ["(", ")", "[", "]", "°", "º"] { cleaned = cleaned.replacingOccurrences(of: mark, with: " ") }
        guard let items = items(in: cleaned) else { return nil }

        var entries: [(value: Double, letter: Character?)] = []
        var pendingLetter: Character?
        for item in items {
            switch item {
            case .number(let value):
                entries.append((value, pendingLetter))     // "N 37.3349" if a letter came first
                pendingLetter = nil
            case .letter(let letter):
                if pendingLetter == nil, let last = entries.indices.last, entries[last].letter == nil {
                    entries[last].letter = letter          // "37.3349 N"
                } else if pendingLetter == nil {
                    pendingLetter = letter
                } else {
                    return nil
                }
            }
        }
        guard pendingLetter == nil, entries.count == 2 else { return nil }

        var latitude = entries[0].value
        var longitude = entries[1].value
        if entries.contains(where: { $0.letter != nil }) {
            // Letters on one number mean letters on both: north or south, then east or west.
            guard let first = entries[0].letter, let second = entries[1].letter,
                  first == "N" || first == "S", second == "E" || second == "W",
                  latitude >= 0, longitude >= 0 else { return nil }
            if first == "S" { latitude = -latitude }
            if second == "W" { longitude = -longitude }
        }
        guard (-90...90).contains(latitude), (-180...180).contains(longitude) else { return nil }
        return Point(latitude: latitude, longitude: longitude)
    }

    // MARK: Reading the text

    private enum Item {
        case number(Double)
        case letter(Character)
    }

    /// The text as numbers and N, S, E, W letters, in order, or nil if
    /// anything else is in it.
    private static func items(in text: String) -> [Item]? {
        var pieces = text.split(whereSeparator: { $0.isWhitespace || $0 == ";" }).map(String.init)
        // "37,3349 -122,0090": a decimal comma, when each half has exactly one
        // comma inside it and neither half has a point.
        if pieces.count == 2, !pieces.contains(where: { $0.contains(".") }),
           pieces.allSatisfy({ $0.filter { $0 == "," }.count == 1 && !$0.hasPrefix(",") && !$0.hasSuffix(",") }) {
            pieces = pieces.map { $0.replacingOccurrences(of: ",", with: ".") }
        }

        var items: [Item] = []
        for piece in pieces {
            // "37.3349N" is a number and a letter. A comma only separates.
            var number = ""
            func finishNumber() -> Bool {
                guard !number.isEmpty else { return true }
                defer { number = "" }
                guard let value = value(of: number) else { return false }
                items.append(.number(value))
                return true
            }
            for character in piece {
                if character == "," {
                    guard finishNumber() else { return nil }
                } else if character.isASCII, character.isNumber || "+-.".contains(character) {
                    number.append(character)
                } else if let letter = hemisphere(character) {
                    guard finishNumber() else { return nil }
                    items.append(.letter(letter))
                } else {
                    return nil
                }
            }
            guard finishNumber() else { return nil }
        }
        return items
    }

    private static func hemisphere(_ character: Character) -> Character? {
        let upper = Character(character.uppercased())
        return upper == "N" || upper == "S" || upper == "E" || upper == "W" ? upper : nil
    }

    /// A plain decimal number: an optional sign, digits and at most one point.
    /// (`Double("0x10")` and `Double("1e5")` would read, and aren't coordinates.)
    private static func value(of text: String) -> Double? {
        var digits = 0
        var points = 0
        for (index, character) in text.enumerated() {
            if character.isNumber {
                digits += 1
            } else if character == "." {
                points += 1
            } else if !(index == 0 && (character == "-" || character == "+")) {
                return nil
            }
        }
        guard digits > 0, points <= 1 else { return nil }
        return Double(text)
    }
}
