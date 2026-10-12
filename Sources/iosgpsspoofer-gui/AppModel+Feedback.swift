import Foundation
import SpooferCore

/// Saying why something didn't happen. A control that does nothing, with the reason only in a
/// collapsed log, looks broken: every refusal now also shows up as a note over the map.
extension AppModel {

    // MARK: - Why Start can't run

    /// What a Start would need, read from the model (the rules are in Logic/StartGuidance.swift).
    func startContext(for kind: StartContext.Kind, hasDestination: Bool? = nil) -> StartContext {
        var c = StartContext(kind: kind)
        c.helperInstalled = pmd != nil
        // A running session has its own iPhone, even if the sidebar has moved on.
        c.iPhoneAvailable = selectedDevice != nil || session != nil
        switch kind {
        case .teleport:
            c.hasDestination = hasDestination ?? (target != nil)
        case .joystick:
            c.hasDestination = hasDestination ?? (target != nil || devicePosition != nil)
            c.joystickNeedsLiveEngine = joystickNeedsLiveEngine
        case .route:
            c.waypointCount = waypoints.count
            c.routePointCount = routeGeometry.count
            c.findingRoads = directionsState == .computing
            c.paceByDuration = pacing == .time
            c.duration = routeDuration
            c.effectiveSpeed = effectiveRouteSpeed
        }
        return c
    }

    func startIssue(for kind: StartContext.Kind, hasDestination: Bool? = nil) -> StartIssue? {
        StartGuidance.issue(for: startContext(for: kind, hasDestination: hasDestination))
    }

    /// The first thing in the way of the big Start button in the current mode.
    var startIssue: StartIssue? {
        switch mode {
        case .teleport: return startIssue(for: .teleport)
        case .route: return startIssue(for: .route)
        case .joystick: return startIssue(for: .joystick)
        }
    }

    /// The joystick can't run: the engine in use can't stream movement. (iOS 16 and older
    /// iPhones move step by step with either engine.)
    var joystickNeedsLiveEngine: Bool {
        if let session, !session.canStream { return true }
        let legacy = activeDevice?.isLegacy ?? false
        if prefs.enginePreference == .classic { return !legacy }
        if case .classicOnly = engineStatus { return !legacy }
        return false
    }

    // MARK: - Saying so

    /// Show why a Start (or a move) was refused: a note over the map, and a line in the log.
    func explain(_ issue: StartIssue) {
        let waiting = issue.isJustWaiting
        appendLog("\(issue.title). \(issue.detail)", level: waiting ? .info : .warning)
        showToast(Toast(symbol: issue.symbol, title: issue.title, subtitle: issue.detail,
                        style: waiting ? .info : .warning), duration: 4.5)
    }

    /// The same for anything that isn't a Start. `log` is a longer line for the log, if the
    /// toast's words aren't enough.
    func warn(_ title: String, _ detail: String? = nil, log: String? = nil) {
        appendLog(log ?? (detail.map { "\(title). \($0)" } ?? title), level: .warning)
        showToast(Toast(symbol: "exclamationmark.triangle.fill", title: title, subtitle: detail, style: .warning),
                  duration: 4.5)
    }
}
