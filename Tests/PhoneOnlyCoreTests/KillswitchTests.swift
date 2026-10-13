import XCTest
@testable import PhoneOnlyCore

final class KillswitchTests: XCTestCase {
    func testThePresetsAreTheOnesOnTheMenu() {
        XCTAssertEqual(Killswitch.presetMinutes, [15, 30, 60, 120, 240])
        XCTAssertEqual(Killswitch.presetMinutes.map { Killswitch.label(minutes: $0) },
                       ["15 minutes", "30 minutes", "1 hour", "2 hours", "4 hours"])
    }

    func testLabelsReadLikeAPerson() {
        XCTAssertEqual(Killswitch.label(minutes: 0), "Never")
        XCTAssertEqual(Killswitch.label(minutes: -5), "Never")
        XCTAssertEqual(Killswitch.label(minutes: 1), "1 minute")
        XCTAssertEqual(Killswitch.label(minutes: 45), "45 minutes")
        XCTAssertEqual(Killswitch.label(minutes: 60), "1 hour")
        XCTAssertEqual(Killswitch.label(minutes: 90), "1 hour 30 minutes")
        XCTAssertEqual(Killswitch.label(minutes: 61), "1 hour 1 minute")
        XCTAssertEqual(Killswitch.label(minutes: 120), "2 hours")
        XCTAssertEqual(Killswitch.label(minutes: 5_000), "24 hours")   // held at a day
    }

    func testSanitizeTurnsNonsenseOffAndHoldsAtADay() {
        XCTAssertEqual(Killswitch.sanitize(minutes: 0), 0)
        XCTAssertEqual(Killswitch.sanitize(minutes: -1), 0)
        XCTAssertEqual(Killswitch.sanitize(minutes: Int.min), 0)
        XCTAssertEqual(Killswitch.sanitize(minutes: 30), 30)
        XCTAssertEqual(Killswitch.sanitize(minutes: 24 * 60), 24 * 60)
        XCTAssertEqual(Killswitch.sanitize(minutes: Int.max), 24 * 60)
    }

    func testParsingWhatAPersonTypes() {
        XCTAssertEqual(Killswitch.parse("45"), 45)
        XCTAssertEqual(Killswitch.parse(" 45 min "), 45)
        XCTAssertEqual(Killswitch.parse("90m"), 90)
        XCTAssertEqual(Killswitch.parse("1.5 h"), 90)
        XCTAssertEqual(Killswitch.parse("1,5 hours"), 90)
        XCTAssertEqual(Killswitch.parse("2 HOURS"), 120)
        XCTAssertEqual(Killswitch.parse("1:30"), 90)
        XCTAssertEqual(Killswitch.parse("0:20"), 20)
        XCTAssertEqual(Killswitch.parse("24h"), 24 * 60)
    }

    func testParsingRefusesWhatIsNotATime() {
        for text in ["", "  ", "abc", "0", "-5", "0 min", "25h", "1441", "1:75", "1:2:3", ":30", "5 weeks", "nan", "inf", "1e9", "∞",
                     // Far too big: refused, never an overflow.
                     "99999999999999999999", "99999999999999999999 minutes", "99999999999999999999 hours",
                     "9223372036854775807", "9223372036854775807 h", "9223372036854775807:00",
                     "92233720368547758:30", "1441.4", "24.1 h", String(repeating: "9", count: 400)] {
            XCTAssertNil(Killswitch.parse(text), "“\(text)”")
        }
    }

    func testTheDeadline() {
        let start = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(Killswitch.deadline(from: start, minutes: 15), start.addingTimeInterval(900))
        XCTAssertEqual(Killswitch.deadline(from: start, minutes: 120), start.addingTimeInterval(7_200))
        XCTAssertNil(Killswitch.deadline(from: start, minutes: 0))
        XCTAssertNil(Killswitch.deadline(from: start, minutes: -3))
    }

    func testRemainingNeverGoesBelowZero() {
        let deadline = Date(timeIntervalSince1970: 2_000)
        XCTAssertEqual(Killswitch.remaining(until: deadline, now: Date(timeIntervalSince1970: 1_000)), 1_000)
        XCTAssertEqual(Killswitch.remaining(until: deadline, now: deadline), 0)
        XCTAssertEqual(Killswitch.remaining(until: deadline, now: Date(timeIntervalSince1970: 9_999)), 0)
    }

    func testTheCountdownText() {
        XCTAssertEqual(Killswitch.countdown(0), "0:00")
        XCTAssertEqual(Killswitch.countdown(-4), "0:00")
        XCTAssertEqual(Killswitch.countdown(59.2), "1:00")      // rounds up: it never says 0:00 before it fires
        XCTAssertEqual(Killswitch.countdown(899), "14:59")
        XCTAssertEqual(Killswitch.countdown(900), "15:00")
        XCTAssertEqual(Killswitch.countdown(3_723), "1:02:03")
        // Not numbers a clock can show: never a crash.
        XCTAssertEqual(Killswitch.countdown(.nan), "0:00")
        XCTAssertEqual(Killswitch.countdown(.infinity), "0:00")
        XCTAssertEqual(Killswitch.countdown(-.infinity), "0:00")
        XCTAssertEqual(Killswitch.countdown(1e300), "99:59:59")
    }
}
