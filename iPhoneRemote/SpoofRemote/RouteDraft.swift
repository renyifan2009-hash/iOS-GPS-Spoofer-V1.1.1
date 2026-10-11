import CoreLocation
import Observation
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

    /// A route needs two or more points.
    var canDrive: Bool { stops.count >= 2 }

    func add(_ coordinate: CLLocationCoordinate2D) {
        stops.append(Stop(latitude: coordinate.latitude, longitude: coordinate.longitude))
    }

    func removeLast() {
        if !stops.isEmpty { stops.removeLast() }
    }

    func clear() {
        stops.removeAll()
    }

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
            name: name)
    }
}
