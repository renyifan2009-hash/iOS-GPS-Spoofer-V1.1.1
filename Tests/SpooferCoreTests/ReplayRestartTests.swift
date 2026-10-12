import Foundation
import XCTest
@testable import SpooferCore

/// A classic route that is replayed and loses its connection starts again, and says so.
final class ReplayRestartTests: XCTestCase {
    private var harness: SessionHarness!
    private var gpx: URL!

    override func tearDown() {
        harness?.finish()
        harness = nil
        if let gpx { try? FileManager.default.removeItem(at: gpx) }
    }

    func testARouteThatDropsStartsAgainAndSaysSo() throws {
        let marker = FileManager.default.temporaryDirectory.appendingPathComponent("play-died-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: marker) }
        harness = try SessionHarness(engine: .classic, iOS: "18.0", environment: ["FAKE_PMD_PLAY_DIE_ONCE": marker.path])
        gpx = FileManager.default.temporaryDirectory.appendingPathComponent("route-\(UUID().uuidString).gpx")
        try "<gpx/>".write(to: gpx, atomically: true, encoding: .utf8)

        harness.session.replay(gpxPath: gpx.path, summary: "a test route")
        XCTAssertTrue(harness.waitForState { $0 == .replaying }, "\(harness.states)")
        // The first play dies after a moment, the second one holds.
        XCTAssertTrue(harness.wait {
            harness.logged("started again from its beginning", level: .warning)
        }, "\(harness.logs)")
        XCTAssertTrue(harness.waitForState { $0 == .replaying })
        func plays() -> [String] { harness.lines(of: harness.pmdLog).filter { $0.contains("simulate-location play") } }
        XCTAssertTrue(harness.wait { plays().count == 2 }, "\(plays())")
    }

    func testTheFirstStartIsNotCalledARestart() throws {
        harness = try SessionHarness(engine: .classic, iOS: "18.0")
        gpx = FileManager.default.temporaryDirectory.appendingPathComponent("route-\(UUID().uuidString).gpx")
        try "<gpx/>".write(to: gpx, atomically: true, encoding: .utf8)
        harness.session.replay(gpxPath: gpx.path, summary: "a test route")
        XCTAssertTrue(harness.waitForState { $0 == .replaying })
        XCTAssertFalse(harness.logged("started again"), "\(harness.logs)")
    }
}
