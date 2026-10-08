import Foundation
import SpooferCore

/// Live progress of a route, for the HUD.
struct RouteProgressInfo: Equatable {
    var fraction: Double
    var lapDistance: Double
    var lapLength: Double
    var remaining: Double
    var eta: TimeInterval?
    var lap: Int
    var finished: Bool
    var loopMode: LoopMode
}

extension AppModel {

    // MARK: - Editing

    func addWaypoint(_ point: GeoPoint) {
        guard point.isValid else { return }
        waypoints.append(Waypoint(point: point))
    }

    func moveWaypoint(id: UUID, to point: GeoPoint) {
        guard let i = waypoints.firstIndex(where: { $0.id == id }) else { return }
        waypoints[i].point = point
    }

    func removeWaypoint(id: UUID) {
        waypoints.removeAll { $0.id == id }
    }

    func moveWaypoint(id: UUID, by offset: Int) {
        guard let i = waypoints.firstIndex(where: { $0.id == id }) else { return }
        let j = i + offset
        guard waypoints.indices.contains(j) else { return }
        waypoints.swapAt(i, j)
    }

    /// Insert a point halfway to the next waypoint (or the previous, if last).
    func insertMidpoint(after id: UUID) {
        guard let i = waypoints.firstIndex(where: { $0.id == id }) else { return }
        let a = waypoints[i].point
        let b = i + 1 < waypoints.count ? waypoints[i + 1].point : (i > 0 ? waypoints[i - 1].point : a)
        let mid = Geo.interpolate(a, b, fraction: 0.5)
        waypoints.insert(Waypoint(point: mid), at: min(i + 1, waypoints.count))
    }

    func reverseRoute() {
        waypoints.reverse()
    }

    func clearWaypoints() {
        waypoints.removeAll()
        routeName = nil
        savedRouteID = nil
        routeSpeed = prefs.defaultRouteSpeed
    }

    // MARK: - Geometry

    /// Recompute `routeGeometry` after waypoint / road-following changes.
    func routeInputsChanged() {
        saveRouteDraft()
        let points = waypoints.map(\.point)
        directionsTask?.cancel()
        guard followRoads, points.count >= 2 else {
            directionsTask = nil
            directionsState = .idle
            routeGeometry = points
            return
        }
        directionsState = .computing
        let travel = travelMode
        directionsTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            let result = await DirectionsService.shared.route(through: points, mode: travel)
            guard !Task.isCancelled, let self else { return }
            self.routeGeometry = result.points
            if result.failedLegs > 0 {
                self.directionsState = .partial(failedLegs: result.failedLegs)
                self.appendLog("Couldn't find a \(travel.label.lowercased()) route for \(result.failedLegs) leg(s); using straight lines there.", level: .warning)
            } else {
                self.directionsState = .idle
            }
        }
    }

    var routePath: RoutePath { RoutePath(routeGeometry) }

    /// One-way length of the route.
    var routeLength: Double { Geo.length(of: routeGeometry) }

    /// Length of one lap as played: closed for loops, out-and-back for ping-pong.
    var lapLength: Double { RoutePlayback(path: routePath, loopMode: loopMode).cycleLength }

    /// Speed (m/s) the route will be played at.
    var effectiveRouteSpeed: Double {
        switch pacing {
        case .speed:
            return routeSpeed
        case .time:
            let pass = loopMode == .loop ? lapLength : routeLength
            return routeDuration > 0 && pass > 0 ? pass / routeDuration : 0
        }
    }

    /// Time for one pass (start → end; a full lap for loops).
    var routePassDuration: TimeInterval? {
        let speed = effectiveRouteSpeed
        guard speed > 0 else { return nil }
        return (loopMode == .loop ? lapLength : routeLength) / speed
    }

    var routeSummary: String {
        var parts = [Format.distance(routeLength, units: prefs.units)]
        if effectiveRouteSpeed > 0 { parts.append(Format.speed(effectiveRouteSpeed, units: prefs.units)) }
        if let d = routePassDuration { parts.append(Format.duration(d)) }
        if loopMode != .once { parts.append(loopMode.label.lowercased()) }
        return parts.joined(separator: " · ")
    }

    /// Identifies the geometry a playback was started with.
    var routeSignature: String {
        let ends = [routeGeometry.first, routeGeometry.last].compactMap { $0 }
            .map { String(format: "%.6f,%.6f", $0.latitude, $0.longitude) }.joined(separator: ";")
        return "\(routeGeometry.count)|\(ends)|\(Int(routeLength.rounded()))|\(loopMode.rawValue)"
    }

    /// The route was edited after it started playing.
    var hasPendingRouteChange: Bool {
        guard activity == .routing, let signature = playbackSignature else { return false }
        return signature != routeSignature
    }

    var canPauseRoute: Bool { activity == .routing && canStream }

    // MARK: - Playback

    func startRoute() {
        guard routeGeometry.count >= 2 else {
            appendLog("Add at least two waypoints — click the map to drop them.", level: .warning)
            return
        }
        if directionsState == .computing {
            appendLog("Still working out the road route — try again in a moment.", level: .info)
            return
        }
        let speed = effectiveRouteSpeed
        guard speed > 0 else {
            appendLog("Set a speed or duration above zero.", level: .warning)
            return
        }
        let path = routePath
        let loop = loopMode
        guard let start = path.start else { return }

        Task {
            guard let obtained = await obtainSession(requireStreaming: false) else { return }
            let s = obtained.session
            announcedArrival = false
            isPaused = false
            playbackSignature = routeSignature
            pendingToast = Toast(symbol: "point.topleft.down.to.point.bottomright.curvepath", title: "Route started",
                                 subtitle: routeSummary, style: .info)
            if s.canStream {
                playback = RoutePlayback(path: path, loopMode: loop)
                activity = .routing
                devicePosition = start
                if obtained.isNew { s.start(at: start) } else { s.move(to: start) }
                appendLog("Route started — \(routeSummary).", level: .info)
            } else {
                do {
                    let track = try RouteBuilder.timedTrack(path: path, speed: speed, loopMode: loop)
                    let url = try RouteBuilder.writeGPX(track, name: routeName ?? "iOS GPS Spoofer route")
                    playback = RoutePlayback(path: path, loopMode: loop)
                    replaySpeed = speed
                    replayStartedAt = nil
                    activity = .routing
                    s.replay(gpxPath: url.path, summary: routeSummary)
                } catch {
                    appendLog("Couldn't build the route: \(error.localizedDescription)", level: .error)
                    if obtained.isNew { stop() }
                }
            }
        }
    }

    /// Apply waypoint edits to the running route, keeping the distance covered.
    func applyRouteChanges() {
        guard activity == .routing, let session else { return }
        guard routeGeometry.count >= 2 else { return }
        if session.canStream, let old = playback {
            playback = RoutePlayback(path: routePath, loopMode: loopMode, travelled: old.travelled)
            playbackSignature = routeSignature
            announcedArrival = false
            appendLog("Route updated.", level: .info)
        } else {
            startRoute()
        }
    }

    func togglePause() {
        guard canPauseRoute else { return }
        isPaused.toggle()
        if isPaused { deviceSpeed = 0 }
        appendLog(isPaused ? "Route paused." : "Route resumed.", level: .info)
    }

    /// Jump within the current lap (live engine only).
    func seekRoute(toFraction fraction: Double) {
        guard canPauseRoute, var pb = playback else { return }
        pb.seek(toLapFraction: fraction)
        playback = pb
        announcedArrival = pb.isFinished
        let sample = pb.current
        devicePosition = sample.point
        deviceHeading = sample.bearing
        session?.move(to: sample.point)
    }

    func restartRoute() {
        guard activity == .routing else { return }
        if canStream {
            seekRoute(toFraction: 0)
            if var pb = playback { pb.seek(toDistance: 0); playback = pb }
            announcedArrival = false
            isPaused = false
        } else {
            startRoute()
        }
    }

    var routeProgress: RouteProgressInfo? {
        guard activity == .routing, let pb = playback else { return nil }
        let speed = canStream ? effectiveRouteSpeed : replaySpeed
        let remaining = pb.loopMode == .once ? max(0, pb.path.length - pb.travelled) : pb.remainingInLap
        return RouteProgressInfo(
            fraction: pb.lapFraction,
            lapDistance: pb.lapDistance,
            lapLength: pb.cycleLength,
            remaining: remaining,
            eta: speed > 0 && !pb.isFinished ? remaining / speed : nil,
            lap: pb.lap,
            finished: pb.isFinished,
            loopMode: pb.loopMode
        )
    }

    /// Geometry to draw: what's playing, or what's being edited.
    var displayedRoute: [GeoPoint] {
        if activity == .routing, let pb = playback { return pb.path.points }
        guard mode == .route else { return [] }
        return loopMode == .loop ? RoutePath(routeGeometry).closed().points : routeGeometry
    }

    /// 0…1 of `displayedRoute` already covered (for the "travelled" overlay).
    var travelledFraction: Double {
        guard activity == .routing, let pb = playback, pb.path.length > 0 else { return 0 }
        switch pb.loopMode {
        case .once, .loop:
            return min(1, pb.lapDistance / pb.path.length)
        case .pingPong:
            let d = pb.lapDistance
            return d <= pb.path.length ? d / pb.path.length : max(0, (pb.cycleLength - d) / pb.path.length)
        }
    }
}
