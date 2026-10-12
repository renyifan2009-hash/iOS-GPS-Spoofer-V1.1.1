import AppKit
import SpooferCore

extension AppModel {
    /// After the Mac wakes, a held location's channel may be dead (the iPhone's side timed out while
    /// asleep). Ask the session to check it at once instead of waiting for the next move to fail.
    func observeWake() {
        NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { @Sendable _ in
            // Delivered on the main queue, but this closure must not be main-actor isolated itself.
            Task { @MainActor in AppModel.shared.session?.channelMayBeStale() }
        }
    }
}
