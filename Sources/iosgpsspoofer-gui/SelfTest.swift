import AppKit
import SpooferCore
import SwiftUI

/// `ANYWHERE_SELF_TEST=1 AnyWhere.app/Contents/MacOS/AnyWhere`
///
/// Starts the real app (windows, model, helper probe), but with no Dock icon, no focus stealing
/// and every window parked behind everything else, lets it run for a few seconds, prints
/// `SELF-TEST-OK …` and quits with status 0. A crash anywhere on the way ends the process with a
/// signal instead, so the exit status says whether this build of the app can start on this Mac.
///
/// Why it exists: an app compiled on a Mac whose Swift toolchain and macOS SDK don't match can
/// build fine and then crash at launch ("AnyWhere quit unexpectedly"). `setup.sh`, the in-app
/// updater and CI run this on the freshly built app *before* it replaces a working one.
@MainActor
enum SelfTest {
    static let isOn = ProcessInfo.processInfo.environment["ANYWHERE_SELF_TEST"] == "1"
    /// How long to run, in seconds (ANYWHERE_SELF_TEST_SECONDS; default 6).
    static let seconds: Double = {
        let value = Double(ProcessInfo.processInfo.environment["ANYWHERE_SELF_TEST_SECONDS"] ?? "") ?? 6
        return min(max(value, 1), 120)
    }()

    private static var started = false
    /// Windows already moved out of the way. Each is parked once: re-ordering windows over and
    /// over makes SwiftUI rebuild the whole main menu every time (a bundled app has one), which on
    /// a slow virtual machine can keep the main thread busy for good.
    private static var parked: Set<Int> = []
    private static let parkingOn = ProcessInfo.processInfo.environment["ANYWHERE_SELF_TEST_NOPARK"] != "1"

    static func begin() {
        guard isOn, !started else { return }
        started = true
        // No Dock icon, and nothing here ever activates the app.
        NSApp.setActivationPolicy(.accessory)
        if parkingOn {
            Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
                MainActor.assumeIsolated { parkNewWindows() }
            }
        }
        Timer.scheduledTimer(withTimeInterval: seconds, repeats: false) { _ in
            MainActor.assumeIsolated { finish() }
        }
    }

    /// New windows go behind every other window, on the desktop level, so a person at the Mac sees nothing.
    private static func parkNewWindows() {
        for window in NSApp.windows where (window.isVisible || window.isSheet) && parked.insert(window.windowNumber).inserted {
            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
            window.collectionBehavior.insert([.canJoinAllSpaces, .fullScreenAuxiliary])
            window.ignoresMouseEvents = true
            window.orderFrontRegardless()
        }
    }

    private static func finish() {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "dev"
        let windows = NSApp.windows.filter { $0.isVisible }.count
        print("SELF-TEST-OK version=\(version) windows=\(windows) seconds=\(Int(seconds))")
        fflush(stdout)
        // Close what is open first: with the first-launch Welcome sheet showing, AppKit ignores
        // terminate(_:) when it is called from a timer in an app that isn't active (it doesn't even
        // ask the delegate). If it still hasn't gone after a moment, leave directly: the test has
        // already said everything it has to say.
        let model = AppModel.shared
        model.showWelcome = false
        model.showPairingFile = false
        model.showConnectionHelp = false
        PhoneInstaller.shared.isPresented = false
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { NSApp.terminate(nil) }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) { exit(0) }
    }
}
