import Foundation
import Observation
import PhoneOnlyCore

/// Tells the person when a newer version of iOS GPS Spoofer is out, so they
/// can reinstall SpoofRemote from the release page (SpoofRemote doesn't update
/// itself). Once a day at most it asks GitHub for the newest release and
/// compares its tag with the VERSION this app was built from.
///
/// It sends nothing about the person or the iPhone. No network, a GitHub
/// limit, or an odd answer shows nothing, never an error. The notice can be
/// dismissed, and comes back only for a release newer than the dismissed one.
@MainActor
@Observable
final class UpdateChecker {
    enum State: Equatable {
        case idle
        /// A newer release is out. The string is its version, for the notice.
        case available(String)
    }

    private(set) var state: State = .idle

    /// The VERSION this build was made from (stamped in by project.yml).
    let current = BuildVersion.version
    /// The page to open to get the newest version.
    let releaseURL = URL(string: Repository.releasesLatestURL)!

    private static let lastCheckKey = "update.lastCheck"
    private static let lastLatestKey = "update.lastLatestTag"
    private static let dismissedKey = "update.dismissedRelease"

    var updateAvailable: Bool {
        if case .available = state { return true }
        return false
    }

    /// The newer version to show, like "2.4.0".
    var latestVersion: String? {
        if case .available(let version) = state { return version }
        return nil
    }

    init() {
        #if DEBUG
        // For screenshots: `-SpoofRemotePretendUpdate 9.9.9` pretends a newer
        // release is out, so the notice shows without the network.
        if let pretend = UserDefaults.standard.string(forKey: "SpoofRemotePretendUpdate"), !pretend.isEmpty {
            state = .available(Self.display(pretend))
        }
        #endif
    }

    /// Show a notice from what we already know, then, at most once a day, ask
    /// GitHub again. Safe to call on every appearance.
    func checkIfDue() {
        #if DEBUG
        if case .available = state { return }  // keep a pretended notice
        #endif
        applyStored()
        let last = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > 24 * 3600 else { return }
        Task { await check() }
    }

    /// Ask GitHub now and update the notice.
    func check() async {
        let latest = await Self.latestReleaseTag()
        UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)
        guard let latest else { return }  // no answer: leave what we had, say nothing new
        UserDefaults.standard.set(latest, forKey: Self.lastLatestKey)
        applyStored()
    }

    /// Hide the notice and remember this release, so it only comes back for a
    /// newer one.
    func dismiss() {
        guard case .available(let version) = state else { return }
        UserDefaults.standard.set(version, forKey: Self.dismissedKey)
        state = .idle
    }

    /// Set the state from the last tag GitHub gave and what's been dismissed.
    private func applyStored() {
        let latest = UserDefaults.standard.string(forKey: Self.lastLatestKey)
        let dismissed = UserDefaults.standard.string(forKey: Self.dismissedKey)
        if ReleaseUpdate.shouldShow(latest: latest, current: current, dismissed: dismissed), let latest {
            state = .available(Self.display(latest))
        } else {
            state = .idle
        }
    }

    /// A tag as a plain version for the notice ("v2.4.0" -> "2.4.0").
    private static func display(_ tag: String) -> String {
        ReleaseVersion(tag).map(String.init(describing:)) ?? tag
    }

    /// GitHub's newest published release tag, or nil on any failure. Sends only
    /// a generic User-Agent (GitHub requires one); nothing about the person.
    private static func latestReleaseTag() async -> String? {
        guard let url = URL(string: Repository.latestReleaseAPI) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        request.setValue("SpoofRemote", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let tag = object["tag_name"] as? String, !tag.isEmpty else { return nil }
        return tag
    }
}
