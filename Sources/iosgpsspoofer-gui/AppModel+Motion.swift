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
            let speed = variedSpeed(effectiveRouteSpeed)
            let sample = pb.advance(by: speed * dt)
            playback = pb
            let point = prefs.positionJitter > 0 ? jittered(sample.point) : sample.point
            devicePosition = point
            deviceHeading = sample.bearing
            deviceSpeed = speed
            session.move(to: point)
            if pb.isFinished { arrived(at: sample.point) }
        } else {
            // Classic engine: pymobiledevice3 replays the GPX; estimate where it is.
            guard sessionState == .replaying, let started = replayStartedAt else { return }
            pb.seek(toDistance: Date().timeIntervalSince(started) * replaySpeed)
            playback = pb
            let sample = pb.current
            devicePosition = sample.point
            deviceHeading = sample.bearing
            deviceSpeed = pb.isFinished ? 0 : replaySpeed
            if pb.isFinished { arrived(at: sample.point) }
        }
        geocodeDeviceIfNeeded()
    }

    private func arrived(at point: GeoPoint) {
        deviceSpeed = 0
        guard !announcedArrival else { return }
        announcedArrival = true
        appendLog("Arrived at the destination — holding there until you stop.", level: .success)
        recordRecent(point, name: routeName.map { "End of \($0)" })
    }

    private func joystickTick(dt: Double, session: SpoofSession) {
        guard session.canStream, sessionState == .active, dt > 0 else { return }
        let input = joystickInput
        let dx = Double(input.dx), dy = Double(input.dy)
        let magnitude = min(1.0, hypot(dx, dy))
        guard magnitude > 0.05, let from = devicePosition ?? target else {
            if deviceSpeed != 0 { deviceSpeed = 0 }
            return
        }
        // Pad "up" is screen-up, whichever way the map is rotated.
        let heading = Geo.normalizedBearing(atan2(dx, dy) * 180 / .pi + mapHeading)
        let speed = prefs.joystickSpeed * magnitude * (sprinting ? 2.5 : 1)
        let next = from.moved(by: speed * dt, bearing: heading)
        devicePosition = next
        deviceHeading = heading
        deviceSpeed = speed
        session.move(to: next)
        geocodeDeviceIfNeeded()
    }

    /// Smooth random-walk speed variation (Settings ▸ Movement).
    private func variedSpeed(_ base: Double) -> Double {
        let variation = prefs.speedVariation
        guard variation > 0 else { return base }
        speedNoise = min(1, max(-1, speedNoise * 0.92 + Double.random(in: -0.25...0.25)))
        return max(0.1, base * (1 + variation * speedNoise))
    }

    private func jittered(_ point: GeoPoint) -> GeoPoint {
        point.moved(by: Double.random(in: 0...prefs.positionJitter), bearing: Double.random(in: 0..<360))
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
                obtained.session.start(at: start)
                devicePosition = start
            }
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
