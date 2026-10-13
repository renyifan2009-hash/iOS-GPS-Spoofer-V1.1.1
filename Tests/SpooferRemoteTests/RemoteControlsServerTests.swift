import Foundation
import RemoteAPI
import XCTest
@testable import SpooferRemote

/// Does all of the new calls and records them.
private final class ControlsFake: RemoteController, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [String] = []
    var recorded: [String] { lock.lock(); defer { lock.unlock() }; return calls }
    private func record(_ call: String) { lock.lock(); calls.append(call); lock.unlock() }

    private func makeStatus() -> RemoteStatus {
        RemoteStatus(connected: true, spoofing: true, phase: .active, serverName: "Test Mac", activity: "joystick")
    }

    func status() async -> RemoteStatus { makeStatus() }
    func setLocation(_ request: LocationRequest) async throws -> RemoteStatus { makeStatus() }
    func start(_ request: LocationRequest?) async throws -> RemoteStatus { makeStatus() }
    func stop() async -> RemoteStatus { record("stop"); return makeStatus() }
    func joystick(_ request: JoystickRequest) async throws -> RemoteStatus {
        record("joystick \(request.heading) \(request.speed)")
        return makeStatus()
    }
    func setPaused(_ request: PauseRequest) async throws -> RemoteStatus {
        record("paused \(request.paused)")
        return makeStatus()
    }
    func setAutoStop(_ request: AutoStopRequest) async throws -> RemoteStatus {
        record("autostop \(request.minutes)")
        return makeStatus()
    }
}

/// A controller that only does what every controller must: the new calls fall back to 501.
private final class BareController: RemoteController, @unchecked Sendable {
    private func makeStatus() -> RemoteStatus { RemoteStatus(connected: true, spoofing: false, phase: .idle, serverName: "Bare") }
    func status() async -> RemoteStatus { makeStatus() }
    func setLocation(_ request: LocationRequest) async throws -> RemoteStatus { makeStatus() }
    func start(_ request: LocationRequest?) async throws -> RemoteStatus { makeStatus() }
    func stop() async -> RemoteStatus { makeStatus() }
}

final class RemoteControlsServerTests: XCTestCase {
    private var fileURL: URL!
    private var pairing: PairingManager!

    override func setUp() {
        super.setUp()
        fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("controls-\(UUID().uuidString).json")
        pairing = PairingManager(fileURL: fileURL)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: fileURL)
        super.tearDown()
    }

    private func request(_ method: String, _ path: String, token: String? = nil, body: String = "") -> HTTPRequest {
        var headers = ["content-length": String(body.utf8.count)]
        if let token { headers["authorization"] = "Bearer \(token)" }
        return HTTPRequest(method: method, path: path, headers: headers, body: Data(body.utf8))
    }

    private func token(for server: MacRemoteServer) async throws -> String {
        let body = String(decoding: try RemoteAPI.makeEncoder().encode(
            PairRequest(code: pairing.currentCode, clientName: "Phone", clientID: "phone")), as: UTF8.self)
        let response = await server.handle(request("POST", RemoteAPI.Path.pair, body: body))
        XCTAssertEqual(response.status, 200)
        return try RemoteAPI.makeDecoder().decode(PairResponse.self, from: response.body).token
    }

    private func make(_ controller: RemoteController) -> MacRemoteServer {
        MacRemoteServer(name: "Test Mac", port: 0, controller: controller, pairing: pairing)
    }

    // MARK: - Joystick

    func testTheJoystickNeedsAToken() async {
        let fake = ControlsFake()
        let response = await make(fake).handle(request("POST", RemoteAPI.Path.joystick, body: #"{"heading":90,"speed":3}"#))
        XCTAssertEqual(response.status, 401)
        XCTAssertTrue(fake.recorded.isEmpty)
    }

    func testAValidJoystickRequestReachesTheController() async throws {
        let fake = ControlsFake()
        let server = make(fake)
        let response = await server.handle(request("POST", RemoteAPI.Path.joystick, token: try await token(for: server),
                                                   body: #"{"heading":90,"speed":3.5}"#))
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(try RemoteAPI.makeDecoder().decode(RemoteStatus.self, from: response.body).activity, "joystick")
        XCTAssertEqual(fake.recorded, ["joystick 90.0 3.5"])
    }

    func testBadJoystickRequestsAreRefusedBeforeTheController() async throws {
        let fake = ControlsFake()
        let server = make(fake)
        let token = try await token(for: server)
        for body in [#"{"heading":360,"speed":1}"#, #"{"heading":-5,"speed":1}"#, #"{"heading":10,"speed":71}"#,
                     #"{"heading":10,"speed":-1}"#, #"{"heading":"north","speed":1}"#, "", "not json", "{}"] {
            let response = await server.handle(request("POST", RemoteAPI.Path.joystick, token: token, body: body))
            XCTAssertEqual(response.status, 400, "body: \(body)")
        }
        XCTAssertTrue(fake.recorded.isEmpty)
    }

    func testSteeringDoesNotShowAMessageOnTheMacEachTime() async throws {
        // It arrives several times a second: only real commands (pause, stop, ...) are announced.
        let fake = ControlsFake()
        let server = make(fake)
        let announced = Counter()
        server.onCommand = { _, _ in announced.increment() }
        let token = try await token(for: server)
        for _ in 0..<5 {
            _ = await server.handle(request("POST", RemoteAPI.Path.joystick, token: token, body: #"{"heading":0,"speed":1}"#))
        }
        XCTAssertEqual(announced.value, 0)
        _ = await server.handle(request("POST", RemoteAPI.Path.pause, token: token, body: #"{"paused":true}"#))
        XCTAssertEqual(announced.value, 1)
    }

    // MARK: - Pause and Auto-stop

    func testPauseAndResume() async throws {
        let fake = ControlsFake()
        let server = make(fake)
        let token = try await token(for: server)
        let paused = await server.handle(request("POST", RemoteAPI.Path.pause, token: token, body: #"{"paused":true}"#))
        let resumed = await server.handle(request("POST", RemoteAPI.Path.pause, token: token, body: #"{"paused":false}"#))
        XCTAssertEqual([paused.status, resumed.status], [200, 200])
        XCTAssertEqual(fake.recorded, ["paused true", "paused false"])
        let bad = await server.handle(request("POST", RemoteAPI.Path.pause, token: token, body: "nope"))
        XCTAssertEqual(bad.status, 400)
    }

    func testAutoStopMinutesAreChecked() async throws {
        let fake = ControlsFake()
        let server = make(fake)
        let token = try await token(for: server)
        let ok = await server.handle(request("POST", RemoteAPI.Path.autoStop, token: token, body: #"{"minutes":30}"#))
        let off = await server.handle(request("POST", RemoteAPI.Path.autoStop, token: token, body: #"{"minutes":0}"#))
        XCTAssertEqual([ok.status, off.status], [200, 200])
        for body in [#"{"minutes":-1}"#, #"{"minutes":1441}"#, #"{"minutes":"soon"}"#, ""] {
            let response = await server.handle(request("POST", RemoteAPI.Path.autoStop, token: token, body: body))
            XCTAssertEqual(response.status, 400, "body: \(body)")
        }
        XCTAssertEqual(fake.recorded, ["autostop 30", "autostop 0"])
    }

    // MARK: - Controllers that can't

    func testAControllerThatCannotAnswers501ForEachNewCall() async throws {
        let server = make(BareController())
        let token = try await token(for: server)
        let calls: [(String, String)] = [
            (RemoteAPI.Path.joystick, #"{"heading":0,"speed":1}"#),
            (RemoteAPI.Path.pause, #"{"paused":true}"#),
            (RemoteAPI.Path.autoStop, #"{"minutes":15}"#),
            (RemoteAPI.Path.route, #"{"waypoints":[{"latitude":1,"longitude":2},{"latitude":3,"longitude":4}],"speed":5}"#),
        ]
        for (path, body) in calls {
            let response = await server.handle(request("POST", path, token: token, body: body))
            XCTAssertEqual(response.status, 501, path)
        }
    }

    func testTheNewPathsAreKnownSoTheyAreNot404() async throws {
        let server = make(ControlsFake())
        for path in [RemoteAPI.Path.joystick, RemoteAPI.Path.pause, RemoteAPI.Path.autoStop] {
            let response = await server.handle(request("GET", path, token: try await token(for: server)))
            XCTAssertEqual(response.status, 405, "\(path) exists but only takes POST")
        }
    }
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
    func increment() { lock.lock(); count += 1; lock.unlock() }
}
