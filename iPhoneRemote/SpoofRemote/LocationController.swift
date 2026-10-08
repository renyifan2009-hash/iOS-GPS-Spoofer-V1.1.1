import CoreLocation
import MapKit
import Observation
import RemoteAPI
import SwiftUI

/// A place you can send the iPhone to.
struct Place: Codable, Identifiable, Hashable, Sendable {
    var id = UUID()
    var name: String
    var subtitle: String?
    var latitude: Double
    var longitude: Double

    var coordinate: CLLocationCoordinate2D {
        CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    var request: LocationRequest {
        LocationRequest(latitude: latitude, longitude: longitude, name: name)
    }

    var coordinateText: String {
        String(format: "%.5f, %.5f", latitude, longitude)
    }

    func isSameSpot(as other: Place) -> Bool {
        abs(latitude - other.latitude) < 1e-5 && abs(longitude - other.longitude) < 1e-5
    }
}

/// What's selected on the map, plus favorites and recents.
@MainActor
@Observable
final class LocationController {
    var selection: Place?
    var camera: MapCameraPosition = .automatic
    /// Show the blue dot: where iOS itself thinks the iPhone is (the
    /// simulated location, once the Mac is holding one).
    var showsReportedLocation = false
    private(set) var favorites: [Place] = []
    private(set) var recents: [Place] = []

    @ObservationIgnored private let geocoder = CLGeocoder()
    @ObservationIgnored private let locationManager = CLLocationManager()
    @ObservationIgnored private var geocodeTask: Task<Void, Never>?

    private static let favoritesKey = "favorites"
    private static let recentsKey = "recents"

    init() {
        favorites = Self.load(Self.favoritesKey)
        recents = Self.load(Self.recentsKey)
    }

    // MARK: - Selection

    /// A tap on the map: drop a pin, then name it from the address.
    func drop(at coordinate: CLLocationCoordinate2D) {
        let place = Place(name: "Dropped Pin", subtitle: nil, latitude: coordinate.latitude, longitude: coordinate.longitude)
        selection = place
        name(place)
    }

    /// A search result, favorite or recent.
    func select(_ place: Place, moveCamera: Bool = true) {
        selection = place
        if moveCamera { focus(on: place.coordinate) }
    }

    func focus(on coordinate: CLLocationCoordinate2D, meters: CLLocationDistance = 1200) {
        camera = .region(MKCoordinateRegion(center: coordinate, latitudinalMeters: meters, longitudinalMeters: meters))
    }

    private func name(_ place: Place) {
        geocodeTask?.cancel()
        let location = CLLocation(latitude: place.latitude, longitude: place.longitude)
        let geocoder = self.geocoder
        geocodeTask = Task { [weak self] in
            let found = await Self.reverseGeocode(location, with: geocoder)
            guard let self, !Task.isCancelled, let found, self.selection?.id == place.id else { return }
            withAnimation(Brand.snappy) {
                self.selection?.name = found.name
                self.selection?.subtitle = found.subtitle
            }
        }
    }

    private static func reverseGeocode(_ location: CLLocation, with geocoder: CLGeocoder) async -> (name: String, subtitle: String)? {
        geocoder.cancelGeocode()
        return await withCheckedContinuation { (continuation: CheckedContinuation<(name: String, subtitle: String)?, Never>) in
            geocoder.reverseGeocodeLocation(location) { placemarks, _ in
                guard let mark = placemarks?.first else {
                    continuation.resume(returning: nil)
                    return
                }
                let name = mark.name ?? mark.thoroughfare ?? mark.locality ?? "Dropped Pin"
                let parts = [mark.locality, mark.administrativeArea, mark.country].compactMap { $0 }
                    .filter { $0 != name }
                continuation.resume(returning: (name, parts.joined(separator: ", ")))
            }
        }
    }

    // MARK: - Favorites & recents

    func isFavorite(_ place: Place) -> Bool {
        favorites.contains { $0.isSameSpot(as: place) }
    }

    func toggleFavorite(_ place: Place) {
        if let index = favorites.firstIndex(where: { $0.isSameSpot(as: place) }) {
            favorites.remove(at: index)
        } else {
            favorites.insert(place, at: 0)
        }
        Self.save(favorites, Self.favoritesKey)
    }

    func removeFavorites(at offsets: IndexSet) {
        favorites.remove(atOffsets: offsets)
        Self.save(favorites, Self.favoritesKey)
    }

    func recordRecent(_ place: Place) {
        recents.removeAll { $0.isSameSpot(as: place) }
        recents.insert(place, at: 0)
        if recents.count > 20 { recents.removeLast(recents.count - 20) }
        Self.save(recents, Self.recentsKey)
    }

    func clearRecents() {
        recents.removeAll()
        Self.save(recents, Self.recentsKey)
    }

    // MARK: - Reported location

    func toggleReportedLocation() {
        if !showsReportedLocation, locationManager.authorizationStatus == .notDetermined {
            locationManager.requestWhenInUseAuthorization()
        }
        showsReportedLocation.toggle()
    }

    // MARK: - Storage

    private static func load(_ key: String) -> [Place] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let places = try? JSONDecoder().decode([Place].self, from: data) else { return [] }
        return places
    }

    private static func save(_ places: [Place], _ key: String) {
        if let data = try? JSONEncoder().encode(places) {
            UserDefaults.standard.set(data, forKey: key)
        }
    }
}
