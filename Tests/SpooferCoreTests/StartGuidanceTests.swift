import XCTest

/// The Mac app's Start button and the reasons it gives when it can't run. The rules live in
/// Sources/iosgpsspoofer-gui/Logic (linked into this test target as GUILogic), so none of this
/// needs a window or an iPhone.
final class StartGuidanceTests: XCTestCase {
    private func issue(_ kind: StartContext.Kind, _ edit: (inout StartContext) -> Void = { _ in }) -> StartIssue? {
        var c = StartContext(kind: kind)
        edit(&c)
        return StartGuidance.issue(for: c)
    }

    // MARK: Teleport

    func testTeleportNeedsTheHelperThenAnIPhoneThenAPlace() {
        XCTAssertEqual(issue(.teleport) { $0.helperInstalled = false; $0.iPhoneAvailable = false; $0.hasDestination = false },
                       .helperMissing)
        XCTAssertEqual(issue(.teleport) { $0.iPhoneAvailable = false; $0.hasDestination = false }, .noIphone)
        XCTAssertEqual(issue(.teleport) { $0.hasDestination = false }, .noDestination)
        XCTAssertNil(issue(.teleport))
    }

    // MARK: Joystick

    func testJoystickNeedsTheLiveEngineBeforeAStartingPoint() {
        XCTAssertEqual(issue(.joystick) { $0.joystickNeedsLiveEngine = true; $0.hasDestination = false }, .needsLiveEngine)
        XCTAssertEqual(issue(.joystick) { $0.hasDestination = false }, .noStartPoint)
        XCTAssertNil(issue(.joystick))
    }

    // MARK: Route

    func testRouteWithFewerThanTwoStops() {
        XCTAssertEqual(issue(.route) { $0.waypointCount = 0 }, .needTwoStops)
        XCTAssertEqual(issue(.route) { $0.waypointCount = 1; $0.routePointCount = 1 }, .needTwoStops)
    }

    func testRouteWhileTheRoadsAreStillBeingFound() {
        // Two stops, no road geometry yet: that's "finding the road route", not "add stops".
        let c = issue(.route) { $0.waypointCount = 2; $0.routePointCount = 0; $0.findingRoads = true }
        XCTAssertEqual(c, .findingRoads)
        XCTAssertTrue(c?.isJustWaiting ?? false, "waiting is shown calmly, not as a warning")
    }

    func testRouteWithADurationOfZeroSaysSo() {
        // The tester's case: Duration 0:00:00 greyed Start out with no hint at all.
        let c = issue(.route) {
            $0.waypointCount = 3; $0.routePointCount = 3
            $0.paceByDuration = true; $0.duration = 0; $0.effectiveSpeed = 0
        }
        XCTAssertEqual(c, .durationIsZero)
    }

    func testRouteWithNoSpeedAndRouteLengthZero() {
        XCTAssertEqual(issue(.route) {
            $0.waypointCount = 2; $0.routePointCount = 2; $0.effectiveSpeed = 0
        }, .speedIsZero)
        // Pacing by duration with a duration set, but no distance to cover.
        XCTAssertEqual(issue(.route) {
            $0.waypointCount = 2; $0.routePointCount = 2
            $0.paceByDuration = true; $0.duration = 600; $0.effectiveSpeed = 0
        }, .stopsOnTheSameSpot)
    }

    func testAGoodRouteHasNoIssue() {
        XCTAssertNil(issue(.route) { $0.waypointCount = 4; $0.routePointCount = 40 })
    }

    // MARK: Words

    func testEveryIssueHasPlainWords() {
        for issue in StartIssue.allCases {
            for text in [issue.title, issue.detail, issue.hint] {
                XCTAssertFalse(text.isEmpty, "\(issue)")
                // New copy: short sentences, no em dashes, no semicolons.
                XCTAssertFalse(text.contains("—"), "\(issue): \(text)")
                XCTAssertFalse(text.contains(";"), "\(issue): \(text)")
                XCTAssertFalse(text.lowercased().contains("pymobiledevice3"), "\(issue): \(text)")
            }
            // Toast small print has room for two lines at most.
            XCTAssertLessThanOrEqual(issue.detail.count, 90, "\(issue)")
            XCTAssertLessThanOrEqual(issue.title.count, 40, "\(issue)")
        }
    }

    func testOnlyTheRealBlockersGreyOutStart() {
        XCTAssertTrue(StartIssue.noIphone.disablesStart)
        XCTAssertTrue(StartIssue.findingRoads.disablesStart)
        XCTAssertTrue(StartIssue.durationIsZero.disablesStart)
        XCTAssertFalse(StartIssue.stillRestoring.disablesStart)
    }

    // MARK: Menus

    func testAMenuItemThatCantRunSaysWhy() {
        XCTAssertEqual(StartGuidance.menuTitle("Teleport Here", reason: "connect an iPhone"),
                       "Teleport Here (connect an iPhone)")
        XCTAssertEqual(StartGuidance.menuTitle("Teleport Here", reason: nil), "Teleport Here")
        XCTAssertEqual(StartGuidance.menuTitle("Teleport Here", reason: ""), "Teleport Here")
    }

    func testTheIssuesAMapMenuCanBlockHaveAShortReason() {
        XCTAssertEqual(StartIssue.helperMissing.menuReason, "install the helper")
        XCTAssertEqual(StartIssue.noIphone.menuReason, "connect an iPhone")
        XCTAssertEqual(StartIssue.needsLiveEngine.menuReason, "needs the live engine")
        // A missing destination never blocks a right-click: the click is the destination.
        XCTAssertNil(StartIssue.noDestination.menuReason)
    }
}
