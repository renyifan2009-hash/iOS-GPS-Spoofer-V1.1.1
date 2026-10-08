import MapKit
import RemoteAPI
import SwiftUI

/// The map, a floating status pill and controls, and a glass card to start,
/// move or stop the simulated location.
struct ContentView: View {
    @Environment(ConnectionManager.self) private var connection
    @Environment(LocationController.self) private var locations
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("hasSeenIntro") private var hasSeenIntro = false
    @State private var showIntro = false
    @State private var showSearch = false
    @State private var showPairing = false
    @State private var pairAfterIntro = false

    var body: some View {
        ZStack {
            map
            VStack(spacing: 0) {
                topBar
                Spacer(minLength: 0)
                bottomCard
            }
            .padding(.horizontal, 14)
            .padding(.bottom, 8)
        }
        .sheet(isPresented: $showSearch) {
            MapSearchView()
                .presentationDetents([.medium, .large])
                .presentationDragIndicator(.visible)
        }
        .sheet(isPresented: $showPairing) {
            PairingView()
        }
        .fullScreenCover(isPresented: $showIntro, onDismiss: {
            if pairAfterIntro {
                pairAfterIntro = false
                showPairing = true
            }
        }) {
            IntroView { pairNow in
                hasSeenIntro = true
                pairAfterIntro = pairNow
                showIntro = false
            }
        }
        .onAppear {
            if !hasSeenIntro { showIntro = true }
            connection.startBrowsing()
            connection.startPolling()
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                connection.startBrowsing()
                connection.startPolling()
            case .background:
                connection.stopPolling()
                connection.stopBrowsing()
            default:
                break
            }
        }
        .task(id: connection.isSpoofing) {
            // Opening the app while a location is held: show where it is.
            if connection.isSpoofing, locations.selection == nil, let spoofed = spoofedCoordinate {
                locations.focus(on: spoofed, meters: 2500)
            }
        }
        .sensoryFeedback(.selection, trigger: locations.selection?.id)
        .sensoryFeedback(trigger: connection.isSpoofing) { _, isSpoofing in
            isSpoofing ? .success : .impact(weight: .light)
        }
    }

    // MARK: - Map

    private var spoofedCoordinate: CLLocationCoordinate2D? {
        guard let status = connection.status, status.spoofing,
              let latitude = status.latitude, let longitude = status.longitude else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    private var map: some View {
        @Bindable var locations = locations
        return MapReader { proxy in
            Map(position: $locations.camera) {
                if let spoofed = spoofedCoordinate {
                    Annotation("Simulated location", coordinate: spoofed, anchor: .center) {
                        DeviceMarker(phase: connection.status?.phase ?? .idle)
                    }
                    .annotationTitles(.hidden)
                }
                if let selection = locations.selection {
                    Annotation(selection.name, coordinate: selection.coordinate, anchor: .bottom) {
                        SelectionPin().id(selection.id)
                    }
                    .annotationTitles(.hidden)
                }
                if locations.showsReportedLocation {
                    UserAnnotation()
                }
            }
            .mapStyle(.standard(elevation: .realistic))
            .mapControls {
                MapCompass()
                MapScaleView()
            }
            .onTapGesture { point in
                if let coordinate = proxy.convert(point, from: .local) {
                    withAnimation(Brand.spring) { locations.drop(at: coordinate) }
                }
            }
        }
        .ignoresSafeArea()
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 10) {
            Button { showPairing = true } label: {
                StatusPill(connection: connection)
            }
            .buttonStyle(.plain)
            Spacer(minLength: 8)
            GlassGroup(spacing: 8) {
                HStack(spacing: 8) {
                    CircleButton(symbol: locations.showsReportedLocation ? "location.fill" : "location",
                                 tint: locations.showsReportedLocation ? Brand.sky : nil) {
                        withAnimation(Brand.snappy) { locations.toggleReportedLocation() }
                    }
                    CircleButton(symbol: "magnifyingglass") { showSearch = true }
                }
            }
        }
        .padding(.top, 6)
    }

    // MARK: - Bottom card

    private var bottomCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            if !connection.isPaired {
                connectPrompt
                    .transition(.rise)
            } else {
                if connection.isSpoofing, let status = connection.status {
                    NowSimulatingRow(status: status)
                        .transition(.rise)
                }
                if let status = connection.status, !status.connected, connection.isOnline {
                    Label("The Mac can't see this iPhone. Connect them with a cable and tap Trust.",
                          systemImage: "cable.connector")
                        .font(.footnote)
                        .foregroundStyle(Brand.warning)
                        .transition(.rise)
                }
                if let place = locations.selection {
                    selectionRow(place)
                        .transition(.rise)
                } else if !connection.isSpoofing {
                    Label("Tap the map or search to pick a place.", systemImage: "hand.tap.fill")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .transition(.rise)
                }
                actions
                if let error = connection.lastError {
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(Brand.warning)
                        .transition(.rise)
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(cornerRadius: 32)
        .animation(Brand.spring, value: connection.isPaired)
        .animation(Brand.spring, value: connection.isSpoofing)
        .animation(Brand.spring, value: locations.selection)
        .animation(Brand.spring, value: connection.lastError)
        .animation(Brand.spring, value: connection.status?.connected)
    }

    private var connectPrompt: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                IconTile(symbol: "laptopcomputer.and.iphone", size: 46)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Connect your Mac").font(Brand.rounded(.title3))
                    Text("Your Mac holds the simulated location; this iPhone tells it where to go.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Button {
                showPairing = true
            } label: {
                Label("Find My Mac", systemImage: "dot.radiowaves.left.and.right")
                    .frame(maxWidth: .infinity)
            }
            .prominentButton()
        }
    }

    private func selectionRow(_ place: Place) -> some View {
        let favorite = locations.isFavorite(place)
        return HStack(spacing: 12) {
            IconTile(symbol: "mappin", colors: [Color(red: 0.99, green: 0.42, blue: 0.42), Color(red: 0.86, green: 0.15, blue: 0.27)],
                     size: 42)
            VStack(alignment: .leading, spacing: 2) {
                Text(place.name)
                    .font(Brand.rounded(.title3))
                    .lineLimit(1)
                    .contentTransition(.opacity)
                Text(place.subtitle.flatMap { $0.isEmpty ? nil : $0 } ?? place.coordinateText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .contentTransition(.opacity)
            }
            Spacer(minLength: 0)
            Button {
                withAnimation(Brand.snappy) { locations.toggleFavorite(place) }
            } label: {
                Image(systemName: favorite ? "star.fill" : "star")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(favorite ? Color.yellow : Color.secondary)
                    .symbolEffect(.bounce, value: favorite)
                    .frame(width: 44, height: 44)
                    .glassCircle()
            }
            .buttonStyle(.plain)
            .accessibilityLabel(favorite ? "Remove from favorites" : "Add to favorites")
        }
    }

    private var actions: some View {
        GlassGroup(spacing: 10) {
            HStack(spacing: 10) {
                if connection.isSpoofing {
                    if let place = locations.selection, !isCurrent(place) {
                        Button {
                            send(.move, place)
                        } label: {
                            Label("Move Here", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .prominentButton()
                        .transition(.scale.combined(with: .opacity))
                    }
                    Button {
                        Task { await connection.stop() }
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .prominentButton(tint: Brand.danger)
                } else {
                    Button {
                        if let place = locations.selection { send(.start, place) }
                    } label: {
                        Label(connection.isWorking ? "Starting…" : "Start Here", systemImage: "location.fill")
                            .frame(maxWidth: .infinity)
                            .contentTransition(.opacity)
                    }
                    .prominentButton()
                    .disabled(locations.selection == nil || connection.isWorking || !connection.isOnline)
                }
            }
        }
        .disabled(connection.isWorking)
    }

    private enum Command { case start, move }

    private func send(_ command: Command, _ place: Place) {
        Task {
            let ok: Bool
            switch command {
            case .start: ok = await connection.start(at: place.request)
            case .move: ok = await connection.move(to: place.request)
            }
            if ok { locations.recordRecent(place) }
        }
    }

    private func isCurrent(_ place: Place) -> Bool {
        guard let status = connection.status, let latitude = status.latitude, let longitude = status.longitude else {
            return false
        }
        return abs(latitude - place.latitude) < 1e-5 && abs(longitude - place.longitude) < 1e-5
    }
}

// MARK: - Pieces

/// Mac link + iPhone link + what's happening, in one capsule.
private struct StatusPill: View {
    let connection: ConnectionManager

    private var display: (text: String, color: Color, live: Bool) {
        switch connection.link {
        case .unpaired:
            return ("Not connected · Tap to pair", .gray, false)
        case .connecting:
            return ("Connecting to \(connection.server?.name ?? "Mac")…", Brand.sky, false)
        case .offline:
            return ("\(connection.server?.name ?? "Mac") is offline", Brand.warning, false)
        case .online:
            let name = connection.server?.name ?? "Mac"
            guard let status = connection.status else { return (name, Brand.sky, false) }
            switch status.phase {
            case .active: return ("Simulating · \(name)", Brand.live, true)
            case .starting: return ("Starting · \(name)", Brand.sky, false)
            case .reconnecting: return ("Reconnecting · \(name)", Brand.warning, false)
            case .stopping: return ("Restoring · \(name)", Brand.sky, false)
            case .failed: return ("Retrying · \(name)", Brand.danger, false)
            case .idle: return (status.connected ? "Ready · \(name)" : "\(name) · No iPhone", status.connected ? Brand.live : Brand.warning, false)
            }
        }
    }

    var body: some View {
        let display = self.display
        HStack(spacing: 8) {
            if display.live {
                PulsingDot(color: display.color, size: 8)
            } else {
                Circle().fill(display.color).frame(width: 8, height: 8)
            }
            Text(display.text)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .contentTransition(.opacity)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .glassCapsule(interactive: true)
        .animation(Brand.spring, value: display.text)
    }
}

private struct NowSimulatingRow: View {
    let status: RemoteStatus

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(Brand.gradient).frame(width: 44, height: 44)
                    .shadow(color: Brand.indigo.opacity(0.5), radius: 10, y: 4)
                Image(systemName: "location.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
                    .symbolEffect(.pulse, options: .repeating, isActive: status.phase != .active)
            }
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text("NOW SIMULATING")
                        .font(.caption2.weight(.bold))
                        .kerning(0.8)
                        .foregroundStyle(.secondary)
                    if let engine = status.engine {
                        Text(engine)
                            .font(.caption2.weight(.semibold))
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Brand.indigo.opacity(0.18), in: Capsule())
                    }
                }
                Text(status.placeName ?? "Custom location")
                    .font(Brand.rounded(.headline))
                    .lineLimit(1)
                    .contentTransition(.opacity)
                if let latitude = status.latitude, let longitude = status.longitude {
                    Text(String(format: "%.5f, %.5f", latitude, longitude))
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .contentTransition(.numericText())
                }
                if let detail = status.detail, status.phase != .active {
                    Text(detail)
                        .font(.caption)
                        .foregroundStyle(Brand.warning)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
            if let device = status.device {
                VStack(alignment: .trailing, spacing: 2) {
                    Image(systemName: device.connection == "usb" ? "cable.connector" : "wifi")
                        .foregroundStyle(.secondary)
                    Text(device.model).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
            }
        }
        .animation(Brand.spring, value: status)
    }
}

private struct CircleButton: View {
    let symbol: String
    var tint: Color? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 17, weight: .semibold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: 48, height: 48)
                .glassCircle(tint: tint)
        }
        .buttonStyle(.plain)
    }
}

/// The chosen spot: a gradient pin that drops in with a bounce.
private struct SelectionPin: View {
    @State private var landed = false

    var body: some View {
        ZStack(alignment: .top) {
            PinShape()
                .fill(LinearGradient(colors: [Color(red: 0.99, green: 0.42, blue: 0.42), Color(red: 0.86, green: 0.15, blue: 0.27)],
                                     startPoint: .top, endPoint: .bottom))
                .overlay(PinShape().stroke(.white, lineWidth: 2.5))
                .frame(width: 34, height: 44)
                .shadow(color: .black.opacity(0.35), radius: 6, y: 4)
            Circle().fill(.white).frame(width: 12, height: 12).padding(.top, 11)
        }
        .scaleEffect(landed ? 1 : 0.4, anchor: .bottom)
        .offset(y: landed ? 0 : -46)
        .opacity(landed ? 1 : 0)
        .onAppear {
            withAnimation(.spring(duration: 0.55, bounce: 0.5)) { landed = true }
        }
    }
}

/// Where the Mac is holding the iPhone: a glowing dot with a ripple, amber
/// while it's (re)connecting.
private struct DeviceMarker: View {
    let phase: SpoofPhase
    @State private var ripple = false

    private var color: Color {
        switch phase {
        case .active: return Brand.indigo
        case .failed: return Brand.danger
        default: return Brand.warning
        }
    }

    var body: some View {
        ZStack {
            Circle()
                .fill(color.opacity(0.25))
                .frame(width: 70, height: 70)
                .scaleEffect(ripple ? 1.25 : 0.55)
                .opacity(ripple ? 0 : 1)
            Circle()
                .fill(.white)
                .frame(width: 26, height: 26)
                .shadow(color: .black.opacity(0.3), radius: 5, y: 2)
            Circle()
                .fill(phase == .active ? AnyShapeStyle(Brand.gradient) : AnyShapeStyle(color))
                .frame(width: 18, height: 18)
        }
        .animation(Brand.spring, value: phase)
        .onAppear {
            withAnimation(.easeOut(duration: 1.8).repeatForever(autoreverses: false)) { ripple = true }
        }
    }
}
