import MapKit
import RemoteAPI
import SwiftUI

/// Who holds the simulated location.
enum LocationSource: String {
    /// The Mac, over USB or Wi-Fi; this app tells it where to go.
    case mac
    /// This iPhone by itself (the iPhone-only mode).
    case thisPhone
}

/// The map, a floating status pill and controls, and a glass card to start,
/// move or stop the simulated location.
struct ContentView: View {
    @Environment(ConnectionManager.self) private var connection
    @Environment(LocationController.self) private var locations
    @Environment(OnDeviceController.self) private var phone
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("hasSeenIntro") private var hasSeenIntro = false
    @AppStorage("locationSource") private var source: LocationSource = .mac
    @State private var showIntro = false
    @State private var showSearch = false
    @State private var showPairing = false
    @State private var showPhoneSetup = false
    @State private var pairAfterIntro = false

    /// Either source holds a location right now.
    private var isSpoofing: Bool { connection.isSpoofing || phone.isSpoofing }

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
        .sheet(isPresented: $showPhoneSetup) {
            PhoneOnlySetupView()
        }
        .onOpenURL { url in
            // A pairing file opened from AirDrop, Files or Mail.
            if phone.importPairingFile(from: url), !isSpoofing { source = .thisPhone }
            guard showPairing else {
                showPhoneSetup = true
                return
            }
            // One sheet at a time: let the Mac sheet go first.
            showPairing = false
            Task {
                try? await Task.sleep(for: .milliseconds(500))
                showPhoneSetup = true
            }
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
            #if DEBUG
            // For screenshots in the Simulator: `-SpoofRemoteShow phoneSetup`
            // opens the setup sheet; `phoneStart` starts at Apple Park.
            switch UserDefaults.standard.string(forKey: "SpoofRemoteShow") {
            case "phoneSetup":
                showPhoneSetup = true
            case "phoneStart":
                let place = Place(name: "Apple Park", subtitle: "Cupertino", latitude: 37.3349, longitude: -122.0090)
                locations.selection = place
                locations.focus(on: place.coordinate, meters: 2500)
                setPhone(place)
            default:
                break
            }
            #endif
        }
        .task(id: source) {
            // Is LocalDevVPN on? The status pill says so before you tap Start.
            if source == .thisPhone, phone.isSetUp, !phone.isSpoofing { await phone.checkLoopback() }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                connection.startBrowsing()
                connection.startPolling()
                if source == .thisPhone, phone.isSetUp, !phone.isSpoofing {
                    Task { await phone.checkLoopback() }
                }
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
        .sensoryFeedback(trigger: isSpoofing) { _, isSpoofing in
            isSpoofing ? .success : .impact(weight: .light)
        }
    }

    // MARK: - Map

    private var spoofedCoordinate: CLLocationCoordinate2D? {
        if source == .thisPhone { return phone.current }
        guard let status = connection.status, status.spoofing,
              let latitude = status.latitude, let longitude = status.longitude else { return nil }
        return CLLocationCoordinate2D(latitude: latitude, longitude: longitude)
    }

    private var markerPhase: SpoofPhase {
        source == .thisPhone ? (phone.isSpoofing ? .active : .starting) : (connection.status?.phase ?? .idle)
    }

    private var map: some View {
        @Bindable var locations = locations
        return MapReader { proxy in
            Map(position: $locations.camera) {
                if let spoofed = spoofedCoordinate {
                    Annotation("Simulated location", coordinate: spoofed, anchor: .center) {
                        DeviceMarker(phase: markerPhase)
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
            Button {
                if source == .thisPhone { showPhoneSetup = true } else { showPairing = true }
            } label: {
                if source == .thisPhone {
                    PhonePill(phone: phone)
                } else {
                    StatusPill(connection: connection)
                }
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
            sourcePicker
            if source == .thisPhone {
                phoneCard
            } else {
                macCard
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(cornerRadius: 32)
        .animation(Brand.spring, value: source)
        .animation(Brand.spring, value: connection.isPaired)
        .animation(Brand.spring, value: isSpoofing)
        .animation(Brand.spring, value: locations.selection)
        .animation(Brand.spring, value: connection.lastError)
        .animation(Brand.spring, value: phone.lastError)
        .animation(Brand.spring, value: connection.status?.connected)
    }

    private var sourcePicker: some View {
        Picker("Change the location from", selection: $source) {
            Text("Mac").tag(LocationSource.mac)
            Text("This iPhone").tag(LocationSource.thisPhone)
        }
        .pickerStyle(.segmented)
        // One at a time: stop the current location before switching.
        .disabled(isSpoofing)
    }

    @ViewBuilder
    private var macCard: some View {
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

    // MARK: - This iPhone

    @ViewBuilder
    private var phoneCard: some View {
        if !OnDeviceController.isSupported || !phone.isSetUp {
            phoneSetupPrompt
                .transition(.rise)
        } else {
            if phone.isSpoofing, let current = phone.current {
                PhoneSimulatingRow(name: phone.currentName, coordinate: current)
                    .transition(.rise)
            }
            if let place = locations.selection {
                selectionRow(place)
                    .transition(.rise)
            } else if !phone.isSpoofing {
                Label("Tap the map or search to pick a place.", systemImage: "hand.tap.fill")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .transition(.rise)
            }
            phoneActions
            if let error = phone.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(Brand.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .transition(.rise)
            }
        }
    }

    private var phoneSetupPrompt: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 14) {
                IconTile(symbol: "iphone.gen3.radiowaves.left.and.right", size: 46)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Use this iPhone on its own").font(Brand.rounded(.title3))
                    Text(OnDeviceController.isSupported
                         ? "Set it up once with your Mac. Then change the location anywhere, even on cellular."
                         : "Needs iOS 17.4 or later. Use your Mac instead, or update this iPhone.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            Button {
                showPhoneSetup = true
            } label: {
                Label("Set Up", systemImage: "checklist")
                    .frame(maxWidth: .infinity)
            }
            .prominentButton()
            .disabled(!OnDeviceController.isSupported)
        }
    }

    private var phoneActions: some View {
        GlassGroup(spacing: 10) {
            HStack(spacing: 10) {
                if phone.isSpoofing {
                    if let place = locations.selection, !phoneIsAt(place) {
                        Button {
                            setPhone(place)
                        } label: {
                            Label("Move Here", systemImage: "arrow.triangle.turn.up.right.diamond.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .prominentButton()
                        .transition(.scale.combined(with: .opacity))
                    }
                    Button {
                        Task { await phone.stop() }
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .prominentButton(tint: Brand.danger)
                } else {
                    Button {
                        if let place = locations.selection { setPhone(place) }
                    } label: {
                        Label(phone.isWorking ? "Starting…" : "Start Here", systemImage: "location.fill")
                            .frame(maxWidth: .infinity)
                            .contentTransition(.opacity)
                    }
                    .prominentButton()
                    .disabled(locations.selection == nil || phone.isWorking)
                }
            }
        }
        .disabled(phone.isWorking)
    }

    private func setPhone(_ place: Place) {
        Task {
            if await phone.set(place.coordinate, name: place.name) { locations.recordRecent(place) }
        }
    }

    private func phoneIsAt(_ place: Place) -> Bool {
        guard let current = phone.current else { return false }
        return abs(current.latitude - place.latitude) < 1e-5 && abs(current.longitude - place.longitude) < 1e-5
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
        PillContent(text: display.text, color: display.color, live: display.live)
    }
}

/// The iPhone-only mode's status, in the same capsule.
private struct PhonePill: View {
    let phone: OnDeviceController

    private var display: (text: String, color: Color, live: Bool) {
        guard OnDeviceController.isSupported else { return ("This iPhone · Needs iOS 17.4", Brand.warning, false) }
        guard phone.isSetUp else { return ("This iPhone · Tap to set up", .gray, false) }
        switch phone.phase {
        case .active: return ("Simulating · This iPhone", Brand.live, true)
        case .connecting: return ("Connecting · This iPhone", Brand.sky, false)
        case .idle:
            if phone.loopbackReachable == false { return ("Turn on LocalDevVPN", Brand.warning, false) }
            return ("Ready · This iPhone", Brand.live, false)
        }
    }

    var body: some View {
        let display = self.display
        PillContent(text: display.text, color: display.color, live: display.live)
    }
}

private struct PillContent: View {
    let text: String
    let color: Color
    let live: Bool

    var body: some View {
        HStack(spacing: 8) {
            if live {
                PulsingDot(color: color, size: 8)
            } else {
                Circle().fill(color).frame(width: 8, height: 8)
            }
            Text(text)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .contentTransition(.opacity)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .glassCapsule(interactive: true)
        .animation(Brand.spring, value: text)
    }
}

/// What the iPhone-only mode is holding.
private struct PhoneSimulatingRow: View {
    let name: String?
    let coordinate: CLLocationCoordinate2D

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                Circle().fill(Brand.gradient).frame(width: 44, height: 44)
                    .shadow(color: Brand.indigo.opacity(0.5), radius: 10, y: 4)
                Image(systemName: "location.fill")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(.white)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text("NOW SIMULATING · THIS IPHONE")
                    .font(.caption2.weight(.bold))
                    .kerning(0.8)
                    .foregroundStyle(.secondary)
                Text(name ?? "Custom location")
                    .font(Brand.rounded(.headline))
                    .lineLimit(1)
                    .contentTransition(.opacity)
                Text(String(format: "%.5f, %.5f", coordinate.latitude, coordinate.longitude))
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            Spacer(minLength: 0)
        }
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
