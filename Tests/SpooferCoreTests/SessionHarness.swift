import Foundation
import XCTest
@testable import SpooferCore

/// A `SpoofSession` against a pretend iPhone: the fake `pymobiledevice3` for the
/// device list and for classic holds, and the fake live helper for the live
/// engine. Nothing talks to a real device, and nothing is written outside a
/// temporary folder (the helper script comes from the fixtures, not from the
/// app's support folder).
final class SessionHarness: @unchecked Sendable {
    static let fixtures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("Fixtures")

    let directory: URL
    let session: SpoofSession
    let pmd: Pymobiledevice3
    private let queue = DispatchQueue(label: "SessionHarness.callbacks")
    private let lock = NSLock()
    private var recordedStates: [SessionState] = []
    private var recordedLogs: [(LogLevel, String)] = []
    private var changedEnvironment: [String] = []

    /// What the pretend `pymobiledevice3` was asked, one command per line.
    var pmdLog: URL { directory.appendingPathComponent("pmd.log") }
    /// What the pretend live helper saw, one event per line.
    var helperLog: URL { directory.appendingPathComponent("helper.log") }

    /// Fast timings so a test that waits for a timeout takes a moment, not a minute.
    static let fastTiming: SpoofSession.Timing = {
        var timing = SpoofSession.Timing()
        timing.tick = 0.05
        timing.idleHeartbeat = 0.25
        timing.answerTimeout = 0.6
        timing.sleepGap = 5
        timing.retryDelays = [0.05, 0.05, 0.05]
        timing.listRetry = 0.05
        timing.listFailureLimit = 3
        return timing
    }()

    /// - Parameters:
    ///   - iOS: the version the session believes the iPhone runs.
    ///   - helperModes: `FAKE_HELPER_MODES`, how each launch of the live helper behaves.
    init(engine: EngineKind, iOS: String = "18.0", helperModes: String = "ok", timing: SpoofSession.Timing = fastTiming,
         environment: [String: String] = [:]) throws {
        try XCTSkipIf(which("python3") == nil, "needs python3 to run the pretend pymobiledevice3")
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("session-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        pmd = Pymobiledevice3(executableURL: Self.fixtures.appendingPathComponent("fake-pymobiledevice3"))
        let device = Device(deviceName: "Demo iPhone", identifier: "00008110-000DEMO0000DEMO", connectionType: "USB",
                            productType: "iPhone15,3", productVersion: iOS)
        let helper = Self.fixtures.appendingPathComponent("fake-live-helper.py")
        var options = SpoofSession.Options()
        options.timing = timing
        options.helperScript = { helper }
        let python = URL(fileURLWithPath: which("python3")!)
        session = SpoofSession(pmd: pmd, device: device, transport: .automatic, engine: engine,
                               python: engine == .live ? python : nil, callbackQueue: queue, options: options)

        set("PYTHONDONTWRITEBYTECODE", "1")
        set("FAKE_PMD_LOG", pmdLog.path)
        set("FAKE_PMD_IOS", iOS)
        set("FAKE_HELPER_LOG", helperLog.path)
        set("FAKE_HELPER_MODES", helperModes)
        for (name, value) in environment { set(name, value) }

        session.onStateChange = { [self] state in
            lock.lock(); recordedStates.append(state); lock.unlock()
        }
        session.onLog = { [self] level, line in
            lock.lock(); recordedLogs.append((level, line)); lock.unlock()
        }
    }

    private func set(_ name: String, _ value: String) {
        setenv(name, value, 1)
        changedEnvironment.append(name)
    }

    /// Stops the session and cleans up. Call from `tearDown`.
    func finish() {
        session.stopBlocking()
        for name in changedEnvironment { unsetenv(name) }
        changedEnvironment = []
        try? FileManager.default.removeItem(at: directory)
    }

    // MARK: - What happened

    var states: [SessionState] {
        lock.lock(); defer { lock.unlock() }
        return recordedStates
    }

    var logs: [(level: LogLevel, line: String)] {
        lock.lock(); defer { lock.unlock() }
        return recordedLogs.map { (level: $0.0, line: $0.1) }
    }

    func logged(_ text: String, level: LogLevel? = nil) -> Bool {
        logs.contains { $0.line.contains(text) && (level == nil || $0.level == level) }
    }

    /// The lines of a log file written by the pretend programs.
    func lines(of file: URL) -> [String] {
        ((try? String(contentsOf: file, encoding: .utf8)) ?? "").split(separator: "\n").map(String.init)
    }

    var helperLaunches: Int { lines(of: helperLog).filter { $0.hasPrefix("start ") }.count }
    var helperSets: Int { lines(of: helperLog).filter { $0.hasPrefix("set ") }.count }

    /// Poll until `condition` holds. False if it didn't within `timeout`.
    @discardableResult
    func wait(_ timeout: TimeInterval = 10, _ condition: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if condition() { return true }
            Thread.sleep(forTimeInterval: 0.02)
        }
        return condition()
    }

    func waitForState(_ timeout: TimeInterval = 10, _ matches: (SessionState) -> Bool) -> Bool {
        wait(timeout) { matches(session.state) }
    }
}

extension SessionState {
    var isFailed: Bool {
        if case .failed = self { return true }
        return false
    }

    var failureMessage: String? {
        if case let .failed(message) = self { return message }
        return nil
    }
}
