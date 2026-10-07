import Foundation
import MapKit
import SpooferCore

/// Road-following geometry between waypoints, via Apple Maps directions.
/// Legs are cached, so editing one waypoint only re-requests its two legs.
@MainActor
final class DirectionsService {
    static let shared = DirectionsService()

    struct Result: Sendable {
        let points: [GeoPoint]
        let failedLegs: Int
    }

    private var cache: [String: [GeoPoint]] = [:]

    private init() {}

    func route(through waypoints: [GeoPoint], mode: TravelMode) async -> Result {
        guard waypoints.count >= 2 else { return Result(points: waypoints, failedLegs: 0) }
        var points: [GeoPoint] = []
        var failed = 0
        for (a, b) in zip(waypoints, waypoints.dropFirst()) {
            if Task.isCancelled { break }
            var leg: [GeoPoint]
            let key = Self.key(a, b, mode)
            if let cached = cache[key] {
                leg = cached
            } else if let fetched = await Self.fetchLeg(from: a, to: b, mode: mode), fetched.count >= 2 {
                leg = fetched
                cache[key] = fetched
                if cache.count > 500 { cache.removeAll() }
            } else {
                leg = [a, b]
                failed += 1
            }
            // Pin the leg to the exact waypoints so the drawn route meets the pins.
            leg[0] = a
            leg[leg.count - 1] = b
            if !points.isEmpty { leg.removeFirst() }
            points += leg
        }
        return Result(points: points, failedLegs: failed)
    }

    private static func key(_ a: GeoPoint, _ b: GeoPoint, _ mode: TravelMode) -> String {
        String(format: "%.6f,%.6f>%.6f,%.6f|", a.latitude, a.longitude, b.latitude, b.longitude) + mode.rawValue
    }

    private static func fetchLeg(from a: GeoPoint, to b: GeoPoint, mode: TravelMode) async -> [GeoPoint]? {
        let request = MKDirections.Request()
        request.source = MKMapItem(placemark: MKPlacemark(
            coordinate: CLLocationCoordinate2D(latitude: a.latitude, longitude: a.longitude)))
        request.destination = MKMapItem(placemark: MKPlacemark(
            coordinate: CLLocationCoordinate2D(latitude: b.latitude, longitude: b.longitude)))
        request.transportType = mode == .walking ? .walking : .automobile
        request.requestsAlternateRoutes = false
        let directions = MKDirections(request: request)
        return await withCheckedContinuation { (continuation: CheckedContinuation<[GeoPoint]?, Never>) in
            directions.calculate { response, _ in
                guard let polyline = response?.routes.first?.polyline, polyline.pointCount >= 2 else {
                    continuation.resume(returning: nil)
                    return
                }
                var coords = [CLLocationCoordinate2D](repeating: CLLocationCoordinate2D(), count: polyline.pointCount)
                polyline.getCoordinates(&coords, range: NSRange(location: 0, length: polyline.pointCount))
                continuation.resume(returning: coords.map { GeoPoint($0.latitude, $0.longitude) })
            }
        }
    }
}
