import Foundation

/// How long a route waits at one of its stops: read from what a person types ("30", "45 min", "1h 30m",
/// "1:30", "half an hour") and written back as short text. The iPhone app and the Mac app both use it, so a
/// wait reads the same everywhere.
public enum WaitDuration {
    /// The longest wait at one stop: a day. A visit can be long; a typo of extra zeros shouldn't park the
    /// route for weeks.
    public static let maxSeconds: Double = 24 * 3600

    /// The quick choices offered next to the text field and in the Mac's menu, in seconds.
    public static let presets: [Double] = [0, 60, 300, 900, 1800, 3600, 7200]

    public enum Parsed: Equatable, Sendable, CustomStringConvertible {
        case wait(Double)
        case tooLong
        case unreadable

        /// What to show under the field while typing.
        public var description: String {
            switch self {
            case .wait(let seconds): return WaitDuration.format(seconds)
            case .tooLong: return "That's longer than 24 hours."
            case .unreadable: return "Type a time like 20, 45 min or 1h 30m."
            }
        }
    }

    /// Reads a typed time. A bare number is minutes ("30" is half an hour); a bare number after hours is
    /// minutes ("1h30") and after minutes is seconds ("5m30"); "1:30" is an hour and a half.
    public static func parse(_ text: String) -> Parsed {
        var s = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !s.isEmpty else { return .unreadable }
        switch s {
        case "no wait", "none", "no", "now", "0", "0 min": return .wait(0)
        case "half an hour", "half hour", "half a hour", "1/2 hour", "1/2 h": return .wait(1800)
        default: break
        }
        if s.contains(":") { return clock(s) }
        // A comma between two digits is a decimal comma ("1,5 h" where that's how decimals are written);
        // any other comma just separates ("1 h, 15 min").
        s = s.replacingOccurrences(of: #"(\d),(\d)"#, with: "$1.$2", options: .regularExpression)
        s = s.replacingOccurrences(of: ",", with: " ")
        // "an hour", "a minute": the article is a one.
        s = " " + s + " "
        for word in [" an ", " a ", " one "] { s = s.replacingOccurrences(of: word, with: " 1 ") }
        s = s.replacingOccurrences(of: " and ", with: " ")

        var total = 0.0
        var lastUnit: Double?
        var rest = Substring(s)
        while true {
            rest = rest.drop { $0 == " " }
            if rest.isEmpty { break }
            guard let first = rest.first, first.isASCII, first.isNumber else { return .unreadable }
            // A plain decimal number: digits, then optionally a dot and more digits. No sign, no exponent.
            var digits = String(rest.prefix { $0.isASCII && $0.isNumber })
            rest = rest.dropFirst(digits.count)
            if rest.first == ".", let next = rest.dropFirst().first, next.isASCII, next.isNumber {
                let fraction = rest.dropFirst().prefix { $0.isASCII && $0.isNumber }
                digits += "." + fraction
                rest = rest.dropFirst(1 + fraction.count)
            }
            guard let value = Double(digits), value.isFinite else { return .unreadable }
            rest = rest.drop { $0 == " " }
            let word = String(rest.prefix { $0.isLetter })
            rest = rest.dropFirst(word.count)
            let unit: Double
            if word.isEmpty {
                switch lastUnit {
                case nil: unit = 60          // "30" alone: minutes
                case 3600: unit = 60         // "1h30"
                case 60: unit = 1            // "5m30"
                default: return .unreadable  // nothing smaller than seconds
                }
            } else {
                guard let named = units[word] else { return .unreadable }
                unit = named
            }
            total += value * unit
            lastUnit = unit
            guard total.isFinite else { return .tooLong }
        }
        return finish(total)
    }

    /// "1:30" (h:mm) or "1:02:03" (h:mm:ss).
    private static func clock(_ s: String) -> Parsed {
        let parts = s.split(separator: ":", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 2 || parts.count == 3,
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isNumber } }) else { return .unreadable }
        let numbers = parts.compactMap { Double($0) }
        guard numbers.count == parts.count, numbers.dropFirst().allSatisfy({ $0 < 60 }) else { return .unreadable }
        var total = numbers[0] * 3600 + numbers[1] * 60
        if numbers.count == 3 { total += numbers[2] }
        return finish(total)
    }

    private static func finish(_ total: Double) -> Parsed {
        guard total.isFinite else { return .tooLong }
        let rounded = total.rounded()
        if rounded > maxSeconds { return .tooLong }
        return .wait(max(0, rounded))
    }

    private static let units: [String: Double] = [
        "s": 1, "sec": 1, "secs": 1, "second": 1, "seconds": 1,
        "m": 60, "min": 60, "mins": 60, "minute": 60, "minutes": 60,
        "h": 3600, "hr": 3600, "hrs": 3600, "hour": 3600, "hours": 3600,
    ]

    /// A wait from a file, the network or a menu, made safe to use: 0 if it isn't a number, at most a day.
    public static func clamp(_ seconds: Double) -> Double {
        seconds.isFinite ? min(max(0, seconds), maxSeconds) : 0
    }

    /// Whole seconds in 0...maxSeconds, whatever comes in (NaN, negative, huge), so the arithmetic below
    /// can never trap.
    private static func whole(_ seconds: Double, roundUp: Bool = false) -> Int {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        let bounded = min(seconds, maxSeconds)
        return Int(roundUp ? bounded.rounded(.up) : bounded.rounded())
    }

    /// "No wait", "45 sec", "1 min 30 sec", "30 min", "1 h 30 min". Every second it has is shown, so the text
    /// an editor starts with reads back as the same wait.
    public static func format(_ seconds: Double) -> String {
        let total = whole(seconds)
        guard total > 0 else { return "No wait" }
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        var parts: [String] = []
        if h > 0 { parts.append("\(h) h") }
        if m > 0 { parts.append("\(m) min") }
        if s > 0 { parts.append("\(s) sec") }
        return parts.joined(separator: " ")
    }

    /// For a map pin: "45s", "30m", "1h30", "2h". Empty for no wait.
    public static func short(_ seconds: Double) -> String {
        let total = whole(seconds)
        guard total > 0 else { return "" }
        if total < 60 { return "\(total)s" }
        if total < 3600 {
            let m = total / 60, r = total % 60
            return r > 0 ? "\(m)m\(r)" : "\(m)m"
        }
        let h = total / 3600, m = (total % 3600) / 60
        return m > 0 ? "\(h)h\(m)" : "\(h)h"
    }

    /// A countdown: "29:41", "1:02:03". Rounds up, so it never shows 0:00 while there is still a wait.
    public static func countdown(_ seconds: Double) -> String {
        guard seconds.isFinite else { return "0:00" }
        let total = whole(seconds, roundUp: true)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
