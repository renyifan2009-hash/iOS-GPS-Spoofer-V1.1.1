import Foundation
import MapKit
import Observation
import SpooferCore

/// Autocompleting place search (MKLocalSearchCompleter), plus instant
/// recognition of typed/pasted coordinates and map links.
@MainActor
@Observable
final class PlaceSearch {
    struct Suggestion: Identifiable {
        let id = UUID()
        let title: String
        let subtitle: String
        let symbolName: String
        fileprivate let source: Source
    }

    fileprivate enum Source {
        case coordinate(GeoPoint)
        case completion(MKLocalSearchCompletion)
        case favorite(SavedPlace)
    }

    struct Place: Sendable {
        let name: String
        let point: GeoPoint
    }

    var query = "" { didSet { queryChanged() } }
    private(set) var suggestions: [Suggestion] = []
    private(set) var isResolving = false
    var highlighted: Int = 0

    @ObservationIgnored private let completer = MKLocalSearchCompleter()
    @ObservationIgnored private let bridge = CompleterBridge()
    @ObservationIgnored private var completions: [MKLocalSearchCompletion] = []

    init() {
        completer.resultTypes = [.address, .pointOfInterest]
        completer.delegate = bridge
        bridge.onUpdate = { [weak self] results in self?.completionsUpdated(results) }
    }

    /// Bias results towards what's on screen.
    func setRegion(center: GeoPoint, spanDegrees: Double) {
        completer.region = MKCoordinateRegion(
            center: CLLocationCoordinate2D(latitude: center.latitude, longitude: center.longitude),
            span: MKCoordinateSpan(latitudeDelta: spanDegrees, longitudeDelta: spanDegrees))
    }

    private func queryChanged() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        highlighted = 0
        if text.isEmpty {
            completions = []
            suggestions = []
            completer.cancel()
            return
        }
        completer.queryFragment = text
        rebuild()
    }

    private func completionsUpdated(_ results: [MKLocalSearchCompletion]) {
        completions = Array(results.prefix(8))
        rebuild()
    }

    private func rebuild() {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        var list: [Suggestion] = []
        if let point = Coordinate.parsePoint(text), point.isValid {
            list.append(Suggestion(title: Coordinate.format(point, precision: 6),
                                   subtitle: "Coordinate · \(Coordinate.formatDMS(point))",
                                   symbolName: "scope", source: .coordinate(point)))
        }
        let key = text.lowercased()
        for place in LibraryStore.shared.favorites where !key.isEmpty && place.name.lowercased().contains(key) {
            list.append(Suggestion(title: place.name, subtitle: "Favorite · \(Format.coordinate(place.point, precision: 4))",
                                   symbolName: "star.fill", source: .favorite(place)))
            if list.count >= 3 { break }
        }
        for c in completions {
            list.append(Suggestion(title: c.title, subtitle: c.subtitle,
                                   symbolName: c.subtitle.isEmpty ? "magnifyingglass" : "mappin.circle",
                                   source: .completion(c)))
        }
        suggestions = list
        if highlighted >= list.count { highlighted = max(0, list.count - 1) }
    }

    func moveHighlight(_ delta: Int) {
        guard !suggestions.isEmpty else { return }
        highlighted = (highlighted + delta + suggestions.count) % suggestions.count
    }

    func clear() {
        query = ""
    }

    /// Turn a suggestion into a concrete place (may hit the network).
    func resolve(_ suggestion: Suggestion) async -> Place? {
        switch suggestion.source {
        case .coordinate(let p):
            return Place(name: Coordinate.format(p, precision: 5), point: p)
        case .favorite(let place):
            return Place(name: place.name, point: place.point)
        case .completion(let completion):
            isResolving = true
            defer { isResolving = false }
            let request = MKLocalSearch.Request(completion: completion)
            let search = MKLocalSearch(request: request)
            let fallbackName = suggestion.title
            return await withCheckedContinuation { (continuation: CheckedContinuation<Place?, Never>) in
                search.start { response, _ in
                    guard let item = response?.mapItems.first else {
                        continuation.resume(returning: nil)
                        return
                    }
                    let c = item.placemark.coordinate
                    continuation.resume(returning: Place(name: item.name ?? fallbackName,
                                                         point: GeoPoint(c.latitude, c.longitude)))
                }
            }
        }
    }
}

/// Plain NSObject delegate, so the observable model doesn't have to be one.
/// MapKit calls it on the main thread; the protocol itself isn't annotated.
@MainActor
private final class CompleterBridge: NSObject, @preconcurrency MKLocalSearchCompleterDelegate {
    var onUpdate: (@MainActor ([MKLocalSearchCompletion]) -> Void)?

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        onUpdate?(completer.results)
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        onUpdate?([])
    }
}
