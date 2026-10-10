import XCTest
@testable import SpooferCore

final class CongestionTests: XCTestCase {
    func testFreeFlowingOvernight() {
        XCTAssertEqual(Congestion.factor(hour: 3, weekend: false), 1, accuracy: 0.01)
        XCTAssertEqual(Congestion.factor(hour: 2, weekend: true), 1, accuracy: 0.01)
    }

    func testRushHourIsSlowerThanNight() {
        let night = Congestion.factor(hour: 3, weekend: false)
        let morning = Congestion.factor(hour: 8, weekend: false)
        let evening = Congestion.factor(hour: 17.5, weekend: false)
        XCTAssertLessThan(morning, night)
        XCTAssertLessThan(evening, night)
        XCTAssertLessThan(morning, 0.65)                         // a real slowdown
        XCTAssertGreaterThanOrEqual(morning, Congestion.floor)   // but never below the floor
        XCTAssertLessThanOrEqual(evening, morning)               // evening peak is the worst
    }

    func testMiddayIsBetweenPeakAndFree() {
        let noon = Congestion.factor(hour: 12, weekend: false)
        XCTAssertGreaterThan(noon, Congestion.factor(hour: 8, weekend: false))
        XCTAssertLessThan(noon, 1)
    }

    func testWeekendHasNoCommutePeak() {
        XCTAssertGreaterThan(Congestion.factor(hour: 8, weekend: true),
                             Congestion.factor(hour: 8, weekend: false) + 0.2)
        XCTAssertGreaterThan(Congestion.factor(hour: 8, weekend: true), 0.9)
    }

    func testStaysWithinBounds() {
        for tenth in 0...240 {
            let hour = Double(tenth) / 10
            for weekend in [false, true] {
                let f = Congestion.factor(hour: hour, weekend: weekend)
                XCTAssertGreaterThanOrEqual(f, Congestion.floor)
                XCTAssertLessThanOrEqual(f, 1)
            }
        }
    }

    func testDateReadsLocalHourAndWeekday() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        func date(_ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
            calendar.date(from: DateComponents(year: 2026, month: month, day: day, hour: hour, minute: minute))!
        }
        // 2026-10-12 is a Monday, 2026-10-11 a Sunday.
        XCTAssertEqual(Congestion.factor(at: date(10, 12, 8, 30), calendar: calendar),
                       Congestion.factor(hour: 8.5, weekend: false), accuracy: 1e-9)
        XCTAssertEqual(Congestion.factor(at: date(10, 11, 8, 30), calendar: calendar),
                       Congestion.factor(hour: 8.5, weekend: true), accuracy: 1e-9)
    }

    /// Congestion lengthens a planned lap, through the cruise speed.
    func testCongestionLengthensATrip() {
        let plan = LapPlan(length: 3000, stops: [], limits: [],
                           zones: [SpeedZone(start: 0, end: 3000, speed: 20)], driverFactor: 1)
        let free = TripSettings(topSpeed: 30)
        var congested = TripSettings(topSpeed: 30)
        congested.trafficFactor = 0.6
        let freeTime = TripTiming.time(plan: plan, from: 0, speed: 0, settings: free, firstStop: 0)
        let slowTime = TripTiming.time(plan: plan, from: 0, speed: 0, settings: congested, firstStop: 0)
        XCTAssertGreaterThan(slowTime, freeTime * 1.3)
    }
}
