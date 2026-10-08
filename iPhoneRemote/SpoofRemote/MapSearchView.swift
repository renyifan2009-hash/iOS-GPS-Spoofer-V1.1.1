import MapKit
import Observation
import SwiftUI

/// Search sheet: autocomplete as you type (MKLocalSearchCompleter), a full
/// MKLocalSearch on Return ("Apple Park", an address, "coffee"), typed
/// coordinates, plus favorites and recents when the field is empty.
struct MapSearchView: View {
    @Environment(LocationController.self) private var locations
    @Environment(\.dismiss) private var dismiss
    @State private var search = PlaceSearch()
    @State private var searchPresented = true

    var body: some View {
        @Bindable var search = search
        NavigationStack {
            List {
                if search.query.isEmpty {
                    savedSections
                } else {
                    resultSections
                }
            }
            .listStyle(.insetGrouped)
            .scrollContentBackground(.hidden)
            .animation(Brand.snappy, value: search.query.isEmpty)
            .animation(Brand.snappy, value: search.results)
            .navigationTitle("Search")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search.query, isPresented: $searchPresented,
                        placement: .navigationBarDrawer(displayMode: .always),
                        prompt: "Place, address or coordinates")
            .onSubmit(of: .search) { Task { await search.runFullSearch() } }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .overlay {
                if search.isSearching {
                    ProgressView().controlSize(.large)
                        .padding(22)
                        .glassSurface(cornerRadius: 22)
                        .transition(.scale.combined(with: .opacity))
                }
            }
        }
        .onAppear {
            if let center = locations.selection?.coordinate { search.bias(to: center) }
        }
    }

    // MARK: Sections

    @ViewBuilder
    private var savedSections: some View {
        if locations.favorites.isEmpty && locations.recents.isEmpty {
            Section {
                VStack(spacing: 12) {
                    IconTile(symbol: "magnifyingglass", size: 52)
                    Text("Search anywhere")
                        .font(Brand.rounded(.title3))
                    Text("Try “Apple Park”, a street address, or coordinates like 48.8584, 2.2945. Places you star show up here.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 26)
                .listRowBackground(Color.clear)
            }
        }
        if !locations.favorites.isEmpty {
            Section("Favorites") {
                ForEach(locations.favorites) { place in
                    row(place, symbol: "star.fill", colors: [Color.yellow, Color.orange])
                }
                .onDelete { locations.removeFavorites(at: $0) }
            }
        }
        if !locations.recents.isEmpty {
            Section {
                ForEach(locations.recents) { place in
                    row(place, symbol: "clock.fill", colors: [Color.gray, Color(white: 0.45)])
                }
            } header: {
                HStack {
                    Text("Recent")
                    Spacer()
                    Button("Clear") { withAnimation(Brand.snappy) { locations.clearRecents() } }
                        .font(.caption.weight(.semibold))
                        .textCase(nil)
                }
            }
        }
    }

    @ViewBuilder
    private var resultSections: some View {
        if let coordinate = search.typedCoordinate {
            Section {
                Button {
                    choose(Place(name: "Dropped Pin", subtitle: nil, latitude: coordinate.latitude, longitude: coordinate.longitude))
                } label: {
                    PlaceRowLabel(title: String(format: "%.5f, %.5f", coordinate.latitude, coordinate.longitude),
                                  subtitle: "Go to these coordinates", symbol: "scope", colors: [Brand.violet, Brand.indigo])
                }
            }
        }
        if !search.results.isEmpty {
            Section("Results") {
                ForEach(search.results) { result in
                    Button { choose(result) } label: {
                        PlaceRowLabel(title: result.name, subtitle: result.subtitle, symbol: "mappin.circle.fill",
                                      colors: [Color(red: 0.99, green: 0.42, blue: 0.42), Color(red: 0.86, green: 0.15, blue: 0.27)])
                    }
                }
            }
        }
        if !search.suggestions.isEmpty {
            Section("Suggestions") {
                ForEach(search.suggestions) { suggestion in
                    Button {
                        Task {
                            if let place = await search.resolve(suggestion) { choose(place) }
                        }
                    } label: {
                        PlaceRowLabel(title: suggestion.title, subtitle: suggestion.subtitle,
                                      symbol: suggestion.subtitle.isEmpty ? "magnifyingglass" : "mappin.and.ellipse",
                                      colors: [Brand.indigo, Brand.sky])
                    }
                }
            }
        }
        if search.results.isEmpty && search.suggestions.isEmpty && search.typedCoordinate == nil && !search.isSearching {
            Section {
                Button {
                    Task { await search.runFullSearch() }
                } label: {
                    Label("Search for “\(search.query)”", systemImage: "magnifyingglass")
                }
            }
        }
        if let message = search.message {
            Section {
                Label(message, systemImage: "exclamationmark.magnifyingglass")
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func row(_ place: Place, symbol: String, colors: [Color]) -> some View {
        Button { choose(place) } label: {
            PlaceRowLabel(title: place.name, subtitle: place.subtitle ?? place.coordinateText, symbol: symbol, colors: colors)
        }
    }

    private func choose(_ place: Place) {
        locations.select(place)
        dismiss()
    }
}

struct PlaceRowLabel: View {
    let title: String
    let subtitle: String
    let symbol: String
    let colors: [Color]

    var body: some View {
        HStack(spacing: 12) {
            IconTile(symbol: symbol, colors: colors, size: 34)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                if !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }
}

/// Autocomplete plus full-text search over MapKit.
@MainActor
@Observable
final class PlaceSearch {
    struct Suggestion: Identifiable {
        let id = UUID()
        let title: String
        let subtitle: String
        let completion: MKLocalSearchCompletion
    }

    var query = "" { didSet { queryChanged() } }
    private(set) var suggestions: [Suggestion] = []
    private(set) var results: [Place] = []
    private(set) var isSearching = false
    private(set) var message: String?

    @ObservationIgnored private let completer = MKLocalSearchCompleter()
    @ObservationIgnored private let bridge = CompleterBridge()
    @ObservationIgnored private var region: MKCoordinateRegion?

    init() {
        completer.resultTypes = [.address, .pointOfInterest]
        completer.delegate = bridge
        bridge.onUpdate = { [weak self] completions in
            self?.suggestions = completions.prefix(10).map {
                Suggestion(title: $0.title, subtitle: $0.subtitle, completion: $0)
            }
        }
    }

    /// "37.3349, -122.0090" typed into the field.
    var typedCoordinate: CLLocationCoordinate2D? {
        let parts = query.split(whereSeparator: { $0 == "," || $0 == " " }).compactMap { Double($0) }
        guard parts.count == 2, (-90...90).contains(parts[0]), (-180...180).contains(parts[1]) else { return nil }
        return CLLocationCoordinate2D(latitude: parts[0], longitude: parts[1])
    }

    func bias(to center: CLLocationCoordinate2D) {
        let region = MKCoordinateRegion(center: center, latitudinalMeters: 50_000, longitudinalMeters: 50_000)
        self.region = region
        completer.region = region
    }

    private func queryChanged() {
        results = []
        message = nil
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.isEmpty {
            suggestions = []
            completer.cancel()
        } else {
            completer.queryFragment = text
        }
    }

    func runFullSearch() async {
        let text = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }
        let request = MKLocalSearch.Request()
        request.naturalLanguageQuery = text
        if let region { request.region = region }
        isSearching = true
        let found = await Self.places(for: MKLocalSearch(request: request))
        isSearching = false
        guard text == query.trimmingCharacters(in: .whitespacesAndNewlines) else { return }
        results = found
        message = found.isEmpty ? "No places found for “\(text)”." : nil
    }

    func resolve(_ suggestion: Suggestion) async -> Place? {
        isSearching = true
        defer { isSearching = false }
        let places = await Self.places(for: MKLocalSearch(request: MKLocalSearch.Request(completion: suggestion.completion)))
        guard var place = places.first else {
            message = "Couldn't find “\(suggestion.title)”."
            return nil
        }
        if place.subtitle?.isEmpty ?? true { place.subtitle = suggestion.subtitle }
        return place
    }

    private static func places(for search: MKLocalSearch) async -> [Place] {
        await withCheckedContinuation { (continuation: CheckedContinuation<[Place], Never>) in
            search.start { response, _ in
                let places = (response?.mapItems ?? []).prefix(15).map { item -> Place in
                    let mark = item.placemark
                    let subtitle = [mark.thoroughfare, mark.locality, mark.country].compactMap { $0 }.joined(separator: ", ")
                    return Place(name: item.name ?? "Unnamed Place", subtitle: subtitle,
                                 latitude: mark.coordinate.latitude, longitude: mark.coordinate.longitude)
                }
                continuation.resume(returning: Array(places))
            }
        }
    }
}

/// MKLocalSearchCompleter's delegate isn't actor-annotated; MapKit calls it
/// on the main thread.
@MainActor
private final class CompleterBridge: NSObject, @preconcurrency MKLocalSearchCompleterDelegate {
    var onUpdate: (([MKLocalSearchCompletion]) -> Void)?

    func completerDidUpdateResults(_ completer: MKLocalSearchCompleter) {
        onUpdate?(completer.results)
    }

    func completer(_ completer: MKLocalSearchCompleter, didFailWithError error: Error) {
        onUpdate?([])
    }
}
