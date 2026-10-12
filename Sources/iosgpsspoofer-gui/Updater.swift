import AppKit
import Foundation
import Observation
import PhoneOnlyCore
import SpooferCore

/// Tells people when a newer version is on GitHub, and installs it.
///
/// Two kinds of install update differently. An app that came from the release DMG (the ready-made
/// app, `SpooferChannel` = release) is updated from the newest published release: the DMG is
/// downloaded, checked against its checksum, started once as a test, and only then swapped in, so
/// it behaves exactly like the one CI built. An app built from source on this Mac (by the one-line
/// installer) is updated by running that installer again, which also tests the new build before
/// it replaces anything. Both kinds quit this app, replace it and open the new one.
@MainActor
@Observable
final class Updater {
    static let shared = Updater()

    enum State: Equatable {
        case idle
        case checking
        case upToDate
        /// A newer commit is on the main branch (nil: we don't know our own).
        case available(latest: String)
        case updating
        case failed(String)
    }

    var state: State = .idle

    /// "owner/name" and the commit this app was built from, stamped into
    /// Info.plist by scripts/make-app.sh. Unset in development builds.
    let repository: String?
    let commit: String?
    /// Where this app came from: the published release DMG, or a build on this Mac.
    enum Channel: Equatable { case release, source }
    let channel: Channel
    /// This app's own version (CFBundleShortVersionString), for the release route.
    let version: String?

    private static let lastCheckKey = "lastUpdateCheck"

    private init() {
        let info = Bundle.main.infoDictionary ?? [:]
        repository = (info["SpooferRepository"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        commit = (info["SpooferGitCommit"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        channel = (info["SpooferChannel"] as? String) == "release" ? .release : .source
        version = info["CFBundleShortVersionString"] as? String
    }

    /// Installed by the installer (so it knows where updates come from).
    var canUpdate: Bool { repository != nil }

    var updateAvailable: Bool {
        if case .available = state { return true }
        return false
    }

    /// At launch: check at most every six hours, quietly.
    func checkIfDue() {
        guard canUpdate, channel == .release || commit != nil else { return }
        let last = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date ?? .distantPast
        guard Date().timeIntervalSince(last) > 6 * 3600 else { return }
        Task {
            try? await Task.sleep(for: .seconds(8))
            await check(userInitiated: false)
        }
    }

    /// Ask GitHub for the newest commit on main.
    func check(userInitiated: Bool) async {
        guard let repository, state != .checking, state != .updating else { return }
        state = .checking
        let latest: String?
        switch channel {
        case .release: latest = await Self.latestReleaseTag(repository: repository)
        case .source: latest = await Self.latestCommit(repository: repository)
        }
        UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)
        let model = AppModel.shared
        guard let latest else {
            state = .idle
            if userInitiated {
                model.showToast(Toast(symbol: "wifi.exclamationmark", title: "Couldn't check for updates",
                                      subtitle: "Check the Mac's internet connection.", style: .warning))
            }
            return
        }
        // A release-DMG app is behind when a newer release exists; a source build, when main has moved.
        let isCurrent: Bool
        switch channel {
        case .release: isCurrent = !ReleaseUpdate.isNewer(latest: latest, than: version)
        case .source: isCurrent = commit.map { latest.hasPrefix($0) || $0.hasPrefix(latest) } ?? false
        }
        if isCurrent {
            state = .upToDate
            if userInitiated {
                model.showToast(Toast(symbol: "checkmark.seal.fill", title: "You're up to date",
                                      subtitle: "This is the newest version.", style: .success))
            }
        } else {
            state = .available(latest: latest)
            model.appendLog("A newer version is available. Click Update in the banner (or use the install command again).",
                            level: .info)
        }
    }

    /// The changes since this build, on GitHub.
    var whatsNewURL: URL? {
        guard let repository else { return nil }
        if channel == .release, case .available(let tag) = state {
            return URL(string: "https://github.com/\(repository)/releases/tag/\(tag)")
        }
        if let commit { return URL(string: "https://github.com/\(repository)/compare/\(commit)...main") }
        return URL(string: "https://github.com/\(repository)/commits/main")
    }

    /// Confirm, then update. The app quits itself at the end and the new one opens.
    func installUpdate() {
        guard let repository, state != .updating else { return }
        if channel == .release, case .available(let tag) = state {
            installRelease(repository: repository, tag: tag)
            return
        }
        let alert = NSAlert()
        alert.messageText = "Update AnyWhere?"
        alert.informativeText = """
            This downloads the newest version and builds it on this Mac, which takes a few minutes. \
            The new app is started once as a test before it replaces this one. \
            The app then restarts by itself.\(AppModel.shared.session != nil ? " Your iPhone goes back to its real location while it restarts." : "")
            """
        alert.addButton(withTitle: "Update")
        alert.addButton(withTitle: "Not Now")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let logs = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Logs/AnyWhere", isDirectory: true)
        try? FileManager.default.createDirectory(at: logs, withIntermediateDirectories: true)
        let logURL = logs.appendingPathComponent("update.log")
        FileManager.default.createFile(atPath: logURL.path, contents: nil)

        // Not tracked as a child we clean up on quit: the installer has to
        // outlive this app, because quitting it is one of its steps.
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        let installer = "https://raw.githubusercontent.com/\(repository)/main/install.sh"
        // pipefail: without it a failed download still ends in "bash read an empty script, status 0",
        // and the app would say "Updating…" for ever.
        process.arguments = ["-c", "set -o pipefail; curl -fsSL --connect-timeout 15 --max-time 120 '\(installer)' | SPOOFER_REPO='\(repository)' bash"]
        process.standardInput = FileHandle.nullDevice
        if let log = try? FileHandle(forWritingTo: logURL) {
            process.standardOutput = log
            process.standardError = log
        }
        process.terminationHandler = { @Sendable _ in
            // On success the installer quits this app, so if this app is still here, the update
            // did not finish, whatever the exit status says. The log says why.
            let reason = InstallLog.failureHeadline(inFileAt: logURL)
            Task { @MainActor in
                guard Updater.shared.state == .updating else { return }
                let detail = reason.map { "\($0) " } ?? ""
                Updater.shared.state = .failed("The update didn't finish. \(detail)Details: ~/Library/Logs/AnyWhere/update.log")
                AppModel.shared.appendLog("The update didn't finish. \(detail)See ~/Library/Logs/AnyWhere/update.log", level: .error)
            }
        }
        do {
            try process.run()
            state = .updating
            AppModel.shared.appendLog("Updating: downloading and building the newest version…", level: .info)
            // A build that has not finished after 25 minutes is stuck.
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(25 * 60))
                guard Updater.shared.state == .updating else { return }
                if process.isRunning { process.terminate() }
                Updater.shared.state = .failed("The update took too long and was stopped. Details: ~/Library/Logs/AnyWhere/update.log")
            }
        } catch {
            state = .failed("Couldn't start the installer: \(error.localizedDescription)")
        }
    }

    // MARK: - The release route

    private func installRelease(repository: String, tag: String) {
        let alert = NSAlert()
        alert.messageText = "Update AnyWhere to \(ReleaseVersion(tag)?.description ?? tag)?"
        alert.informativeText = """
            This downloads the new version (about 20 MB), checks it, starts it once as a test, and then \
            restarts the app.\(AppModel.shared.session != nil ? " Your iPhone goes back to its real location while it restarts." : "")
            """
        alert.addButton(withTitle: "Update")
        alert.addButton(withTitle: "Not Now")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        let appURL = Bundle.main.bundleURL
        state = .updating
        AppModel.shared.appendLog("Updating: downloading \(tag)…", level: .info)
        Task {
            do {
                let backup = try await Self.downloadAndStage(repository: repository, tag: tag, appURL: appURL)
                AppModel.shared.appendLog("The new version passed its start-up test. Restarting…", level: .success)
                Self.relaunch(appAt: appURL, removing: backup)
            } catch {
                let message = (error as? ReleaseInstall.Problem)?.description ?? "The update didn't finish: \(SpoofSession.firstLine(of: error))"
                Updater.shared.state = .failed(message)
                AppModel.shared.appendLog(message, level: .error)
            }
        }
    }

    /// Download, check, stage, test and swap. Returns the folder holding the old app, to delete afterwards.
    nonisolated private static func downloadAndStage(repository: String, tag: String, appURL: URL) async throws -> URL {
        try ReleaseInstall.checkReplaceable(appURL: appURL)
        let name = ReleaseInstall.dmgName(version: tag)
        guard let dmgURL = ReleaseInstall.assetURL(repository: repository, tag: tag, name: name),
              let sumsURL = ReleaseInstall.assetURL(repository: repository, tag: tag, name: PhoneApp.checksumsName) else {
            throw ReleaseInstall.Problem.checksumMissing
        }
        let sums = try? await URLSession.shared.data(from: sumsURL)
        let checksums = (sums?.1 as? HTTPURLResponse)?.statusCode == 200 ? sums.map { String(decoding: $0.0, as: UTF8.self) } : nil
        let (downloaded, response) = try await URLSession.shared.download(from: dmgURL)
        defer { try? FileManager.default.removeItem(at: downloaded) }
        guard (response as? HTTPURLResponse)?.statusCode == 200 else {
            throw ReleaseInstall.Problem.copyFailed("the release has no \(name)")
        }
        try ReleaseInstall.verifyDownload(downloaded, checksums: checksums, name: name)
        let parent = appURL.deletingLastPathComponent()
        let staged = try ReleaseInstall.stage(dmg: downloaded, beside: parent) { try ReleaseInstall.runSelfTest(of: $0) }
        return try ReleaseInstall.swap(current: appURL, with: staged)
    }

    /// Open the new app once this one has quit (waiting for it, so the dying copy isn't "activated"
    /// instead), then delete the old app's backup. Quitting restores the iPhone's real location.
    private static func relaunch(appAt app: URL, removing backup: URL) {
        let script = """
            pid=\(getpid()); n=0
            while kill -0 "$pid" 2>/dev/null && [ "$n" -lt 240 ]; do sleep 0.5; n=$((n + 1)); done
            /usr/bin/open "$1"
            sleep 10
            /bin/rm -rf "$2"
            """
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = ["-c", script, "anywhere-relaunch", app.path, backup.path]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try? process.run()
        NSApp.terminate(nil)
    }

    /// The newest published release's tag ("v2.4.0"), from the redirect of `releases/latest`. That
    /// needs no API call, so GitHub's rate limit (60 an hour per address) can't block it.
    nonisolated static func latestReleaseTag(repository: String) async -> String? {
        guard let url = ReleaseInstall.latestReleaseURL(repository: repository) else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "HEAD"
        request.setValue("AnyWhere-updater", forHTTPHeaderField: "User-Agent")
        guard let (_, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200,
              let final = response.url else { return nil }
        return ReleaseInstall.tag(fromReleaseURL: final)
    }

    func revealLog() {
        let log = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first!
            .appendingPathComponent("Logs/AnyWhere/update.log")
        NSWorkspace.shared.activateFileViewerSelecting([log])
    }

    // MARK: - GitHub

    /// The newest commit on main, from git's own ref listing (what `git
    /// ls-remote` reads). GitHub's REST API would be simpler, but it allows 60
    /// requests an hour per IP, and a VPN or a school network shares one IP
    /// between many people.
    nonisolated static func latestCommit(repository: String) async -> String? {
        guard let url = URL(string: "https://github.com/\(repository).git/info/refs?service=git-upload-pack") else {
            return nil
        }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("git/2.0 (iOS-GPS-Spoofer)", forHTTPHeaderField: "User-Agent")
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        // Lines look like "003d<40 hex digits> refs/heads/main".
        let text = String(decoding: data, as: UTF8.self)
        guard let range = text.range(of: " refs/heads/main\n") ?? text.range(of: " refs/heads/main") else { return nil }
        let sha = String(text[..<range.lowerBound].suffix(40))
        return sha.count == 40 && sha.allSatisfy(\.isHexDigit) ? sha : nil
    }
}
