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

/// Build a route on the map, then send it to the Mac to drive.
struct RouteCardView: View {
    @Bindable var route: RouteDraft
    var connection: ConnectionManager
    var drive: () -> Void

    private var speedRange: ClosedRange<Double> { route.driving ? 10...120 : 1...10 }
    private var speedStep: Double { route.driving ? 5 : 1 }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if route.canDrive {
                options
            }
            driveButton
        }
        .animation(Brand.spring, value: route.stops.count)
        .animation(Brand.spring, value: route.driving)
    }

    private var header: some View {
        HStack(spacing: 12) {
            IconTile(symbol: "point.topleft.down.to.point.bottomright.curvepath.fill", size: 42)
            VStack(alignment: .leading, spacing: 2) {
                Text(route.stops.isEmpty ? "Build a route"
                     : "\(route.stops.count) stop\(route.stops.count == 1 ? "" : "s")")
                    .font(Brand.rounded(.title3))
                    .contentTransition(.opacity)
                Text(route.canDrive ? "Tap the map to add more, or drive it."
                     : "Tap the map to add points (two or more).")
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
            if route.driving {
                Toggle("Slower in rush hour", isOn: $route.timeOfDayTraffic)
            }

            HStack(spacing: 12) {
                Text("Speed")
                Slider(value: $route.speedKmh, in: speedRange, step: speedStep)
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

    private var driveButton: some View {
        GlassGroup(spacing: 10) {
            Button {
                drive()
            } label: {
                Label(connection.isWorking ? "Starting…" : "Drive Route", systemImage: "car.fill")
                    .frame(maxWidth: .infinity)
                    .contentTransition(.opacity)
            }
            .prominentButton()
            .disabled(!route.canDrive || connection.isWorking || !connection.isOnline)
        }
    }
}
