import CoreLocation
import Observation
import PhoneOnlyCore
import RemoteAPI

/// The route being built on the map, before it's sent to the Mac to drive.
@MainActor
@Observable
final class RouteDraft {
    struct Stop: Identifiable, Hashable {
        let id = UUID()
        var latitude: Double
        var longitude: Double
        /// Seconds to wait here (0 = don't wait).
        var wait: Double = 0

        var coordinate: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
    }

    enum Repeat: String, CaseIterable, Identifiable {
        case once, loop, pingPong

        var id: String { rawValue }
        var label: String {
            switch self {
            case .once: return "Once"
            case .loop: return "Loop"
            case .pingPong: return "There & back"
            }
        }
    }

    var stops: [Stop] = []
    var driving = true
    var followRoads = true
    /// Top speed in km/h for the UI; converted to m/s for the request.
    var speedKmh: Double = 50
    var repeats: Repeat = .once
    var timeOfDayTraffic = false
    /// The name it was saved or loaded under, if any.
    var name: String?

    /// A route needs two or more points.
    var canDrive: Bool { stops.count >= 2 }

    var canAddStop: Bool { stops.count < SavedRoute.maxStops }

    // MARK: - Editing

    func add(_ coordinate: CLLocationCoordinate2D) {
        guard canAddStop, CLLocationCoordinate2DIsValid(coordinate) else { return }
        stops.append(Stop(latitude: coordinate.latitude, longitude: coordinate.longitude))
    }

    func removeLast() {
        if !stops.isEmpty { stops.removeLast() }
    }

    func remove(at offsets: IndexSet) {
        stops.remove(atOffsets: offsets)
    }

    func move(from source: IndexSet, to destination: Int) {
        stops.move(fromOffsets: source, toOffset: destination)
    }

    func reverse() {
        stops.reverse()
    }

    func setWait(_ seconds: Double, for id: Stop.ID) {
        guard let index = stops.firstIndex(where: { $0.id == id }) else { return }
        stops[index].wait = seconds.isFinite ? min(max(seconds, 0), Self.maxWait) : 0
    }

    func clear() {
        stops.removeAll()
        name = nil
    }

    /// The longest wait at one stop: four hours.
    static let maxWait: Double = 4 * 3600

    // MARK: - Summary

    /// The length as the crow flies, stop to stop (a loop adds the way back). Roads make it longer.
    var straightLineMeters: Double {
        guard stops.count >= 2 else { return 0 }
        var total = 0.0
        for (a, b) in zip(stops, stops.dropFirst()) {
            total += CLLocation(latitude: a.latitude, longitude: a.longitude)
                .distance(from: CLLocation(latitude: b.latitude, longitude: b.longitude))
        }
        if repeats == .loop, let first = stops.first, let last = stops.last {
            total += CLLocation(latitude: last.latitude, longitude: last.longitude)
                .distance(from: CLLocation(latitude: first.latitude, longitude: first.longitude))
        }
        return total
    }

    /// A rough time for one pass at the chosen speed, including the waits. The Mac's realistic trips take
    /// longer (lights, turns), so this is the least it could be.
    var roughSeconds: Double? {
        let speed = max(0.1, speedKmh / 3.6)
        guard straightLineMeters > 0 else { return nil }
        return straightLineMeters / speed + stops.reduce(0) { $0 + $1.wait }
    }

    // MARK: - Saved routes

    func apply(_ saved: SavedRoute) {
        stops = saved.stops.map { Stop(latitude: $0.latitude, longitude: $0.longitude, wait: $0.wait) }
        driving = saved.driving
        followRoads = saved.followRoads
        speedKmh = saved.speedKmh
        repeats = Repeat(rawValue: saved.repeats) ?? .once
        timeOfDayTraffic = saved.timeOfDayTraffic
        name = saved.name
    }

    func snapshot(named name: String) -> SavedRoute {
        SavedRoute(name: name,
                   stops: stops.map { .init(latitude: $0.latitude, longitude: $0.longitude, wait: $0.wait) },
                   driving: driving, followRoads: followRoads, speedKmh: speedKmh, repeats: repeats.rawValue,
                   timeOfDayTraffic: timeOfDayTraffic)
    }

    // MARK: - Sending

    func request(name: String? = nil) -> RouteRequest? {
        guard canDrive else { return nil }
        return RouteRequest(
            waypoints: stops.map { .init(latitude: $0.latitude, longitude: $0.longitude,
                                         wait: $0.wait > 0 ? $0.wait : nil) },
            followRoads: followRoads,
            travelMode: driving ? "driving" : "walking",
            loopMode: repeats.rawValue,
            speed: max(0.1, speedKmh / 3.6),
            realistic: true,
            timeOfDayTraffic: driving ? timeOfDayTraffic : false,
            name: name ?? self.name)
    }
}
