import Foundation
import RemoteAPI
import SpooferCore
import SpooferRemote

/// What the AnyWhere iPhone app can do to this window: send a route, steer with the joystick, pause, and ask
/// for Auto-stop. `AppRemoteBridge` (RemoteHost.swift) checks the request and calls these.
extension AppModel {
    /// The route the iPhone built replaces the one in the window, waits for its roads (up to 20 seconds, then
    /// goes with straight legs, as the Route tab's Start does), and starts.
    func startRemoteRoute(_ request: RouteRequest) {
        remoteRouteTask?.cancel()
        remoteJoystickMotion = nil
        mode = .route
        remoteTrafficOverride = request.travelMode == "driving" ? request.timeOfDayTraffic : false
        travelMode = TravelMode(rawValue: request.travelMode) ?? .walking
        followRoads = request.followRoads
        loopMode = LoopMode(rawValue: request.loopMode) ?? .once
        pacing = .speed
        routeSpeed = request.speed
        routeName = request.name
        savedRouteID = nil
        waypoints = request.waypoints.map {
            Waypoint(point: GeoPoint($0.latitude, $0.longitude), wait: $0.wait ?? 0)
        }
        appendLog("iPhone Remote: a \(request.waypoints.count)-point route\(request.name.map { " “\($0)”" } ?? "").", level: .info)
        remoteRouteTask = Task { [weak self] in
            // Road legs come from Apple Maps a moment after the stops are set.
            for _ in 0..<200 {
                guard let self, !Task.isCancelled else { return }
                if self.directionsState != .computing { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            guard let self, !Task.isCancelled else { return }
            self.startRoute()
            self.remoteRouteTask = nil
        }
    }

    /// A route from the iPhone is being planned: its roads are loading, it has not started yet.
    var remoteRoutePlanning: Bool { remoteRouteTask != nil && activity != .routing }

    /// Steering from the iPhone's joystick. The location must already be held.
    func steerFromPhone(_ request: JoystickRequest) {
        if activity != .joystick {
            remoteRouteTask?.cancel()
            remoteRouteTask = nil
            takeJoystickControl()
        }
        remoteJoystickMotion = JoystickMotion(request, receivedAt: Date())
    }

    /// Auto-stop for this session only, as the iPhone asked. The Mac's own saved setting is not changed.
    func armAutoStopFromPhone(minutes: Int) {
        let wanted = Killswitch.sanitize(minutes: minutes)
        armKillswitch(minutes: wanted)
        appendLog(wanted > 0 ? "iPhone Remote: Auto-stop after \(Killswitch.label(minutes: wanted))."
                             : "iPhone Remote: Auto-stop off.", level: .info)
    }
}
