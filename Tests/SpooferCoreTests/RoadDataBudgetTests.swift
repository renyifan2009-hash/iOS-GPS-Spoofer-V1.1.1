import XCTest
@testable import SpooferCore

/// Loading road data for a long route on a bad network: give up in good time,
/// say what did load, and be easy on the public servers.
final class RoadDataBudgetTests: XCTestCase {
    private let a = GeoPoint(37, -122)

    /// A straight route of `km` kilometres: 15 km pieces, so `km / 15` rounded up of them.
    private func route(km: Int) -> RoutePath {
        RoutePath((0...km).map { a.moved(by: Double($0) * 1000, bearing: 0) })
    }

    // MARK: Giving up

    func testOfflineStopsAtTheFirstRequest() async {
        let calls = Counter()
        let loader = OverpassLoader(userAgent: "test", cacheDirectory: nil) { _ in
            _ = await calls.increment()
            throw URLError(.notConnectedToInternet)
        }
        do {
            _ = try await loader.features(along: route(km: 200), roads: true)
            XCTFail("with no network and nothing cached it should say so")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .notConnectedToInternet)
        }
        let asked = await calls.value
        XCTAssertEqual(asked, 1)        // not 3 servers for each of 14 pieces
    }

    func testAnUnreachableNetworkGivesUpAfterAFewPieces() async {
        let calls = Counter()
        let loader = OverpassLoader(userAgent: "test", cacheDirectory: nil) { _ in
            _ = await calls.increment()
            throw URLError(.cannotConnectToHost)
        }
        let start = Date()
        do {
            _ = try await loader.features(along: route(km: 200), roads: true)
            XCTFail("nothing loaded, so it should throw")
        } catch {
            XCTAssertEqual((error as? URLError)?.code, .cannotConnectToHost)
        }
        let asked = await calls.value
        XCTAssertEqual(asked, 9)        // 3 pieces, each tried on all 3 servers. Was 14 pieces.
        // No pause between servers when none of them could even be reached.
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.5)
    }

    func testWhatLoadedIsKeptWhenTheNetworkGoesAway() async throws {
        let calls = Counter()
        let loader = OverpassLoader(userAgent: "test", cacheDirectory: nil) { request in
            let n = await calls.increment()
            if n <= 1 { return answered(request) }
            throw URLError(.cannotConnectToHost)
        }
        let features = try await loader.features(along: route(km: 200), roads: false)
        XCTAssertFalse(features.complete)
        let asked = await calls.value
        XCTAssertEqual(asked, 1 + 9)    // the first piece, then 3 pieces that no server answered
    }

    func testPiecesAlreadyCachedStillLoadWhenOffline() async throws {
        let cache = FileManager.default.temporaryDirectory.appendingPathComponent("osm-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: cache) }
        let path = route(km: 40)
        let online = OverpassLoader(userAgent: "test", cacheDirectory: cache) { answered($0) }
        let first = try await online.features(along: path, roads: false)
        XCTAssertTrue(first.complete)

        // Lose the middle piece's cache file, then lose the network.
        let pieces = OverpassLoader.chunks(of: path)
        XCTAssertEqual(pieces.count, 3)
        let middle = OverpassLoader.query(for: pieces[1].points, padding: pieces[1].padding, roads: false)
        try FileManager.default.removeItem(at: cache.appendingPathComponent(OverpassLoader.cacheName(for: middle)))

        let calls = Counter()
        let offline = OverpassLoader(userAgent: "test", cacheDirectory: cache) { _ in
            _ = await calls.increment()
            throw URLError(.notConnectedToInternet)
        }
        let features = try await offline.features(along: path, roads: false)
        XCTAssertFalse(features.complete)       // the middle piece is missing
        let asked = await calls.value
        XCTAssertEqual(asked, 1)                // asked once, then answered the last piece from the cache
    }

    // MARK: The clock

    func testItStopsWhenItsTimeIsUp() async throws {
        let calls = Counter()
        let loader = OverpassLoader(userAgent: "test", cacheDirectory: nil, timeBudget: 0.5) { request in
            _ = await calls.increment()
            try await Task.sleep(for: .milliseconds(200))
            return answered(request)
        }
        let start = Date()
        let features = try await loader.features(along: route(km: 200), roads: false)
        XCTAssertFalse(features.complete)
        let asked = await calls.value
        XCTAssertGreaterThanOrEqual(asked, 2)
        XCTAssertLessThanOrEqual(asked, 4)      // not all 14 pieces
        XCTAssertLessThan(Date().timeIntervalSince(start), 2.0)
    }

    func testNoTimeAtAllIsAnErrorNotAnEmptyAnswer() async {
        let loader = OverpassLoader(userAgent: "test", cacheDirectory: nil, timeBudget: 0) { answered($0) }
        do {
            _ = try await loader.features(along: route(km: 20), roads: false)
            XCTFail("nothing was loaded")
        } catch {
            XCTAssertTrue("\(error)".contains("took too long"), "\(error)")
        }
    }

    func testARouteThatFitsTheTimeIsComplete() async throws {
        let loader = OverpassLoader(userAgent: "test", cacheDirectory: nil, timeBudget: 30) { answered($0) }
        let features = try await loader.features(along: route(km: 40), roads: false)
        XCTAssertTrue(features.complete)
    }

    // MARK: Which server first

    func testServersThatFailedAreTriedLast() async throws {
        let hosts = HostLog()
        let secondServerCalls = Counter()
        let loader = OverpassLoader(userAgent: "test", cacheDirectory: nil) { request in
            let host = request.url?.host ?? ""
            await hosts.add(host)
            switch host {
            case "overpass-api.de":                 // down
                throw URLError(.cannotConnectToHost)
            case "maps.mail.ru":                    // answers once, then goes down
                if await secondServerCalls.increment() == 1 { return answered(request) }
                throw URLError(.cannotConnectToHost)
            default:
                return answered(request)
            }
        }
        let features = try await loader.features(along: route(km: 40), roads: false)    // three pieces
        XCTAssertTrue(features.complete)
        let order = await hosts.all
        // Piece 1: the first server fails, the second answers.
        // Piece 2: the second server goes first and fails; the third answers. The first, which
        //          failed before, is not tried again ahead of it.
        // Piece 3: the third goes first.
        XCTAssertEqual(order, ["overpass-api.de", "maps.mail.ru",
                               "maps.mail.ru", "overpass.private.coffee",
                               "overpass.private.coffee"])
    }
}

/// An Overpass answer with nothing in it.
private func answered(_ request: URLRequest) -> (Data, URLResponse) {
    (Data(#"{"elements": []}"#.utf8), HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!)
}

actor HostLog {
    private(set) var all: [String] = []
    func add(_ host: String) { all.append(host) }
}
