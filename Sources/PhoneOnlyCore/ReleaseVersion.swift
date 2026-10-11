import Foundation

/// A released version of the whole project: the `VERSION` file in the repo
/// root ("2.3.0") and a GitHub release tag ("v2.3.0"). SpoofRemote carries the
/// VERSION it was built from and compares it with GitHub's newest release tag,
/// to tell when a newer version is out.
public struct ReleaseVersion: Equatable, Comparable, Sendable, CustomStringConvertible {
    /// The version as numbers: "2.3.0" -> [2, 3, 0].
    public let components: [Int]

    /// Reads "2.3.0", "v2.3.0", and a build suffix like "2.3.0-ci.45" (which
    /// keeps 2.3.0). Nil when there's no number to read.
    public init?(_ string: String) {
        // A "-ci.45" or "+meta" suffix isn't part of the version to compare.
        let core = string.prefix { $0 != "-" && $0 != "+" }
        let numbers = core.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) }
        guard !numbers.isEmpty else { return nil }
        components = numbers
    }

    public var description: String { components.map(String.init).joined(separator: ".") }

    /// Number by number, with a missing part counting as 0 (so 2.3 == 2.3.0).
    public static func < (a: ReleaseVersion, b: ReleaseVersion) -> Bool {
        let count = max(a.components.count, b.components.count)
        for index in 0..<count {
            let left = index < a.components.count ? a.components[index] : 0
            let right = index < b.components.count ? b.components[index] : 0
            if left != right { return left < right }
        }
        return false
    }

    /// Equal when neither is older, so a trailing zero doesn't matter.
    public static func == (a: ReleaseVersion, b: ReleaseVersion) -> Bool {
        !(a < b) && !(b < a)
    }
}

/// Decides whether SpoofRemote should tell someone a newer version is out.
/// Every input is a string that may not be a version; anything unreadable
/// means "say nothing", never an error.
public enum ReleaseUpdate {
    /// Is `latest` (a GitHub release tag) a newer version than `current` (the
    /// VERSION this build was made from)?
    public static func isNewer(latest: String?, than current: String?) -> Bool {
        guard let latest = latest.flatMap(ReleaseVersion.init),
              let current = current.flatMap(ReleaseVersion.init) else { return false }
        return latest > current
    }

    /// Show the notice when a newer release exists and the person hasn't
    /// already dismissed that release (or a newer one). After a dismissal the
    /// notice comes back only for a release newer than the dismissed one.
    public static func shouldShow(latest: String?, current: String?, dismissed: String?) -> Bool {
        guard let latest = latest.flatMap(ReleaseVersion.init),
              let current = current.flatMap(ReleaseVersion.init),
              latest > current else { return false }
        if let dismissed = dismissed.flatMap(ReleaseVersion.init) {
            return latest > dismissed
        }
        return true
    }
}
