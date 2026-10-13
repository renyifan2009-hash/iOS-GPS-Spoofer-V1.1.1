import PhoneOnlyCore
import RemoteAPI
import SwiftUI

/// A numbered pin for a route waypoint on the map.
struct RouteStopPin: View {
    let number: Int

    var body: some View {
        ZStack {
            Circle()
                .fill(Brand.sky.gradient)
                .frame(width: 26, height: 26)
                .overlay(Circle().strokeBorder(.white, lineWidth: 2))
                .shadow(color: .black.opacity(0.25), radius: 3, y: 1)
            Text("\(number)")
                .font(.system(size: 13, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
        }
        .accessibilityLabel("Stop \(number)")
    }
}

/// Short, locale-aware text for lengths and times.
enum RouteText {
    static func distance(_ meters: Double) -> String {
        Measurement(value: meters, unit: UnitLength.meters)
            .formatted(.measurement(width: .abbreviated, usage: .road, numberFormatStyle: .number.precision(.fractionLength(0...1))))
    }

    static func duration(_ seconds: Double) -> String {
        let total = Int(max(0, seconds.isFinite ? seconds : 0).rounded())
        let h = total / 3600, m = (total % 3600) / 60
        if h > 0 { return m > 0 ? "\(h) h \(m) min" : "\(h) h" }
        return total < 60 ? "under a minute" : "\(max(1, m)) min"
    }

    /// Km/h or mph, by region.
    static func speed(_ metersPerSecond: Double) -> String {
        SpeedText.format(metersPerSecond: metersPerSecond, imperial: Locale.current.measurementSystem == .us)
    }

    /// "30 sec", "2 min".
    static func wait(_ seconds: Double) -> String {
        seconds < 60 ? "\(Int(seconds)) sec" : "\(Int(seconds / 60)) min"
    }
}

// MARK: - Build a route

/// Build a route on the map, then send it to the Mac to drive.
struct RouteCardView: View {
    @Bindable var route: RouteDraft
    var connection: any ControlTarget
    var library: RouteLibrary

    @State private var showStops = false
    @State private var showHistory = false
    @State private var askName = false
    @State private var nameText = ""

    private var speedRange: ClosedRange<Double> { route.driving ? 10...120 : 1...10 }
    private var speedStep: Double { route.driving ? 5 : 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if route.canDrive {
                summary
                options
            }
            toolRow
        }
        .animation(Brand.spring, value: route.stops.count)
        .animation(Brand.spring, value: route.driving)
        .sheet(isPresented: $showStops) {
            RouteStopsSheet(route: route)
        }
        .sheet(isPresented: $showHistory) {
            RouteHistorySheet(route: route, library: library)
        }
        .alert("Save this route", isPresented: $askName) {
            TextField("Name", text: $nameText)
            Button("Save") { save() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Saved routes stay on this iPhone and are listed under Saved.")
        }
    }

    // MARK: Pieces

    private var header: some View {
        HStack(spacing: 12) {
            IconTile(symbol: "point.topleft.down.to.point.bottomright.curvepath.fill", size: 42)
            VStack(alignment: .leading, spacing: 2) {
                Text(route.stops.isEmpty ? "Build a route"
                     : route.name ?? "\(route.stops.count) stop\(route.stops.count == 1 ? "" : "s")")
                    .font(Brand.rounded(.title3))
                    .lineLimit(1)
                    .contentTransition(.opacity)
                Text(route.canDrive ? "Tap the map to add more, or drive it."
                     : route.canAddStop ? "Tap the map to add points (two or more)."
                     : "That's the most stops a route can have.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if !route.stops.isEmpty {
                Button {
                    withAnimation(Brand.snappy) { route.removeLast() }
                } label: {
                    Image(systemName: "arrow.uturn.backward")
                        .font(.system(size: 16, weight: .semibold))
                        .frame(width: 40, height: 40)
                        .glassCircle()
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Remove the last stop")
                Button {
                    withAnimation(Brand.snappy) { route.clear() }
                } label: {
                    Image(systemName: "trash")
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundStyle(Brand.danger)
                        .frame(width: 40, height: 40)
                        .glassCircle()
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear the route")
            }
        }
    }

    /// How long it is and about how long it takes. The Mac plans the real roads, so this is the least.
    private var summary: some View {
        HStack(spacing: 14) {
            Label(RouteText.distance(route.straightLineMeters), systemImage: "ruler")
            if let seconds = route.roughSeconds {
                Label(RouteText.duration(seconds) == "under a minute" ? "under a minute" : "about \(RouteText.duration(seconds))",
                      systemImage: "clock")
            }
            if route.stops.contains(where: { $0.wait > 0 }) {
                Label("waits", systemImage: "pause.circle")
            }
            Spacer(minLength: 0)
        }
        .font(.footnote.weight(.semibold))
        .foregroundStyle(.secondary)
        .labelStyle(.titleAndIcon)
        .accessibilityElement(children: .combine)
    }

    private var options: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Travel", selection: $route.driving) {
                Text("Driving").tag(true)
                Text("Walking").tag(false)
            }
            .pickerStyle(.segmented)

            Picker("Repeat", selection: $route.repeats) {
                ForEach(RouteDraft.Repeat.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)

            Toggle("Follow roads & paths", isOn: $route.followRoads)
            if route.driving, connection.executionName == "Mac" {
                Toggle("Slower in rush hour", isOn: $route.timeOfDayTraffic)
            }

            HStack(spacing: 12) {
                Text("Speed")
                Slider(value: $route.speedKmh, in: speedRange, step: speedStep)
                    .accessibilityLabel("Top speed")
                Text("\(Int(route.speedKmh.rounded())) km/h")
                    .font(.system(.subheadline, design: .rounded).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .font(.subheadline)
        .onChange(of: route.driving) { _, driving in
            route.speedKmh = driving ? 50 : 5
        }
    }

    private var toolRow: some View {
        HStack(spacing: 8) {
            toolButton("Stops", symbol: "list.number", enabled: !route.stops.isEmpty) { showStops = true }
            toolButton("Save", symbol: "bookmark", enabled: route.canDrive) {
                nameText = route.name ?? ""
                askName = true
            }
            toolButton("Saved", symbol: "clock.arrow.circlepath", enabled: true) { showHistory = true }
        }
    }

    private func toolButton(_ title: String, symbol: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: symbol).font(.system(size: 16, weight: .semibold))
                Text(title).font(.caption2.weight(.semibold)).lineLimit(1).minimumScaleFactor(0.8)
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .foregroundStyle(enabled ? Color.primary : Color.secondary)
            .background(Color.primary.opacity(0.07), in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .accessibilityLabel(title)
    }

    private func save() {
        guard let saved = library.save(route.snapshot(named: nameText)) else { return }
        route.name = saved.name
    }
}

// MARK: - While it drives

/// A route that is driving: how far along, and pause, resume or stop.
struct RouteProgressCardView: View {
    var route: RouteDraft
    var connection: any ControlTarget

    private var status: RemoteStatus? { connection.status }
    private var planning: Bool { status?.activity == "planning" }
    private var paused: Bool { status?.routePaused ?? false }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                IconTile(symbol: planning ? "map.fill" : (paused ? "pause.fill" : "point.topleft.down.to.point.bottomright.curvepath.fill"),
                         colors: paused ? [Brand.warning, Brand.warning.opacity(0.7)] : [Brand.indigo, Brand.sky], size: 42)
                VStack(alignment: .leading, spacing: 2) {
                    Text(route.name ?? "Route").font(Brand.rounded(.title3)).lineLimit(1)
                    Text(subtitle)
                        .font(.subheadline.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
                Spacer(minLength: 0)
                AutoStopRow(connection: connection, compact: true)
            }
            if planning {
                ProgressView().frame(maxWidth: .infinity, alignment: .leading)
            } else if let progress = status?.routeProgress {
                ProgressView(value: min(max(progress, 0), 1))
                    .tint(paused ? Brand.warning : Brand.indigo)
                    .accessibilityLabel("Route progress")
                    .accessibilityValue("\(Int((progress * 100).rounded())) percent")
            }
            GlassGroup(spacing: 10) {
                HStack(spacing: 10) {
                    Button {
                        Task { await connection.setPaused(!paused) }
                    } label: {
                        Label(paused ? "Resume" : "Pause", systemImage: paused ? "play.fill" : "pause.fill")
                            .frame(maxWidth: .infinity)
                            .contentTransition(.opacity)
                    }
                    .prominentButton()
                    .disabled(planning || connection.isWorking)
                    Button {
                        Task { await connection.stop() }
                    } label: {
                        Label("Stop", systemImage: "stop.fill").frame(maxWidth: .infinity)
                    }
                    .prominentButton(tint: Brand.danger)
                }
            }
            .disabled(connection.isWorking && !planning)
        }
        .animation(Brand.spring, value: paused)
        .animation(Brand.spring, value: planning)
    }

    private var subtitle: String {
        if planning { return "Planning the route on the \(connection.executionName)…" }
        var parts: [String] = []
        if let progress = status?.routeProgress { parts.append("\(Int((progress * 100).rounded()))%") }
        if paused {
            parts.append("paused")
        } else if let speed = status?.speed, speed > 0.1 {
            parts.append(RouteText.speed(speed))
        }
        return parts.isEmpty ? "Driving" : parts.joined(separator: " · ")
    }
}
