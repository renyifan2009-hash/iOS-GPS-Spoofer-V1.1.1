import AppKit
import SpooferCore

/// The product used to be "iOS GPS Spoofer.app". After a drag-and-drop upgrade from the DMG
/// the old copy is still in Applications, and it shares this app's bundle ID. See `LegacyApp`.
extension AppModel {
    private static let declinedOldAppCleanupKey = "declinedOldAppCleanup"

    /// Offer, once, to move an old-named copy to the Trash. A "Keep It" answer is remembered.
    /// Never runs in development builds or in the screenshot/demo modes.
    func offerToRemoveOldApp() {
        guard Bundle.main.bundleIdentifier != nil,
              ProcessInfo.processInfo.environment["SPOOFER_SNAPSHOT"] == nil,
              !UserDefaults.standard.bool(forKey: Self.declinedOldAppCleanupKey) else { return }
        let leftovers = LegacyApp.leftovers(excluding: Bundle.main.bundleURL)
        guard !leftovers.isEmpty else { return }

        let alert = NSAlert()
        alert.messageText = "Remove the old “iOS GPS Spoofer” app?"
        alert.informativeText = """
            AnyWhere is the new version of it. Both are still in Applications, and macOS can open \
            the wrong one. The old one goes to the Trash, so you can get it back. \
            Your saved places and routes are kept.
            """
        alert.addButton(withTitle: "Move to Trash")
        alert.addButton(withTitle: "Keep It")
        guard alert.runModal() == .alertFirstButtonReturn else {
            UserDefaults.standard.set(true, forKey: Self.declinedOldAppCleanupKey)
            return
        }
        // The handler runs on a system queue, so it must not be main-actor isolated itself.
        NSWorkspace.shared.recycle(leftovers) { @Sendable trashed, error in
            let moved = trashed.count
            let failure = error.map { SpoofSession.firstLine(of: $0) }
            Task { @MainActor in
                let model = AppModel.shared
                if let failure {
                    model.appendLog("Couldn't move the old app to the Trash: \(failure)", level: .warning)
                } else {
                    model.appendLog("Moved \(moved) old “iOS GPS Spoofer” app\(moved == 1 ? "" : "s") to the Trash.", level: .success)
                }
            }
        }
    }
}
