import Foundation
import XCTest
@testable import PhoneOnlyCore

final class UpdateScheduleTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_760_000_000)

    func testFirstCheckIsDue() {
        XCTAssertTrue(UpdateSchedule.isDue(lastCheck: nil, outcome: nil, now: now))
    }

    func testAfterAnAnswerWaitsADay() {
        let hourAgo = now.addingTimeInterval(-3600)
        let almostDay = now.addingTimeInterval(-(24 * 3600 - 60))
        let overDay = now.addingTimeInterval(-(24 * 3600 + 60))
        XCTAssertFalse(UpdateSchedule.isDue(lastCheck: hourAgo, outcome: .answered, now: now))
        XCTAssertFalse(UpdateSchedule.isDue(lastCheck: almostDay, outcome: .answered, now: now))
        XCTAssertTrue(UpdateSchedule.isDue(lastCheck: overDay, outcome: .answered, now: now))
    }

    /// A check made on a plane must not hide a new release for a day.
    func testACheckThatNeverGotThroughIsRetriedWithinTheHour() {
        let tenMinutes = now.addingTimeInterval(-600)
        let overHour = now.addingTimeInterval(-(3600 + 60))
        XCTAssertFalse(UpdateSchedule.isDue(lastCheck: tenMinutes, outcome: .noConnection, now: now))
        XCTAssertTrue(UpdateSchedule.isDue(lastCheck: overHour, outcome: .noConnection, now: now))
    }

    func testAnOldCheckWithNoRecordedOutcomeFollowsTheDailyRule() {
        XCTAssertFalse(UpdateSchedule.isDue(lastCheck: now.addingTimeInterval(-7200), outcome: nil, now: now))
        XCTAssertTrue(UpdateSchedule.isDue(lastCheck: now.addingTimeInterval(-90_000), outcome: nil, now: now))
    }

    func testAClockSetBackDoesNotBlockChecks() {
        XCTAssertTrue(UpdateSchedule.isDue(lastCheck: now.addingTimeInterval(86_400 * 30), outcome: .answered, now: now))
    }

    func testOutcomesRoundTripThroughTheirStoredNames() {
        XCTAssertEqual(UpdateSchedule.Outcome(rawValue: "answered"), .answered)
        XCTAssertEqual(UpdateSchedule.Outcome(rawValue: "noConnection"), .noConnection)
        XCTAssertNil(UpdateSchedule.Outcome(rawValue: "other"))
    }

    // MARK: - Where the checks go (iphone-app-06)

    func testReleaseLinksAllUseTheSameRepository() {
        XCTAssertTrue(Repository.releasesLatestURL.contains(Repository.slug))
        XCTAssertTrue(Repository.latestReleaseAPI.contains(Repository.slug))
        XCTAssertTrue(Repository.releasesLatestURL.hasPrefix("https://github.com/"))
        XCTAssertTrue(Repository.latestReleaseAPI.hasPrefix("https://api.github.com/repos/"))
    }

    /// The project's repository is V1.2.3. The V1.1.1 repository is an old copy
    /// that gets no new releases, so a check against it never finds one.
    func testTheRepositoryIsNotTheOldCopy() {
        XCTAssertFalse(Repository.slug.contains("V1.1.1"))
        XCTAssertFalse(Repository.releasesLatestURL.contains("V1.1.1"))
        XCTAssertFalse(Repository.latestReleaseAPI.contains("V1.1.1"))
    }
}
