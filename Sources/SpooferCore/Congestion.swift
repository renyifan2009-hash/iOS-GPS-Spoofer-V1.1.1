import Foundation

/// A cruise-speed multiplier for the time of day, so a drive crawls in rush
/// hour and runs free overnight. 1.0 means free-flowing (cruising at the speed
/// limit); lower means slower than the limit.
///
/// The shape follows typical urban congestion: on a weekday, a morning peak
/// around 8am and a slightly worse evening peak around 5–6pm, a mild midday
/// lull, and free-flowing nights. Weekends have no commute peaks, just a gentle
/// midday rise as people go out.
///
/// It is **off by default**: `TripSettings.trafficFactor` is 1.0 unless the app
/// opts in, and it only scales cruising speed — the waits at lights, signs and
/// your own stops are unchanged. There's no live-traffic source, so this is a
/// believable daily pattern, not the real congestion on a given road right now.
public enum Congestion {
    /// The slowest it gets: at a bad peak, cruising speed is this fraction of
    /// the limit. ~0.55 is roughly an 80% travel-time increase on the open-road
    /// stretches, in line with peak-hour slowdowns in congested cities.
    public static let floor = 0.55

    /// A Gaussian bump: `height` at `center` hours, fading over `width` hours.
    private static func bump(_ hour: Double, center: Double, width: Double, height: Double) -> Double {
        let d = (hour - center) / width
        return height * exp(-0.5 * d * d)
    }

    /// The multiplier for a fractional `hour` (0–24) and whether it's a weekend.
    public static func factor(hour: Double, weekend: Bool) -> Double {
        let dip: Double
        if weekend {
            // No commute; a broad, gentle afternoon rise.
            dip = bump(hour, center: 14, width: 3.2, height: 0.18)
        } else {
            let morning = bump(hour, center: 8.0, width: 1.1, height: 0.40)
            let evening = bump(hour, center: 17.5, width: 1.5, height: 0.43)
            let midday = bump(hour, center: 12.5, width: 3.0, height: 0.12)
            // The peaks don't stack (you're in one or the other); midday is a
            // low background that eases the dip between them.
            dip = max(morning, evening) + 0.5 * midday
        }
        return max(floor, min(1, 1 - dip))
    }

    /// The multiplier for a date, from its local hour and weekday.
    public static func factor(at date: Date, calendar: Calendar = .current) -> Double {
        let parts = calendar.dateComponents([.hour, .minute, .weekday], from: date)
        let hour = Double(parts.hour ?? 12) + Double(parts.minute ?? 0) / 60
        let weekend = parts.weekday == 1 || parts.weekday == 7   // 1 = Sunday, 7 = Saturday
        return factor(hour: hour, weekend: weekend)
    }
}
