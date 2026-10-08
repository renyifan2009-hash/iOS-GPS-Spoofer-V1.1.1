#if DEBUG
import AppKit
import SpooferCore
import SwiftUI

/// Development aid, compiled into debug builds only: look at the real app,
/// in real states, without taking over the screen.
///
///   SPOOFER_SNAPSHOT=1   no Dock icon, never activates, and every window is
///                        parked on the desktop level, behind all other
///                        windows. `screencapture -l <id>` still captures them;
///                        their ids are printed as "SNAPSHOT-WINDOW <id> <title>".
///   SPOOFER_APPEARANCE=dark|light   force the look.
///   SPOOFER_WINDOW_SIZE=1040x692    the main window's size.
///   SPOOFER_DEMO=…       play a scene: `teleport`, `route`, `route-roads`
///                        (Follow roads and Loop on), `joystick` (once an
///                        iPhone shows up), or `settings` (opens Settings;
///                        `settings-remote` / `settings-movement` /
///                        `settings-about` for that tab).
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
    private static var settingsWindow: NSWindow?

    static func start() {
        guard isOn else { return }
        NSApp.setActivationPolicy(.accessory)
        // SPOOFER_APPEARANCE=dark|light, to check both looks.
        switch ProcessInfo.processInfo.environment["SPOOFER_APPEARANCE"] {
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        default: break
        }
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
                // SPOOFER_WINDOW_SIZE=1040x692: a small laptop screen.
                if let size = ProcessInfo.processInfo.environment["SPOOFER_WINDOW_SIZE"]?.split(separator: "x"),
                   size.count == 2, let w = Double(size[0]), let h = Double(size[1]), !window.isSheet,
                   window.title != "Settings" {
                    window.setFrame(NSRect(x: 40, y: 40, width: w, height: h), display: true)
                }
                print("SNAPSHOT-WINDOW \(window.windowNumber) \(window.title.isEmpty ? "(untitled)" : window.title)")
                fflush(stdout)
            }
        }
        runDemoIfReady()
        if Date().timeIntervalSince(lastReport) >= 2 {
            lastReport = Date()
            let model = AppModel.shared
            let visible = NSApp.windows.filter { $0.occlusionState.contains(.visible) }.map(\.windowNumber)
            let device = AppModel.shared.devicePosition.map { String(format: "%.5f,%.5f", $0.latitude, $0.longitude) } ?? "-"
            print("SNAPSHOT-STATS frames=\(frameTicks) visibleWindows=\(visible) following=\(following) gliding=\(gliding) "
                  + "cameraOffset=\(String(format: "%.1f", cameraOffset))m device=\(device) "
                  + "route=\(model.routeGeometry.count)+\(model.closingLeg?.count ?? 0) directions=\(model.directionsState) "
                  + "speed=\(String(format: "%.1f", model.deviceSpeed)) trip=\(model.tripStatus) roadData=\(model.roadDataState) "
                  + "lights=\(model.roadFeatures.uniqueCount(of: .trafficSignal)) signs=\(model.roadFeatures.uniqueCount(of: .stopSign)) "
                  + "zones=\(model.roadFeatures.zones.count) eta=\(model.routeProgress?.eta.map { String(format: "%.0f", $0) } ?? "-")")
            fflush(stdout)
        }
    }

    private static func runDemoIfReady() {
        let model = AppModel.shared
        if demo?.hasPrefix("settings") == true, !demoStarted {
            demoStarted = true
            // The real Settings scene won't open for an app that never
            // activates, so host the same view in a plain window.
            // `settings-remote` and `settings-about` open on that tab.
            let tab: SettingsView.Tab = switch demo {
            case "settings-remote": .remote
            case "settings-about": .about
            case "settings-movement": .movement
            default: .general
            }
            let view = SettingsView(tab: tab)
                .environment(AppModel.shared)
                .environment(Preferences.shared)
                .environment(LibraryStore.shared)
                .tint(Brand.accent)
            let window = NSWindow(contentViewController: NSHostingController(rootView: view))
            window.title = "Settings"
            window.setContentSize(NSSize(width: 660, height: 560))
            window.orderFrontRegardless()
            settingsWindow = window
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
        case "route", "route-roads":
            model.mode = .route
            model.clearWaypoints()
            for point in [GeoPoint(37.3349, -122.0090), GeoPoint(37.3318, -122.0312),
                          GeoPoint(37.3230, -122.0322), GeoPoint(37.3175, -122.0110)] {
                model.addWaypoint(point)
            }
            model.followRoads = demo == "route-roads"
            model.travelMode = .driving
            model.loopMode = .loop
            if demo == "route-roads", model.waypoints.count > 1 {
                model.setWait(120, forWaypoint: model.waypoints[1].id)   // shows a stop's wait
            }
            model.pacing = .speed
            model.routeSpeed = 31   // about 70 mph, like a tester's drive
            // After the mode switch has framed the route (and Apple Maps has
            // answered), like a person would.
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                while model.directionsState == .computing { try? await Task.sleep(for: .milliseconds(200)) }
                model.startRoute()
            }
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
