import Foundation

/// "Stop spoofing after …": a fail-safe so a location isn't left on the iPhone for ever.
/// The logic that doesn't need a window lives here so it can be tested; the app arms a timer from it.
public enum Killswitch {
    /// The quick choices, in minutes. 0 is "never" and is not listed here.
    public static let presetMinutes = [15, 30, 60, 120, 240]
    /// The longest a custom time may be: a day.
    public static let maxMinutes = 24 * 60

    /// A number of minutes typed by a person (or read from settings), made safe: 0 or less means off,
    /// and more than a day is held at a day. Anything that isn't a sensible number is off.
    public static func sanitize(minutes: Int) -> Int {
        minutes <= 0 ? 0 : min(minutes, maxMinutes)
    }

    /// What a person typed in the "Custom…" box: "45", "45 min", "1.5 h", "90m", "2 hours", "1:30".
    /// nil when it isn't a time. A bare number is minutes.
    public static func parse(_ text: String) -> Int? {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !t.isEmpty else { return nil }
        // 1:30 = an hour and a half
        if t.contains(":") {
            let parts = t.split(separator: ":", omittingEmptySubsequences: false)
            guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]), h >= 0, (0..<60).contains(m) else { return nil }
            return validated(h * 60 + m)
        }
        let digits = t.prefix { $0.isNumber || $0 == "." || $0 == "," }
        let unit = t.dropFirst(digits.count).trimmingCharacters(in: .whitespaces)
        guard let value = Double(digits.replacingOccurrences(of: ",", with: ".")), value.isFinite, value > 0 else { return nil }
        let minutes: Double
        switch unit {
        case "", "m", "min", "mins", "minute", "minutes": minutes = value
        case "h", "hr", "hrs", "hour", "hours": minutes = value * 60
        default: return nil
        }
        return validated(Int(minutes.rounded()))
    }

    private static func validated(_ minutes: Int) -> Int? {
        minutes >= 1 && minutes <= maxMinutes ? minutes : nil
    }

    /// "15 minutes", "1 hour", "2 hours", "1 hour 30 minutes", "Never".
    public static func label(minutes: Int) -> String {
        let m = sanitize(minutes: minutes)
        guard m > 0 else { return "Never" }
        let h = m / 60, rest = m % 60
        let hours = h == 1 ? "1 hour" : "\(h) hours"
        let mins = rest == 1 ? "1 minute" : "\(rest) minutes"
        if h == 0 { return mins }
        return rest == 0 ? hours : "\(hours) \(mins)"
    }

    /// When the iPhone gets its real location back.
    public static func deadline(from start: Date, minutes: Int) -> Date? {
        let m = sanitize(minutes: minutes)
        return m > 0 ? start.addingTimeInterval(TimeInterval(m * 60)) : nil
    }

    /// Seconds left, never below zero.
    public static func remaining(until deadline: Date, now: Date) -> TimeInterval {
        max(0, deadline.timeIntervalSince(now))
    }

    /// The countdown shown on the card: "14:59", "1:02:03".
    public static func countdown(_ seconds: TimeInterval) -> String {
        // Int(.infinity) and Int(.nan) trap, so anything that isn't a sensible number of seconds is "0:00".
        guard seconds.isFinite, seconds > 0 else { return "0:00" }
        let total = Int(min(seconds, 359_999).rounded(.up))
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}
