import Foundation

/// What the iPhone says while a route stands still: "Leaving in 29:41", "Resting at stop 2 · 12:03 left",
/// "Red light · 0:26". The Mac sends the reason, which of your stops (the start is 0) and the time left;
/// the stop number shown counts from 1, like the pins on the map.
public enum RouteWaitText {
    public static func describe(reason: String, stop rawStop: Int?, remaining: Double?, paused: Bool = false) -> String? {
        let clock = remaining.map { WaitDuration.countdown($0) }
        // The number comes from the network: only a stop a route could have counts (and `+ 1` can't overflow).
        let stop = rawStop.flatMap { (0..<10_000).contains($0) ? $0 : nil }
        if paused {
            guard reason == "stop" else { return nil }
            if stop == 0 { return clock.map { "Paused · leaves in \($0)" } ?? "Paused before leaving" }
            if let stop { return clock.map { "Paused · \($0) left at stop \(stop + 1)" } ?? "Paused at stop \(stop + 1)" }
            return nil
        }
        switch reason {
        case "stop":
            guard let stop else { return clock.map { "Resting · \($0) left" } ?? "Resting" }
            if stop == 0 { return clock.map { "Leaving in \($0)" } ?? "Waiting to leave" }
            return clock.map { "Resting at stop \(stop + 1) · \($0) left" } ?? "Resting at stop \(stop + 1)"
        case "light": return clock.map { "Red light · \($0)" } ?? "Red light"
        case "sign": return "Stop sign"
        case "yield": return "Giving way"
        case "crossing": return "Crosswalk"
        case "break": return clock.map { "Taking a break · \($0)" } ?? "Taking a break"
        case "turnaround": return "Turning around"
        case "arrived": return "Arrived"
        default: return nil
        }
    }
}
