import Foundation
import RemoteAPI
import XCTest
@testable import SpooferRemote

final class HTTPParsingTests: XCTestCase {
    private func parse(_ text: String) -> HTTPRequest.ParseResult {
        HTTPRequest.parse(Data(text.utf8))
    }

    func testParsesGetWithoutBody() {
        guard case .complete(let request) = parse("GET /status?x=1 HTTP/1.1\r\nHost: mac\r\nAuthorization: Bearer abc\r\n\r\n") else {
            return XCTFail("expected a complete request")
        }
        XCTAssertEqual(request.method, "GET")
        XCTAssertEqual(request.path, "/status")
        XCTAssertEqual(request.headers["host"], "mac")
        XCTAssertEqual(request.bearerToken, "abc")
        XCTAssertTrue(request.body.isEmpty)
    }

    func testWaitsForTheWholeBody() {
        let head = "POST /start HTTP/1.1\r\nContent-Length: 10\r\n\r\n"
        XCTAssertEqual(parse(head + "12345"), .incomplete)
        guard case .complete(let request) = parse(head + "1234567890") else {
            return XCTFail("expected a complete request")
        }
        XCTAssertEqual(String(data: request.body, encoding: .utf8), "1234567890")
    }

    func testIncompleteHeaders() {
        XCTAssertEqual(parse("GET /status HTTP/1.1\r\nHost: m"), .incomplete)
    }

    func testRejectsMalformedAndUnsupported() {
        XCTAssertEqual(parse("NONSENSE\r\n\r\n"), .invalid(status: 400, message: "Malformed request line."))
        if case .invalid(let status, _) = parse("POST /start HTTP/1.1\r\nTransfer-Encoding: chunked\r\n\r\n") {
            XCTAssertEqual(status, 501)
        } else {
            XCTFail("chunked bodies should be refused")
        }
        if case .invalid(let status, _) = parse("POST /start HTTP/1.1\r\nContent-Length: 999999\r\n\r\n") {
            XCTAssertEqual(status, 413)
        } else {
            XCTFail("huge bodies should be refused")
        }
    }

    func testBearerTokenNeedsTheScheme() {
        let request = HTTPRequest(method: "GET", path: "/status", headers: ["authorization": "Basic abc"], body: Data())
        XCTAssertNil(request.bearerToken)
    }

    func testResponseSerialization() {
        let text = String(decoding: HTTPResponse.json(status: 401, APIError("nope")).serialized(), as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("HTTP/1.1 401 Unauthorized\r\n"))
        XCTAssertTrue(text.contains("Content-Length: 16\r\n"))
        XCTAssertTrue(text.hasSuffix("{\"error\":\"nope\"}"))
    }
}

final class LocalNetworkTests: XCTestCase {
    func testIPv4() {
        XCTAssertTrue(BonjourService.isLocal(ipv4: [192, 168, 1, 20]))
        XCTAssertTrue(BonjourService.isLocal(ipv4: [10, 0, 0, 2]))
        XCTAssertTrue(BonjourService.isLocal(ipv4: [172, 20, 10, 2]))   // Personal Hotspot
        XCTAssertTrue(BonjourService.isLocal(ipv4: [127, 0, 0, 1]))
        XCTAssertTrue(BonjourService.isLocal(ipv4: [169, 254, 3, 4]))
        XCTAssertFalse(BonjourService.isLocal(ipv4: [172, 32, 0, 1]))
        XCTAssertFalse(BonjourService.isLocal(ipv4: [8, 8, 8, 8]))
        XCTAssertFalse(BonjourService.isLocal(ipv4: [17, 253, 144, 10]))
    }

    func testIPv6() {
        var loopback = [UInt8](repeating: 0, count: 16)
        loopback[15] = 1
        XCTAssertTrue(BonjourService.isLocal(ipv6: loopback))
        XCTAssertTrue(BonjourService.isLocal(ipv6: [0xfe, 0x80] + [UInt8](repeating: 0, count: 13) + [7]))
        XCTAssertTrue(BonjourService.isLocal(ipv6: [0xfd, 0x12] + [UInt8](repeating: 0, count: 14)))
        let mapped = [UInt8](repeating: 0, count: 10) + [0xff, 0xff, 192, 168, 0, 9]
        XCTAssertTrue(BonjourService.isLocal(ipv6: mapped))
        XCTAssertFalse(BonjourService.isLocal(ipv6: [0x20, 0x01, 0x0d, 0xb8] + [UInt8](repeating: 0, count: 12)))
    }
}

final class PairingTests: XCTestCase {
    private var fileURL: URL!

    override func setUp() {
        super.setUp()
        fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("pairing-\(UUID().uuidString).json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: fileURL)
        super.tearDown()
    }

    func testRightCodeGivesAWorkingSingleUseToken() throws {
        let pairing = PairingManager(fileURL: fileURL)
        let code = pairing.currentCode
        XCTAssertEqual(code.count, 6)
        let token = try pairing.pair(code: code, clientName: "Test iPhone", clientID: "phone-1")
        XCTAssertEqual(pairing.authorize(token: token)?.name, "Test iPhone")
        XCTAssertNil(pairing.authorize(token: token + "x"))
        XCTAssertNotEqual(pairing.currentCode, code, "codes are single-use")
        XCTAssertThrowsError(try pairing.pair(code: code, clientName: "Other", clientID: "phone-2"))
    }

    func testCodeWithSpacesIsAccepted() throws {
        let pairing = PairingManager(fileURL: fileURL)
        let spaced = pairing.formattedCode
        XCTAssertTrue(spaced.contains(" "))
        XCTAssertNoThrow(try pairing.pair(code: spaced, clientName: "Phone", clientID: "p"))
    }

    func testLockoutAfterRepeatedWrongCodes() {
        let pairing = PairingManager(fileURL: fileURL)
        let wrong = pairing.currentCode == "000000" ? "111111" : "000000"
        let now = Date()
        for attempt in 1...PairingManager.maxAttempts {
            XCTAssertThrowsError(try pairing.pair(code: wrong, clientName: "x", clientID: "x", now: now)) { error in
                XCTAssertEqual(error as? PairingManager.PairingError,
                               .wrongCode(attemptsLeft: PairingManager.maxAttempts - attempt))
            }
        }
        let code = pairing.currentCode
        XCTAssertThrowsError(try pairing.pair(code: code, clientName: "x", clientID: "x", now: now)) { error in
            guard case .lockedOut = error as? PairingManager.PairingError else {
                return XCTFail("expected a lockout, got \(error)")
            }
        }
        // After the window the right code works again.
        XCTAssertNoThrow(try pairing.pair(code: code, clientName: "x", clientID: "x",
                                          now: now.addingTimeInterval(PairingManager.lockoutWindow + 1)))
    }

    func testRepairingReplacesTheOldTokenAndPersists() throws {
        let pairing = PairingManager(fileURL: fileURL)
        let first = try pairing.pair(code: pairing.currentCode, clientName: "Phone", clientID: "same")
        let second = try pairing.pair(code: pairing.currentCode, clientName: "Phone", clientID: "same")
        XCTAssertNil(pairing.authorize(token: first))
        XCTAssertEqual(pairing.pairedClients.count, 1)

        let reloaded = PairingManager(fileURL: fileURL)
        XCTAssertEqual(reloaded.serverID, pairing.serverID)
        XCTAssertNotNil(reloaded.authorize(token: second))
        reloaded.revoke(token: second)
        XCTAssertNil(reloaded.authorize(token: second))
    }

    func testOnlyHashesAreStored() throws {
        let pairing = PairingManager(fileURL: fileURL)
        let token = try pairing.pair(code: pairing.currentCode, clientName: "Phone", clientID: "p")
        let file = try String(contentsOf: fileURL, encoding: .utf8)
        XCTAssertFalse(file.contains(token))
        XCTAssertTrue(file.contains(PairingManager.hash(token)))
    }
}

/// Records what the server asked for.
private final class FakeController: RemoteController, @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [String] = []
    var recorded: [String] { lock.lock(); defer { lock.unlock() }; return calls }

    private func record(_ call: String) {
        lock.lock(); calls.append(call); lock.unlock()
    }

    private func status(spoofing: Bool, _ location: LocationRequest? = nil) -> RemoteStatus {
        RemoteStatus(connected: true, spoofing: spoofing, latitude: location?.latitude, longitude: location?.longitude,
                     placeName: location?.name, phase: spoofing ? .active : .idle, serverName: "Test Mac")
    }

    func status() async -> RemoteStatus { record("status"); return status(spoofing: false) }
    func setLocation(_ request: LocationRequest) async throws -> RemoteStatus {
        record("location \(request.latitude),\(request.longitude)")
        return status(spoofing: true, request)
    }
    func start(_ request: LocationRequest?) async throws -> RemoteStatus {
        guard let request else { throw RemoteControlError("Pick a location first.", status: 400) }
        record("start \(request.latitude),\(request.longitude)")
        return status(spoofing: true, request)
    }
    func stop() async -> RemoteStatus { record("stop"); return status(spoofing: false) }
    func driveRoute(_ request: RouteRequest) async throws -> RemoteStatus {
        record("route \(request.waypoints.count)pts \(request.travelMode) \(request.loopMode)")
        let first = request.waypoints[0]
        return status(spoofing: true, LocationRequest(latitude: first.latitude, longitude: first.longitude,
                                                      name: request.name))
    }
}

final class RoutingTests: XCTestCase {
    private var fileURL: URL!
    private var pairing: PairingManager!
    private var controller: FakeController!
    private var server: MacRemoteServer!

    override func setUp() {
        super.setUp()
        fileURL = FileManager.default.temporaryDirectory.appendingPathComponent("routing-\(UUID().uuidString).json")
        pairing = PairingManager(fileURL: fileURL)
        controller = FakeController()
        server = MacRemoteServer(name: "Test Mac", port: 0, controller: controller, pairing: pairing)
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

    private func decode<T: Decodable>(_ type: T.Type, _ response: HTTPResponse) throws -> T {
        try RemoteAPI.makeDecoder().decode(type, from: response.body)
    }

    private func pairedToken() async throws -> String {
        let body = String(decoding: try RemoteAPI.makeEncoder().encode(
            PairRequest(code: pairing.currentCode, clientName: "Phone", clientID: "phone")), as: UTF8.self)
        let response = await server.handle(request("POST", RemoteAPI.Path.pair, body: body))
        XCTAssertEqual(response.status, 200)
        let paired = try decode(PairResponse.self, response)
        XCTAssertEqual(paired.server.serverID, pairing.serverID)
        return paired.token
    }

    func testInfoNeedsNoToken() async throws {
        let response = await server.handle(request("GET", RemoteAPI.Path.info))
        XCTAssertEqual(response.status, 200)
        XCTAssertEqual(try decode(ServerInfo.self, response).name, "Test Mac")
    }

    func testCommandsNeedAToken() async {
        let response = await server.handle(request("GET", RemoteAPI.Path.status))
        XCTAssertEqual(response.status, 401)
        let wrong = await server.handle(request("POST", RemoteAPI.Path.stop, token: "not-a-token"))
        XCTAssertEqual(wrong.status, 401)
        XCTAssertTrue(controller.recorded.isEmpty)
    }

    func testWrongPairingCode() async throws {
        let wrong = pairing.currentCode == "123456" ? "654321" : "123456"
        let body = String(decoding: try RemoteAPI.makeEncoder().encode(
            PairRequest(code: wrong, clientName: "Phone", clientID: "phone")), as: UTF8.self)
        let response = await server.handle(request("POST", RemoteAPI.Path.pair, body: body))
        XCTAssertEqual(response.status, 403)
    }

    func testStartMoveStop() async throws {
        let token = try await pairedToken()

        let started = await server.handle(request("POST", RemoteAPI.Path.start, token: token,
                                                  body: #"{"latitude":37.3349,"longitude":-122.009,"name":"Apple Park"}"#))
        XCTAssertEqual(started.status, 200)
        let status = try decode(RemoteStatus.self, started)
        XCTAssertTrue(status.spoofing)
        XCTAssertEqual(status.placeName, "Apple Park")

        let moved = await server.handle(request("POST", RemoteAPI.Path.location, token: token,
                                                body: #"{"latitude":48.8584,"longitude":2.2945}"#))
        XCTAssertEqual(moved.status, 200)

        let stopped = await server.handle(request("POST", RemoteAPI.Path.stop, token: token))
        XCTAssertEqual(stopped.status, 200)
        XCTAssertEqual(controller.recorded, ["start 37.3349,-122.009", "location 48.8584,2.2945", "stop"])
    }

    func testDriveRoute() async throws {
        let token = try await pairedToken()
        let body = #"{"waypoints":[{"latitude":37.3349,"longitude":-122.009},{"latitude":37.3318,"longitude":-122.0312,"wait":120}],"followRoads":true,"travelMode":"driving","loopMode":"once","speed":16,"realistic":true,"name":"Commute"}"#
        let response = await server.handle(request("POST", RemoteAPI.Path.route, token: token, body: body))
        XCTAssertEqual(response.status, 200)
        let status = try decode(RemoteStatus.self, response)
        XCTAssertTrue(status.spoofing)
        XCTAssertEqual(status.placeName, "Commute")
        XCTAssertEqual(controller.recorded, ["route 2pts driving once"])
    }

    func testRouteNeedsAToken() async {
        let body = #"{"waypoints":[{"latitude":1,"longitude":2},{"latitude":3,"longitude":4}],"speed":5}"#
        let response = await server.handle(request("POST", RemoteAPI.Path.route, body: body))
        XCTAssertEqual(response.status, 401)
        XCTAssertTrue(controller.recorded.isEmpty)
    }

    func testRouteRejectsBadBody() async throws {
        let token = try await pairedToken()
        let response = await server.handle(request("POST", RemoteAPI.Path.route, token: token,
                                                   body: #"{"waypoints":[{"latitude":1,"longitude":2}],"speed":5}"#))
        XCTAssertEqual(response.status, 400)
    }

    func testBadInput() async throws {
        let token = try await pairedToken()
        let outOfRange = await server.handle(request("POST", RemoteAPI.Path.location, token: token,
                                                     body: #"{"latitude":91,"longitude":0}"#))
        XCTAssertEqual(outOfRange.status, 400)
        let missing = await server.handle(request("POST", RemoteAPI.Path.location, token: token))
        XCTAssertEqual(missing.status, 400)
        let noTarget = await server.handle(request("POST", RemoteAPI.Path.start, token: token))
        XCTAssertEqual(noTarget.status, 400)
        let unknown = await server.handle(request("GET", "/nope", token: token))
        XCTAssertEqual(unknown.status, 404)
        let wrongMethod = await server.handle(request("GET", RemoteAPI.Path.stop, token: token))
        XCTAssertEqual(wrongMethod.status, 405)
    }

    func testUnpairRevokesTheToken() async throws {
        let token = try await pairedToken()
        let response = await server.handle(request("POST", RemoteAPI.Path.unpair, token: token))
        XCTAssertEqual(response.status, 200)
        let after = await server.handle(request("GET", RemoteAPI.Path.status, token: token))
        XCTAssertEqual(after.status, 401)
    }
}

final class RemoteAPITests: XCTestCase {
    func testStatusRoundTrip() throws {
        let status = RemoteStatus(connected: true, spoofing: true, latitude: 37.3349, longitude: -122.009,
                                  placeName: "Apple Park", phase: .active,
                                  device: DeviceSummary(name: "Test iPhone", model: "iPhone 15 Pro", iosVersion: "18.1", connection: "usb"),
                                  engine: "Live", serverName: "Test Mac")
        let data = try RemoteAPI.makeEncoder().encode(status)
        XCTAssertEqual(try RemoteAPI.makeDecoder().decode(RemoteStatus.self, from: data), status)
        let json = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(json.contains("\"connected\":true"))
        XCTAssertTrue(json.contains("\"spoofing\":true"))
        XCTAssertTrue(json.contains("\"latitude\":37.3349"))
    }

    func testLocationValidation() {
        XCTAssertTrue(LocationRequest(latitude: 37.3349, longitude: -122.009).isValid)
        XCTAssertFalse(LocationRequest(latitude: 90.1, longitude: 0).isValid)
        XCTAssertFalse(LocationRequest(latitude: 0, longitude: -180.5).isValid)
        XCTAssertFalse(LocationRequest(latitude: .nan, longitude: 0).isValid)
    }
}
