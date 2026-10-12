import Foundation

// No UI code in this folder, on purpose. These files are also compiled into the unit tests
// (Tests/SpooferCoreTests/GUILogic is a link to this folder), so the rules and the wording are
// checked without opening a window.

/// Why a Start cannot run right now, in words a beginner can act on.
///
/// One list of reasons feeds three places: the hint under the Start button, the note that pops
/// up when a control is pressed anyway (a map right-click, a favorite, ⌘↩), and the grey
/// suffix on a menu item that can't run ("Teleport Here (connect an iPhone)").
enum StartIssue: Equatable, Sendable, CaseIterable {
    case helperMissing
    case noIphone
    case noDestination
    case noStartPoint
    case needTwoStops
    case findingRoads
    case stopsOnTheSameSpot
    case speedIsZero
    case durationIsZero
    case needsLiveEngine
    case stillRestoring

    /// Short, for the top line of a toast.
    var title: String {
        switch self {
        case .helperMissing: return "Install the helper first"
        case .noIphone: return "No iPhone connected"
        case .noDestination: return "Pick a place first"
        case .noStartPoint: return "Pick a starting point first"
        case .needTwoStops: return "Add at least two stops"
        case .findingRoads: return "Still finding the road route"
        case .stopsOnTheSameSpot: return "The stops are all in one place"
        case .speedIsZero: return "Set a speed above zero"
        case .durationIsZero: return "Set a duration above zero"
        case .needsLiveEngine: return "The joystick needs the live engine"
        case .stillRestoring: return "Still restoring your real location"
        }
    }

    /// One line of what to do, for the small print of a toast.
    var detail: String {
        switch self {
        case .helperMissing: return "AnyWhere needs a small helper tool to talk to your iPhone."
        case .noIphone: return "Plug it in, unlock it and tap Trust."
        case .noDestination: return "Click the map, search, or type coordinates."
        case .noStartPoint: return "Click the map or type coordinates."
        case .needTwoStops: return "Click the map to drop them."
        case .findingRoads: return "Try again in a moment."
        case .stopsOnTheSameSpot: return "Move one of them to make a route."
        case .speedIsZero: return "Pick Walk, Run or another pace."
        case .durationIsZero: return "The route needs some time to play."
        case .needsLiveEngine: return "Check Settings ▸ Engine."
        case .stillRestoring: return "Try again in a moment."
        }
    }

    /// The line under the Start button while it can't run.
    var hint: String {
        switch self {
        case .helperMissing: return "Install the helper first. Use the card on the map."
        case .noIphone: return "Connect and select an iPhone to start."
        case .noDestination: return "Pick a place on the map or enter coordinates."
        case .noStartPoint: return "Pick a starting point on the map."
        case .needTwoStops: return "Click the map to add at least two stops."
        case .findingRoads: return "Finding the road route…"
        case .stopsOnTheSameSpot: return "The stops are all in one place. Move one."
        case .speedIsZero: return "Set a speed above zero."
        case .durationIsZero: return "Set a duration above zero."
        case .needsLiveEngine: return "The joystick needs the live engine. See Settings ▸ Engine."
        case .stillRestoring: return "Still restoring your real location. Try again in a moment."
        }
    }

    /// What to add to a menu item that this blocks, or nil when the menu is not the place for it.
    var menuReason: String? {
        switch self {
        case .helperMissing: return "install the helper"
        case .noIphone: return "connect an iPhone"
        case .needsLiveEngine: return "needs the live engine"
        default: return nil
        }
    }

    var symbol: String {
        switch self {
        case .helperMissing: return "wrench.and.screwdriver.fill"
        case .noIphone: return "iphone.slash"
        case .noDestination, .noStartPoint: return "mappin.slash"
        case .needTwoStops, .stopsOnTheSameSpot: return "point.topleft.down.to.point.bottomright.curvepath"
        case .findingRoads, .stillRestoring: return "hourglass"
        case .speedIsZero: return "speedometer"
        case .durationIsZero: return "timer"
        case .needsLiveEngine: return "gamecontroller.fill"
        }
    }

    /// Something to wait out, not something to fix: shown calmly, not as a warning.
    var isJustWaiting: Bool { self == .findingRoads || self == .stillRestoring }

    /// The Start button stays grey until this is dealt with. Pressing ⌘↩ still explains why.
    var disablesStart: Bool { self != .stillRestoring }
}

/// Everything the Start button depends on, as plain values.
struct StartContext: Equatable {
    enum Kind: Equatable, Sendable { case teleport, route, joystick }

    var kind: Kind
    var helperInstalled = true
    var iPhoneAvailable = true
    /// A teleport target, or a place the iPhone already is (the joystick starts from either).
    var hasDestination = true
    var waypointCount = 0
    /// Points in the route as it will be played (it follows roads once they are found).
    var routePointCount = 0
    var findingRoads = false
    var paceByDuration = false
    var duration: TimeInterval = 600
    /// The speed the route will play at, in metres per second (0 when it can't be worked out).
    var effectiveSpeed: Double = 1.4
    var joystickNeedsLiveEngine = false
}

enum StartGuidance {
    /// The first thing in the way of a Start, in the order a person would fix them, or nil.
    static func issue(for c: StartContext) -> StartIssue? {
        if !c.helperInstalled { return .helperMissing }
        if !c.iPhoneAvailable { return .noIphone }
        switch c.kind {
        case .teleport:
            return c.hasDestination ? nil : .noDestination
        case .joystick:
            if c.joystickNeedsLiveEngine { return .needsLiveEngine }
            return c.hasDestination ? nil : .noStartPoint
        case .route:
            if c.waypointCount < 2 { return .needTwoStops }
            if c.findingRoads { return .findingRoads }
            if c.routePointCount < 2 { return .needTwoStops }
            if c.paceByDuration && c.duration <= 0 { return .durationIsZero }
            if c.effectiveSpeed <= 0 { return c.paceByDuration ? .stopsOnTheSameSpot : .speedIsZero }
            return nil
        }
    }

    /// "Teleport Here (connect an iPhone)": a menu title that says why it is grey.
    static func menuTitle(_ title: String, reason: String?) -> String {
        guard let reason, !reason.isEmpty else { return title }
        return "\(title) (\(reason))"
    }
}
