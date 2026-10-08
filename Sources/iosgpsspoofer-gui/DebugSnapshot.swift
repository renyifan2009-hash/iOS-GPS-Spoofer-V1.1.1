#if DEBUG
import AppKit
import SpooferCore

/// Development aid, compiled into debug builds only: look at the real app,
/// in real states, without taking over the screen.
///
///   SPOOFER_SNAPSHOT=1   no Dock icon, never activates, and every window is
///                        parked on the desktop level, behind all other
///                        windows. `screencapture -l <id>` still captures them;
///                        their ids are printed as "SNAPSHOT-WINDOW <id> <title>".
///   SPOOFER_DEMO=…       play a scene: `teleport`, `route`, `joystick` (once
///                        an iPhone shows up), or `settings` (opens Settings).
///
/// Pair it with Tests/Fixtures/fake-pymobiledevice3 (via $PYMOBILEDEVICE3)
/// for a pretend iPhone.
@MainActor
enum DebugSnapshot {
    static let isOn = ProcessInfo.processInfo.environment["SPOOFER_SNAPSHOT"] == "1"
    static let demo = ProcessInfo.processInfo.environment["SPOOFER_DEMO"]

    private static var announced: Set<Int> = []
    private static var demoStarted = false
    /// Frames the map's display link has drawn (MapPicker counts them).
    static var frameTicks = 0
    /// Metres between the map's centre and the drawn dot, and the follow state.
    static var cameraOffset = -1.0
    static var following = false
    static var gliding = false
    private static var lastReport = Date.distantPast

    static func start() {
        guard isOn else { return }
        NSApp.setActivationPolicy(.accessory)
        Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { _ in
            MainActor.assumeIsolated { tick() }
        }
    }

    private static func tick() {
        for window in NSApp.windows where window.isVisible || window.isSheet {
            window.level = NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.desktopWindow)))
            window.collectionBehavior.insert([.canJoinAllSpaces, .fullScreenAuxiliary])
            window.orderFrontRegardless()
            if announced.insert(window.windowNumber).inserted {
                print("SNAPSHOT-WINDOW \(window.windowNumber) \(window.title.isEmpty ? "(untitled)" : window.title)")
                fflush(stdout)
            }
        }
        runDemoIfReady()
        if Date().timeIntervalSince(lastReport) >= 2 {
            lastReport = Date()
            let visible = NSApp.windows.filter { $0.occlusionState.contains(.visible) }.map(\.windowNumber)
            let device = AppModel.shared.devicePosition.map { String(format: "%.5f,%.5f", $0.latitude, $0.longitude) } ?? "-"
            print("SNAPSHOT-STATS frames=\(frameTicks) visibleWindows=\(visible) following=\(following) gliding=\(gliding) "
                  + "cameraOffset=\(String(format: "%.1f", cameraOffset))m device=\(device)")
            fflush(stdout)
        }
    }

    private static func runDemoIfReady() {
        let model = AppModel.shared
        if demo == "settings", !demoStarted {
            demoStarted = true
            NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            return
        }
        guard let demo, !demoStarted, model.selectedDevice != nil, model.startupSweepDone else { return }
        demoStarted = true
        model.showWelcome = false
        model.showInspector = true
        switch demo {
        case "teleport":
            model.mode = .teleport
            model.setTarget(GeoPoint(48.8584, 2.2945), name: "Eiffel Tower, Paris", focus: true)
            model.teleportToTarget()
        case "route":
            model.mode = .route
            model.clearWaypoints()
            for point in [GeoPoint(37.3349, -122.0090), GeoPoint(37.3318, -122.0312),
                          GeoPoint(37.3230, -122.0322), GeoPoint(37.3175, -122.0110)] {
                model.addWaypoint(point)
            }
            model.followRoads = false
            model.loopMode = .loop
            model.pacing = .speed
            model.routeSpeed = 31   // about 70 mph, like a tester's drive
            model.startRoute()
        case "joystick":
            model.mode = .joystick
            model.setTarget(GeoPoint(40.7580, -73.9855), name: "Times Square, New York", focus: true)
            model.startJoystick()
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(2))
                model.padVector = CGVector(dx: 0.55, dy: 0.8)
            }
        default:
            print("SNAPSHOT: unknown SPOOFER_DEMO \(demo)")
        }
    }
}
#endif
