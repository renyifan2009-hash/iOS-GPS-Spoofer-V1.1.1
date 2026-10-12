import XCTest
@testable import SpooferCore

/// A recording left running while parked repeats one position thousands of times.
final class ParkedLoggerTests: XCTestCase {
    private let a = GeoPoint(37, -122)

    /// A winding route, with `repeats` extra copies of the point at `at`.
    private func winding(repeating at: Int? = nil, repeats: Int = 0) -> [GeoPoint] {
        var points: [GeoPoint] = []
        var heading = 0.0
        var p = a
        for i in 0..<60 {
            points.append(p)
            if at == i { points += Array(repeating: p, count: repeats) }
            heading += i % 7 == 0 ? 80 : (i % 3 == 0 ? 12 : -5)
            p = p.moved(by: 25, bearing: heading)
        }
        return points
    }

    func testRepeatedPositionsChangeNothing() {
        let clean = winding()
        let limits = CurveSpeeds.limits(along: RoutePath(clean), profile: .drive)
        XCTAssertFalse(limits.isEmpty)
        for at in [0, 1, 7, 30, 58, 59] {
            let parked = winding(repeating: at, repeats: 40)
            XCTAssertEqual(CurveSpeeds.limits(along: RoutePath(parked), profile: .drive), limits, "parked at \(at)")
        }
    }

    func testAParkedLoggerDoesNotMakeTheRouteSlowToPlan() {
        // 20,000 samples of the same spot (a recording left running): this was quadratic,
        // and took ten seconds here.
        let parked = winding(repeating: 30, repeats: 20_000)
        let start = Date()
        let limits = CurveSpeeds.limits(along: RoutePath(parked), profile: .drive)
        XCTAssertLessThan(Date().timeIntervalSince(start), 2.0)
        XCTAssertEqual(limits, CurveSpeeds.limits(along: RoutePath(winding()), profile: .drive))
    }
}
