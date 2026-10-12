import Foundation

/// When the iPhone app asks GitHub for the newest release again.
///
/// Once a day is plenty, and kind to GitHub's limit. But a check that never
/// got through (no signal, a plane, a captive Wi-Fi page) says nothing about
/// whether a release exists, so it must not use up the day: it tries again
/// within the hour.
public enum UpdateSchedule {
    /// How a check ended.
    public enum Outcome: String, Equatable, Sendable {
        /// GitHub answered. That includes "no releases yet" (404) and "too
        /// many requests" (403): asking again sooner would not help.
        case answered
        /// The request never got an answer.
        case noConnection
    }

    /// After GitHub answered.
    public static let afterAnswer: TimeInterval = 24 * 3600
    /// After a check that never got through.
    public static let afterNoConnection: TimeInterval = 3600

    /// Whether a check is due. With no earlier check, it is.
    public static func isDue(lastCheck: Date?, outcome: Outcome?, now: Date) -> Bool {
        guard let lastCheck else { return true }
        let wait = outcome == .noConnection ? afterNoConnection : afterAnswer
        // A clock set back since the last check shouldn't block checks for days.
        let elapsed = now.timeIntervalSince(lastCheck)
        return elapsed < 0 || elapsed > wait
    }
}
