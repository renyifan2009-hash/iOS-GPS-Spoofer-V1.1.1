import AppKit
import Foundation
import SpooferCore

/// Arrow keys and WASD, by direction.
enum JoystickKey {
    static let up: Set<UInt16> = [126, 13]      // ↑ W
    static let down: Set<UInt16> = [125, 1]     // ↓ S
    static let left: Set<UInt16> = [123, 0]     // ← A
    static let right: Set<UInt16> = [124, 2]    // → D
    static let all = up.union(down).union(left).union(right)
}

extension AppModel {

    // MARK: - Motion loop

    /// Ticks while a session exists, advancing routes and the joystick.
    func startMotionLoop() {
        guard motionTask == nil else { return }
        lastTick = nil
        motionTask = Task { [weak self] in
            while !Task.isCancelled {
                let interval = self?.prefs.updateInterval ?? 0.5
                try? await Task.sleep(for: .milliseconds(Int(interval * 1000)))
                guard let self else { return }
                self.motionTick()
            }
        }
    }

    func stopMotionLoop() {
        motionTask?.cancel()
        motionTask = nil
        lastTick = nil
    }

    private func motionTick() {
        let now = ContinuousClock.now
        let dt = lastTick.map { min(2.0, (now - $0).inSeconds) } ?? 0
        lastTick = now
        guard let session else { return }
        switch activity {
        case .routing:
            routeTick(dt: dt, session: session)
        case .joystick:
            joystickTick(dt: dt, session: session)
        case .holding, .none:
            if deviceSpeed != 0 { deviceSpeed = 0 }
        }
    }

    private func routeTick(dt: Double, session: SpoofSession) {
        guard var pb = playback else { return }
        if session.canStream {
            guard sessionState == .active, !isPaused, !pb.isFinished, dt > 0 else {
                if deviceSpeed != 0, isPaused || pb.isFinished || sessionState != .active { deviceSpeed = 0 }
                return
            }
            // Realistic trips switched on or off mid-route.
            if prefs.realisticTrips, trip == nil {
                trip = makeTrip(for: pb, speed: deviceSpeed)
            } else if !prefs.realisticTrips, trip != nil {
                trip = nil
                tripStatus = .moving
            }
            let distance: Double
            if var trip {
                trip.update(settings: liveTripSettings(for: trip))
                distance = trip.step(dt: dt, lapDistance: pb.lapDistance, lap: pb.lap)
                self.trip = trip
                deviceSpeed = trip.speed
                if tripStatus != trip.status { tripStatus = trip.status }
            } else {
                let speed = variedSpeed(effectiveRouteSpeed)
                distance = speed * dt
                deviceSpeed = speed
            }
            let sample = pb.advance(by: distance)
            playback = pb
            let point = withDrift(sample.point, dt: dt)
            devicePosition = point
            deviceHeading = sample.bearing
            session.move(to: point)
            if pb.isFinished { arrived(at: sample.point) }
        } else {
            // Classic engine: pymobiledevice3 replays the GPX; work out where it is.
            guard sessionState == .replaying, let started = replayStartedAt else { return }
            let elapsed = Date().timeIntervalSince(started)
            if let track = replayTrack, track.count >= 2 {
                // A realistic track: speeds and stops vary, so read where it is from the track itself.
                let now = Self.trackState(track, at: elapsed)
                let before = Self.trackState(track, at: max(0, elapsed - 1))
                devicePosition = now.point
                let moved = (now.travelled ?? 0) - (before.travelled ?? 0)
                if moved > 0.05 { deviceHeading = before.point.bearing(to: now.point) }
                deviceSpeed = max(0, moved)
                if let travelled = now.travelled { pb.seek(toDistance: travelled) }
                if pb.loopMode == .once, elapsed >= (track.last?.offset ?? 0) { pb.seek(toDistance: pb.path.length) }
                playback = pb
                if pb.isFinished { arrived(at: now.point) }
            } else {
                pb.seek(toDistance: elapsed * replaySpeed)
                playback = pb
                let sample = pb.current
                devicePosition = sample.point
                deviceHeading = sample.bearing
                deviceSpeed = pb.isFinished ? 0 : replaySpeed
                if pb.isFinished { arrived(at: sample.point) }
            }
        }
        geocodeDeviceIfNeeded()
    }

    /// When a timed track has first come `distance` metres (nil if it never does).
    static func trackTime(_ track: [RoutePoint], reaching distance: Double) -> TimeInterval? {
        guard let index = track.firstIndex(where: { ($0.travelled ?? -1) >= distance }) else { return nil }
        guard index > 0, let a = track[index - 1].travelled, let b = track[index].travelled, b > a else {
            return track[index].offset
        }
        let f = (distance - a) / (b - a)
        return track[index - 1].offset + f * (track[index].offset - track[index - 1].offset)
    }

    /// Where a timed track is `t` seconds in, and how far it has come.
    static func trackState(_ track: [RoutePoint], at t: Double) -> (point: GeoPoint, travelled: Double?) {
        guard let first = track.first else { return (GeoPoint(0, 0), nil) }
        guard t > first.offset else { return (first.point, first.travelled) }
        var lo = 0, hi = track.count - 1
        while lo < hi {
            let mid = (lo + hi + 1) / 2
            if track[mid].offset <= t { lo = mid } else { hi = mid - 1 }
        }
        let a = track[lo]
        guard lo + 1 < track.count else { return (a.point, a.travelled) }
        let b = track[lo + 1]
        let f = b.offset > a.offset ? (t - a.offset) / (b.offset - a.offset) : 0
        let travelled = a.travelled.flatMap { ta in b.travelled.map { ta + ($0 - ta) * f } }
        return (Geo.interpolate(a.point, b.point, fraction: f), travelled)
    }

    private func arrived(at point: GeoPoint) {
        deviceSpeed = 0
        guard !announcedArrival else { return }
        announcedArrival = true
        appendLog("Arrived at the destination — holding there until you stop.", level: .success)
        showToast(Toast(symbol: "flag.checkered", title: "Arrived",
                        subtitle: "Holding at the destination until you stop.", style: .success))
        recordRecent(point, name: routeName.map { "End of \($0)" })
    }

    private func joystickTick(dt: Double, session: SpoofSession) {
        guard session.canStream, sessionState == .active, dt > 0 else { return }
        let input = joystickInput
        let dx = Double(input.dx), dy = Double(input.dy)
        let magnitude = min(1.0, hypot(dx, dy))
        guard let from = joystickPosition ?? devicePosition ?? target else { return }
        var goal = 0.0
        if magnitude > 0.05 {
            goal = prefs.joystickSpeed * magnitude * (sprinting ? 2.5 : 1)
            // Pad "up" is screen-up, whichever way the map is rotated.
            joystickHeadingNow = Geo.normalizedBearing(atan2(dx, dy) * 180 / .pi + mapHeading)
        }
        var speed = goal
        if prefs.realisticTrips {
            // Ease in and out, a little brisker than a planned trip so it feels responsive.
            let profile = MotionProfile.forSpeed(prefs.joystickSpeed)
            speed = joystickSpeedNow < goal ? min(goal, joystickSpeedNow + 2 * profile.acceleration * dt)
                                            : max(goal, joystickSpeedNow - 2 * profile.braking * dt)
        }
        joystickSpeedNow = speed
        let next = speed > 0.01 ? from.moved(by: speed * dt, bearing: joystickHeadingNow) : from
        joystickPosition = next
        let shown = withDrift(next, dt: dt)
        // Standing still with no GPS wobble: nothing to send.
        guard speed > 0.01 || prefs.positionJitter > 0 else {
            if deviceSpeed != 0 { deviceSpeed = 0 }
            return
        }
        devicePosition = shown
        if speed > 0.01 { deviceHeading = joystickHeadingNow }
        deviceSpeed = speed
        session.move(to: shown)
        geocodeDeviceIfNeeded()
    }

    /// Smooth random-walk speed variation (Settings ▸ Movement).
    private func variedSpeed(_ base: Double) -> Double {
        let variation = prefs.speedVariation
        guard variation > 0 else { return base }
        speedNoise = min(1, max(-1, speedNoise * 0.92 + Double.random(in: -0.25...0.25)))
        return max(0.1, base * (1 + variation * speedNoise))
    }

    /// The point as a GPS receiver would report it: off by a slowly wandering
    /// error the size of Settings ▸ Movement ▸ GPS wobble.
    private func withDrift(_ point: GeoPoint, dt: Double) -> GeoPoint {
        guard prefs.positionJitter > 0 else { return point }
        if drift.size != prefs.positionJitter { drift.size = prefs.positionJitter }
        return drift.apply(to: point, dt: dt)
    }

    // MARK: - Joystick

    /// Combined pad + keyboard input; keys win while held.
    var joystickInput: CGVector {
        guard !pressedKeys.isEmpty else { return padVector }
        var x = 0.0, y = 0.0
        if !pressedKeys.isDisjoint(with: JoystickKey.up) { y += 1 }
        if !pressedKeys.isDisjoint(with: JoystickKey.down) { y -= 1 }
        if !pressedKeys.isDisjoint(with: JoystickKey.left) { x -= 1 }
        if !pressedKeys.isDisjoint(with: JoystickKey.right) { x += 1 }
        let length = hypot(x, y)
        return length > 0 ? CGVector(dx: x / length, dy: y / length) : .zero
    }

    var joystickActive: Bool { activity == .joystick }

    func startJoystick() {
        guard let start = devicePosition ?? target else {
            appendLog("Pick a starting point: click the map or enter coordinates.", level: .warning)
            return
        }
        Task {
            guard let obtained = await obtainSession(requireStreaming: true) else { return }
            playback = nil
            isPaused = false
            if obtained.isNew {
                pendingToast = Toast(symbol: "gamecontroller.fill", title: "Joystick ready",
                                     subtitle: "Drag the pad, or use WASD / the arrow keys", style: .info)
                obtained.session.start(at: start)
                devicePosition = start
            }
            joystickPosition = devicePosition ?? start
            joystickSpeedNow = 0
            activity = .joystick
            appendLog("Joystick on — drag the pad, or use the arrow keys / WASD (hold ⇧ to go faster).", level: .info)
        }
    }

    /// Hand control to the joystick from wherever the device is now.
    func takeJoystickControl() {
        guard let session else { startJoystick(); return }
        guard session.canStream else {
            appendLog("The joystick needs the live engine (see Settings ▸ Engine).", level: .warning)
            return
        }
        playback = nil
        isPaused = false
        joystickPosition = devicePosition
        joystickSpeedNow = 0
        activity = .joystick
    }

    // MARK: - Keyboard

    func installKeyboardMonitor() {
        guard keyMonitor == nil else { return }
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .flagsChanged]) { event in
            let consumed = MainActor.assumeIsolated { AppModel.shared.handleKey(event) }
            return consumed ? nil : event
        }
        resignObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didResignKeyNotification, object: nil, queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                AppModel.shared.pressedKeys.removeAll()
                AppModel.shared.sprinting = false
            }
        }
    }

    /// Returns true when the event drove the joystick (and should be swallowed).
    func handleKey(_ event: NSEvent) -> Bool {
        if event.type == .flagsChanged {
            sprinting = event.modifierFlags.contains(.shift)
            return false
        }
        let code = event.keyCode
        guard JoystickKey.all.contains(code) else { return false }
        if event.type == .keyUp {
            let wasHeld = pressedKeys.remove(code) != nil
            return wasHeld && activity == .joystick
        }
        guard activity == .joystick,
              event.modifierFlags.intersection([.command, .control, .option]).isEmpty else { return false }
        // Typing in a text field? Leave the keys alone.
        if let responder = event.window?.firstResponder, responder is NSText { return false }
        pressedKeys.insert(code)
        return true
    }
}
