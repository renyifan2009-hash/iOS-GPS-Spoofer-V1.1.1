import PhoneOnlyCore
import SwiftUI

// MARK: - Edit the stops

/// The stops of the route being built: put them in order, delete one, say how long to wait at each, or turn
/// the whole route around.
struct RouteStopsSheet: View {
    @Bindable var route: RouteDraft
    @Environment(\.dismiss) private var dismiss

    /// The waits to pick from, seconds.
    private let waits: [Double] = [0, 30, 60, 120, 300, 600, 1800]

    var body: some View {
        NavigationStack {
            List {
                if route.stops.isEmpty {
                    ContentUnavailableView("No stops yet", systemImage: "mappin.slash",
                                           description: Text("Tap the map to add points."))
                } else {
                    Section {
                        ForEach(Array(route.stops.enumerated()), id: \.element.id) { index, stop in
                            row(index: index, stop: stop)
                        }
                        .onMove { route.move(from: $0, to: $1) }
                        .onDelete { route.remove(at: $0) }
                    } footer: {
                        Text("Drag to reorder. A wait makes the route stop there, like a red light or a visit.")
                    }
                    if route.stops.count >= 2 {
                        Section {
                            Button {
                                withAnimation(Brand.snappy) { route.reverse() }
                            } label: {
                                Label("Reverse the route", systemImage: "arrow.left.arrow.right")
                            }
                        }
                    }
                }
            }
            .navigationTitle("Stops")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { EditButton().disabled(route.stops.isEmpty) }
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func row(index: Int, stop: RouteDraft.Stop) -> some View {
        HStack(spacing: 12) {
            RouteStopPin(number: index + 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(label(for: index)).font(.body.weight(.semibold))
                Text(String(format: "%.5f, %.5f", stop.latitude, stop.longitude))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
            Menu {
                Picker("Wait here", selection: Binding(get: { stop.wait }, set: { route.setWait($0, for: stop.id) })) {
                    ForEach(waits, id: \.self) { seconds in
                        Text(seconds == 0 ? "Don't wait" : RouteText.wait(seconds)).tag(seconds)
                    }
                }
            } label: {
                Label(stop.wait > 0 ? RouteText.wait(stop.wait) : "No wait", systemImage: stop.wait > 0 ? "pause.circle.fill" : "pause.circle")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(stop.wait > 0 ? Brand.indigo : Color.secondary)
            }
            .accessibilityLabel("Wait at stop \(index + 1)")
            .accessibilityValue(stop.wait > 0 ? RouteText.wait(stop.wait) : "no wait")
        }
        .accessibilityElement(children: .combine)
    }

    private func label(for index: Int) -> String {
        switch index {
        case 0: return "Start"
        case route.stops.count - 1: return "Destination"
        default: return "Stop \(index + 1)"
        }
    }
}

// MARK: - Saved and recent routes

/// Routes saved by name, and the last few that were driven. Tap one to put it back on the map.
struct RouteHistorySheet: View {
    var route: RouteDraft
    var library: RouteLibrary
    @Environment(\.dismiss) private var dismiss

    private enum Tab: String, CaseIterable, Identifiable {
        case saved = "Saved", recent = "Recent"
        var id: String { rawValue }
    }

    @State private var tab: Tab = .saved
    @State private var renaming: SavedRoute?
    @State private var renameText = ""

    private var routes: [SavedRoute] { tab == .saved ? library.saved : library.recents }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                Picker("Show", selection: $tab) {
                    ForEach(Tab.allCases) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .padding(.horizontal)
                .padding(.vertical, 8)
                list
            }
            .navigationTitle("Routes")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if tab == .recent, !library.recents.isEmpty {
                        Button("Clear", role: .destructive) { library.clearRecents() }
                    }
                }
                ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } }
            }
            .alert("Rename route", isPresented: Binding(get: { renaming != nil }, set: { if !$0 { renaming = nil } })) {
                TextField("Name", text: $renameText)
                Button("Save") {
                    if let id = renaming?.id { library.rename(id, to: renameText) }
                    renaming = nil
                }
                Button("Cancel", role: .cancel) { renaming = nil }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    @ViewBuilder
    private var list: some View {
        if routes.isEmpty {
            ContentUnavailableView(
                tab == .saved ? "No saved routes" : "No recent routes",
                systemImage: tab == .saved ? "bookmark" : "clock",
                description: Text(tab == .saved ? "Build a route and tap Save to keep it here."
                                                : "Routes you drive show up here."))
        } else {
            List {
                ForEach(routes) { saved in
                    Button {
                        route.apply(saved)
                        dismiss()
                    } label: {
                        row(saved)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        if tab == .saved {
                            Button("Rename", systemImage: "pencil") {
                                renameText = saved.name
                                renaming = saved
                            }
                        } else if !library.isSaved(saved) {
                            Button("Save", systemImage: "bookmark") { library.save(saved) }
                        }
                    }
                }
                .onDelete { offsets in
                    if tab == .saved { library.removeSaved(at: offsets) } else { library.removeRecents(at: offsets) }
                }
            }
            .listStyle(.plain)
        }
    }

    private func row(_ saved: SavedRoute) -> some View {
        HStack(spacing: 12) {
            Image(systemName: saved.driving ? "car.fill" : "figure.walk")
                .font(.system(size: 16, weight: .semibold))
                .foregroundStyle(Brand.indigo)
                .frame(width: 36, height: 36)
                .background(Brand.indigo.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
            VStack(alignment: .leading, spacing: 2) {
                Text(saved.name).font(.body.weight(.semibold)).lineLimit(1)
                Text("\(saved.stops.count) stops · \(RouteText.distance(saved.straightLineMeters))\(saved.repeats == "once" ? "" : " · \(saved.repeats == "loop" ? "loop" : "there & back")")")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary)
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .combine)
        .accessibilityHint("Puts this route on the map")
    }
}
