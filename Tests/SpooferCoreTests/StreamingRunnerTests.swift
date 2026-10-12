import Foundation
import XCTest
@testable import SpooferCore

/// A command that is run with a deadline and its output as it arrives.
final class StreamingRunnerTests: XCTestCase {
    private final class Lines: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: [String] = []
        func add(_ line: String) { lock.lock(); stored.append(line); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return stored }
    }

    func testOutputArrivesAndTheStatusIsReported() throws {
        let lines = Lines()
        let result = try ProcessRunner.stream(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "echo one; echo two 1>&2; exit 3"],
                                              timeout: 10, onLine: lines.add)
        XCTAssertEqual(result.status, 3)
        XCTAssertFalse(result.timedOut)
        XCTAssertEqual(Set(lines.all), ["one", "two"])
        XCTAssertEqual(Set(result.tail), ["one", "two"])
    }

    func testACommandThatRunsTooLongIsStopped() throws {
        let started = Date()
        let result = try ProcessRunner.stream(URL(fileURLWithPath: "/bin/sh"), arguments: ["-c", "echo started; exec sleep 60"],
                                              timeout: 0.5, onLine: { _ in })
        XCTAssertTrue(result.timedOut)
        XCTAssertTrue(result.tail.contains("started"))
        XCTAssertLessThan(Date().timeIntervalSince(started), 10)
    }

    func testACommandThatCannotStartThrows() {
        XCTAssertThrowsError(try ProcessRunner.stream(URL(fileURLWithPath: "/no/such/program"), arguments: [],
                                                      timeout: 1, onLine: { _ in }))
    }
}
