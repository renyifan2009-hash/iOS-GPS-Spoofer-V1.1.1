import XCTest
import SpooferCore

/// When does replacing the route in the editor lose work? (Logic/RouteDraftGuard.swift, linked
/// into this test target as GUILogic.) Also: taking favorites out so Undo can put them back.
final class RouteDraftGuardTests: XCTestCase {
    private let a = GeoPoint(37.3349, -122.0090)
    private let b = GeoPoint(37.3318, -122.0312)
    private let c = GeoPoint(37.3230, -122.0322)

    private func snapshot(_ points: [GeoPoint], waits: [TimeInterval] = [], followRoads: Bool = false,
                          travel: TravelMode = .walking, loop: LoopMode = .once) -> RouteSnapshot {
        RouteSnapshot(points: points, waits: waits, followRoads: followRoads, travelMode: travel, loopMode: loop)
    }

    private func saved(_ points: [GeoPoint], waits: [Double]? = nil, followRoads: Bool = false,
                       travel: TravelMode = .walking, loop: LoopMode = .once) -> RouteSnapshot {
        RouteSnapshot(saved: SavedRoute(name: "Commute", waypoints: points, followRoads: followRoads,
                                        travelMode: travel, loopMode: loop, waits: waits))
    }

    // MARK: Is there work to lose?

    func testNothingToLoseWithoutARoute() {
        XCTAssertFalse(RouteDraftGuard.hasUnsavedWork(editing: snapshot([]), savedCopy: nil))
        // One pin is not a route.
        XCTAssertFalse(RouteDraftGuard.hasUnsavedWork(editing: snapshot([a]), savedCopy: nil))
    }

    func testThirtyStopsThatWereNeverSavedAreWorthAsking() {
        // The tester's case: ten minutes of placing stops, then a click on a saved route.
        let many = (0..<30).map { GeoPoint(37.0 + Double($0) * 0.001, -122.0) }
        XCTAssertTrue(RouteDraftGuard.hasUnsavedWork(editing: snapshot(many), savedCopy: nil))
    }

    func testAnUnchangedSavedRouteIsSafeToReplace() {
        XCTAssertFalse(RouteDraftGuard.hasUnsavedWork(editing: snapshot([a, b, c]), savedCopy: saved([a, b, c])))
    }

    func testEditingASavedRouteMakesItWorthAskingAgain() {
        // Moved a stop, added one, reordered, or changed an option: the saved copy no longer matches.
        let copy = saved([a, b, c])
        XCTAssertTrue(RouteDraftGuard.hasUnsavedWork(editing: snapshot([a, b]), savedCopy: copy))
        XCTAssertTrue(RouteDraftGuard.hasUnsavedWork(editing: snapshot([a, c, b]), savedCopy: copy))
        XCTAssertTrue(RouteDraftGuard.hasUnsavedWork(editing: snapshot([a, b, GeoPoint(37.32, -122.03)]), savedCopy: copy))
        XCTAssertTrue(RouteDraftGuard.hasUnsavedWork(editing: snapshot([a, b, c], followRoads: true), savedCopy: copy))
        XCTAssertTrue(RouteDraftGuard.hasUnsavedWork(editing: snapshot([a, b, c], loop: .loop), savedCopy: copy))
        XCTAssertTrue(RouteDraftGuard.hasUnsavedWork(editing: snapshot([a, b, c], travel: .driving), savedCopy: copy))
    }

    func testAWaitCountsAsPartOfTheRoute() {
        let copy = saved([a, b, c])
        XCTAssertTrue(RouteDraftGuard.hasUnsavedWork(editing: snapshot([a, b, c], waits: [0, 120, 0]), savedCopy: copy))
        // Older saves have no waits at all, or fewer waits than stops: that means no wait.
        XCTAssertFalse(RouteDraftGuard.hasUnsavedWork(editing: snapshot([a, b, c], waits: [0, 0, 0]), savedCopy: saved([a, b, c], waits: nil)))
        XCTAssertFalse(RouteDraftGuard.hasUnsavedWork(editing: snapshot([a, b, c], waits: [0, 60, 0]), savedCopy: saved([a, b, c], waits: [0, 60])))
    }

    func testARouteWhoseSavedCopyWasDeletedIsUnsaved() {
        // savedRouteID still points at it, but the library no longer has it.
        XCTAssertTrue(RouteDraftGuard.hasUnsavedWork(editing: snapshot([a, b]), savedCopy: nil))
    }

    func testTheLastDecimalsOfASavedStopDoNotMatter() {
        let nudged = GeoPoint(a.latitude + 1e-12, a.longitude - 1e-12)
        XCTAssertFalse(RouteDraftGuard.hasUnsavedWork(editing: snapshot([nudged, b]), savedCopy: saved([a, b])))
    }

    // MARK: Undo for a removed favorite

    private func place(_ name: String) -> SavedPlace { SavedPlace(name: name, point: a) }

    func testRemovedFavoritesGoBackWhereTheyWere() {
        let list = ["Home", "Work", "Gym", "Park", "Cafe"].map(place)
        let result = FavoriteListEdit.removing(from: list) { $0.name == "Work" || $0.name == "Park" }
        XCTAssertEqual(result.list.map(\.name), ["Home", "Gym", "Cafe"])
        XCTAssertEqual(result.removed.map(\.index), [1, 3])

        let restored = FavoriteListEdit.restoring(result.removed, into: result.list)
        XCTAssertEqual(restored, list)
    }

    func testUndoStillWorksAfterOtherFavoritesChanged() {
        let list = ["Home", "Work", "Gym"].map(place)
        let result = FavoriteListEdit.removing(from: list) { $0.name == "Gym" }
        // Meanwhile the list got shorter: the place goes to the end, not off the end.
        let shorter = Array(result.list.prefix(1))
        let restored = FavoriteListEdit.restoring(result.removed, into: shorter)
        XCTAssertEqual(restored.map(\.name), ["Home", "Gym"])
    }

    func testUndoTwiceDoesNotDuplicate() {
        let list = ["Home", "Work"].map(place)
        let result = FavoriteListEdit.removing(from: list) { $0.name == "Work" }
        let once = FavoriteListEdit.restoring(result.removed, into: result.list)
        let twice = FavoriteListEdit.restoring(result.removed, into: once)
        XCTAssertEqual(twice.map(\.name), ["Home", "Work"])
    }
}
