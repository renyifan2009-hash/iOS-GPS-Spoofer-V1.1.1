import XCTest
@testable import PhoneOnlyCore

final class SavedRouteTests: XCTestCase {
    private func route(name: String = "Commute", stops: [SavedRoute.Stop]? = nil, speed: Double = 50,
                       repeats: String = "once") -> SavedRoute {
        SavedRoute(name: name,
                   stops: stops ?? [.init(latitude: 37.3349, longitude: -122.0090),
                                    .init(latitude: 37.3318, longitude: -122.0312, wait: 120)],
                   driving: true, followRoads: true, speedKmh: speed, repeats: repeats, timeOfDayTraffic: false)
    }

    func testAGoodRouteIsUsable() {
        XCTAssertTrue(route().isUsable)
    }

    func testWhatIsNotUsable() {
        XCTAssertFalse(route(stops: [.init(latitude: 1, longitude: 2)]).isUsable, "one stop")
        XCTAssertFalse(route(stops: []).isUsable)
        XCTAssertFalse(route(stops: [.init(latitude: 1, longitude: 2), .init(latitude: 95, longitude: 2)]).isUsable)
        XCTAssertFalse(route(stops: [.init(latitude: 1, longitude: 2), .init(latitude: .nan, longitude: 2)]).isUsable)
        XCTAssertFalse(route(stops: [.init(latitude: 1, longitude: 2), .init(latitude: 3, longitude: 200)]).isUsable)
        XCTAssertFalse(route(stops: [.init(latitude: 1, longitude: 2), .init(latitude: 3, longitude: 4, wait: -1)]).isUsable)
        XCTAssertFalse(route(speed: 0).isUsable)
        XCTAssertFalse(route(speed: .infinity).isUsable)
        XCTAssertFalse(route(speed: 401).isUsable)
        XCTAssertFalse(route(repeats: "spiral").isUsable)
        let many = (0...SavedRoute.maxStops).map { SavedRoute.Stop(latitude: Double($0) * 0.001, longitude: 0) }
        XCTAssertFalse(route(stops: many).isUsable, "more stops than allowed")
    }

    func testNamesAreNeverEmptyOrHuge() {
        XCTAssertEqual(SavedRoute.cleanName("  Work  "), "Work")
        XCTAssertEqual(SavedRoute.cleanName(""), "Route")
        XCTAssertEqual(SavedRoute.cleanName("   \n"), "Route")
        XCTAssertEqual(SavedRoute.cleanName(String(repeating: "x", count: 500)).count, 60)
    }

    func testTheSameRouteMeansTheSameStopsInOrder() {
        let a = route()
        var b = route(name: "Other name", speed: 5, repeats: "loop")
        b.stops[1].wait = 0
        XCTAssertTrue(a.isSameRoute(as: b), "settings and waits don't make a different route")
        var c = route()
        c.stops[0].latitude += 0.01
        XCTAssertFalse(a.isSameRoute(as: c))
        XCTAssertFalse(a.isSameRoute(as: route(stops: Array(a.stops.reversed()))), "order matters")
        XCTAssertFalse(a.isSameRoute(as: route(stops: a.stops + [.init(latitude: 1, longitude: 1)])))
    }

    func testTheStraightLineLength() {
        // One degree of latitude is about 111.2 km.
        let r = route(stops: [.init(latitude: 10, longitude: 20), .init(latitude: 11, longitude: 20)])
        XCTAssertEqual(r.straightLineMeters, 111_195, accuracy: 300)
        let three = route(stops: [.init(latitude: 10, longitude: 20), .init(latitude: 11, longitude: 20), .init(latitude: 12, longitude: 20)])
        XCTAssertEqual(three.straightLineMeters, 222_390, accuracy: 600)
        XCTAssertEqual(route(stops: [.init(latitude: 5, longitude: 5), .init(latitude: 5, longitude: 5)]).straightLineMeters, 0)
    }

    func testAListRoundTrips() throws {
        let list = [route(name: "A"), route(name: "B", repeats: "loop")]
        let data = try XCTUnwrap(SavedRoute.encodeList(list))
        let back = SavedRoute.decodeList(data)
        XCTAssertEqual(back.map(\.name), ["A", "B"])
        XCTAssertEqual(back.first?.stops, list.first?.stops)
    }

    func testOneDamagedEntryLeavesOnlyItselfOut() throws {
        let good = try XCTUnwrap(SavedRoute.encodeList([route(name: "Keep me")]))
        let goodItem = String(decoding: good, as: UTF8.self).dropFirst().dropLast()   // the object inside [ ]
        let json = "[\(goodItem), 7, \"text\", null, {\"name\":\"no stops\"}, {\"id\":\"not-a-uuid\",\"name\":\"x\"}, \(goodItem)]"
        let loaded = SavedRoute.decodeList(Data(json.utf8))
        XCTAssertEqual(loaded.map(\.name), ["Keep me", "Keep me"])
    }

    func testAnEntryThatDecodesButIsNotUsableIsLeftOut() throws {
        var bad = route(name: "Bad")
        bad.stops[1].latitude = 123
        let data = try XCTUnwrap(SavedRoute.encodeList([route(name: "Good"), bad]))
        XCTAssertEqual(SavedRoute.decodeList(data).map(\.name), ["Good"])
    }

    func testNothingOrNonsenseIsAnEmptyList() {
        XCTAssertEqual(SavedRoute.decodeList(nil), [])
        XCTAssertEqual(SavedRoute.decodeList(Data()), [])
        XCTAssertEqual(SavedRoute.decodeList(Data("not json".utf8)), [])
        XCTAssertEqual(SavedRoute.decodeList(Data("{\"a\":1}".utf8)), [])
    }
}
