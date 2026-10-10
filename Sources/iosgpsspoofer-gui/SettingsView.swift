import AppKit
import SpooferCore
import SpooferRemote
import SwiftUI

struct SettingsView: View {
    enum Tab: Hashable {
        case general, engine, movement, remote, about
    }

    @State private var tab: Tab

    init(tab: Tab = .general) {
        _tab = State(initialValue: tab)
    }

    var body: some View {
        TabView(selection: $tab) {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
                .tag(Tab.general)
            EngineSettings()
                .tabItem { Label("Engine", systemImage: "bolt.horizontal") }
                .tag(Tab.engine)
            MovementSettings()
                .tabItem { Label("Movement", systemImage: "figure.walk.motion") }
                .tag(Tab.movement)
            RemoteSettings()
                .tabItem { Label("iPhone Remote", systemImage: "iphone.radiowaves.left.and.right") }
                .tag(Tab.remote)
            AboutSettings()
                .tabItem { Label("About", systemImage: "info.circle") }
                .tag(Tab.about)
        }
        .frame(width: 620)
        .scenePadding()
    }
}

private struct GeneralSettings: View {
    @Environment(Preferences.self) private var prefs
    @Environment(LibraryStore.self) private var library
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var prefs = prefs
        Form {
            Picker("Units", selection: $prefs.units) {
                ForEach(UnitSystem.allCases) { Text($0.label).tag($0) }
            }
            Picker("Map style", selection: $prefs.mapStyle) {
                ForEach(MapStyle.allCases) { Text($0.label).tag($0) }
            }
            Toggle("Follow the iPhone on the map when spoofing starts", isOn: $prefs.followDevice)
            Toggle("Show in the menu bar", isOn: $prefs.showMenuBarExtra)
            Toggle("Remember recent locations", isOn: $prefs.recordRecents)
            LabeledContent("Scan for devices every") {
                Stepper("\(Int(prefs.autoRefreshInterval)) s", value: $prefs.autoRefreshInterval, in: 2...30, step: 1)
            }
            LabeledContent("Library") {
                HStack {
                    Text("\(library.favorites.count) favorites · \(library.routes.count) routes")
                        .foregroundStyle(.secondary)
                    Button("Show in Finder") { model.revealDataFolder() }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct EngineSettings: View {
    @Environment(Preferences.self) private var prefs
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var prefs = prefs
        Form {
            Section {
                Picker("Engine", selection: $prefs.enginePreference) {
                    ForEach(EnginePreference.allCases) { Text($0.label).tag($0) }
                }
                .disabled(model.hasSession)
                Text("""
                    **Live** keeps one channel open to the iPhone, so moves are instant and routes, \
                    pause/resume and the joystick run smoothly. **Classic** starts a new pymobiledevice3 \
                    process for every move — slower, but works with any pymobiledevice3. **Automatic** \
                    uses Live when it's available.
                    """)
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("Status") {
                    HStack {
                        switch model.engineStatus {
                        case .checking:
                            ProgressView().controlSize(.small)
                            Text("Checking…")
                        case .live(let version):
                            Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                            Text("Live available (\(version))")
                        case .classicOnly(let reason):
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            Text(reason).lineLimit(3).help(reason)
                        }
                        Button("Re-check") { model.startEngineProbe() }
                            .disabled(model.engineStatus == .checking)
                    }
                }
            }
            Section("Tunnel (iOS 17+)") {
                Picker("Transport", selection: $prefs.transport) {
                    ForEach(Transport.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .disabled(model.hasSession)
                Text(prefs.transport.detail).font(.caption).foregroundStyle(.secondary)
            }
            Section("pymobiledevice3") {
                LabeledContent("Location") {
                    Text(model.pmd?.displayPath ?? "Not found")
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                LabeledContent("Version") {
                    Text(model.pymobiledevice3Version ?? "—")
                }
                HStack {
                    Button(model.pmd == nil ? "Install" : "Update") { HelperInstaller.shared.install() }
                        .disabled(HelperInstaller.shared.isWorking)
                        .help("Install or update pymobiledevice3 in the app's own Python environment")
                    if HelperInstaller.shared.isWorking { ProgressView().controlSize(.small) }
                    Button("Choose…") { model.choosePymobiledevice3() }
                    if !prefs.pymobiledevice3Path.isEmpty {
                        Button("Use Automatic") {
                            prefs.pymobiledevice3Path = ""
                            model.resolveTool()
                        }
                    }
                }
                .disabled(model.hasSession)
            }
        }
        .formStyle(.grouped)
    }
}

private struct MovementSettings: View {
    @Environment(Preferences.self) private var prefs
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var prefs = prefs
        Form {
            Section {
                LabeledContent("Update rate") {
                    HStack {
                        Slider(value: $prefs.updateInterval, in: 0.2...2, step: 0.1)
                        Text(String(format: "%.1f s", prefs.updateInterval)).monospacedDigit().frame(width: 44)
                    }
                }
                Text("How often a moving device gets a new position (live engine).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Realistic trips") {
                Toggle("Drive like a real person", isOn: $prefs.realisticTrips)
                Group {
                    Toggle("Stop at some red lights", isOn: $prefs.tripTrafficLights)
                    Toggle("Stop at stop signs, slow at yield signs", isOn: $prefs.tripStopSigns)
                    Toggle("Slow down for turns, curves and speed bumps", isOn: $prefs.tripSlowForTurns)
                    Toggle("Keep to each road's speed limit", isOn: $prefs.tripSpeedLimits)
                    Toggle("Take breaks: every 2 hours when driving, short pauses on foot", isOn: $prefs.tripBreaks)
                    Toggle("Drive slower in rush hour, free overnight (time of day)", isOn: $prefs.tripTimeOfDayTraffic)
                }
                .padding(.leading, 18)
                .disabled(!prefs.realisticTrips)
                Text("""
                    Routes speed up and brake gradually, and wait at the stops you choose. Traffic lights, \
                    signs, speed bumps and speed limits come from OpenStreetMap. About half the lights are \
                    red, and most waits are under a minute. Your chosen speed becomes the top speed.
                    """)
                    .font(.caption).foregroundStyle(.secondary)
            }
            .onChange(of: [prefs.realisticTrips, prefs.tripTrafficLights, prefs.tripStopSigns,
                           prefs.tripSlowForTurns, prefs.tripSpeedLimits, prefs.tripBreaks,
                           prefs.tripTimeOfDayTraffic]) { _, _ in
                model.tripPreferencesChanged()
            }
            Section("Realism") {
                LabeledContent("Speed variation") {
                    HStack {
                        Slider(value: $prefs.speedVariation, in: 0...0.3, step: 0.05)
                        Text("±\(Int(prefs.speedVariation * 100))%").monospacedDigit().frame(width: 44)
                    }
                }
                LabeledContent("GPS wobble") {
                    HStack {
                        Slider(value: $prefs.positionJitter, in: 0...15, step: 1)
                        Text(prefs.positionJitter == 0 ? "Off" : "\(Int(prefs.positionJitter)) m").monospacedDigit().frame(width: 44)
                    }
                }
                Text("Speed variation adds slow changes in speed. GPS wobble makes the reported position wander a few meters from the true one, slowly, like a real phone's GPS, even while standing still.")
                    .font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Section("Defaults") {
                LabeledContent("Route speed") {
                    SpeedField(metresPerSecond: $prefs.defaultRouteSpeed, units: prefs.units)
                }
                .onChange(of: prefs.defaultRouteSpeed) { _, speed in
                    // Use it for the route being planned too (not one that's playing).
                    if model.activity != .routing { model.routeSpeed = speed }
                }
                LabeledContent("Joystick top speed") {
                    SpeedField(metresPerSecond: $prefs.joystickSpeed, units: prefs.units)
                }
            }
            Section {
                Button("Restore All Defaults", role: .destructive) { prefs.resetAll() }
            }
        }
        .formStyle(.grouped)
    }
}

private struct RemoteSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var host = RemoteHost.shared
        Form {
            Section {
                Toggle("Let the SpoofRemote iPhone app control this Mac", isOn: $host.isEnabled)
                Text("""
                    Start, move and stop the simulated location from your iPhone, without touching \
                    the Mac. The iPhone finds this Mac over Bonjour on your Wi-Fi or its own Personal \
                    Hotspot, and only paired iPhones can send commands. Keep this Mac awake while you use it.
                    """)
                    .font(.caption).foregroundStyle(.secondary)
                LabeledContent("Status") {
                    HStack(spacing: 6) {
                        switch host.state {
                        case .off:
                            Image(systemName: "circle").foregroundStyle(.secondary)
                            Text("Off")
                        case .starting:
                            ProgressView().controlSize(.small)
                            Text("Starting…")
                        case .running:
                            PulsingDot(color: Brand.live, size: 7)
                            Text("Listening as “\(host.serverName)”")
                        case .failed(let message):
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                            Text(message).lineLimit(3).help(message)
                        }
                    }
                }
            }
            if host.state == .running || host.state == .starting {
                Section("Pair an iPhone") {
                    HStack(alignment: .center, spacing: 14) {
                        IconTile(symbol: "lock.shield.fill", colors: TileColors.brand, size: 34)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(host.pairingCode)
                                .font(.system(size: 26, weight: .semibold, design: .monospaced))
                                .contentTransition(.numericText())
                                .textSelection(.enabled)
                            Text("In SpoofRemote, pick “\(host.serverName)” and enter this code.")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("New Code") { withAnimation(.snappy) { host.newCode() } }
                    }
                    LabeledContent("If it isn't found automatically") {
                        VStack(alignment: .trailing, spacing: 2) {
                            if host.addresses.isEmpty {
                                Text("Not on a network").foregroundStyle(.secondary)
                            }
                            ForEach(host.addresses, id: \.self) { address in
                                Text("\(address.address):\(String(host.port))  ·  \(address.label)")
                                    .font(.caption.monospaced())
                                    .textSelection(.enabled)
                            }
                        }
                    }
                    .onAppear { host.refreshAddresses() }
                }
                Section("Paired iPhones") {
                    if host.clients.isEmpty {
                        Text("None yet.").foregroundStyle(.secondary)
                    }
                    ForEach(host.clients) { client in
                        HStack(spacing: 10) {
                            IconTile(symbol: "iphone", colors: TileColors.purple, size: 26)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(client.name)
                                Text(seenText(client))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Unpair", role: .destructive) { host.unpair(client) }
                        }
                    }
                }
            }
            Section("iPhone-only mode (beta)") {
                HStack(alignment: .center, spacing: 14) {
                    IconTile(symbol: "iphone.gen3.radiowaves.left.and.right", colors: TileColors.brand, size: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Use SpoofRemote with no Mac nearby")
                        Text("""
                            Save the plugged-in iPhone's pairing file and AirDrop it to that iPhone.                             SpoofRemote then changes the location by itself, even on cellular.
                            """)
                            .font(.caption).foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer()
                    Button("Save Pairing File…") { model.savePairingFile() }
                        .disabled(!model.canSavePairingFile)
                }
                if !model.canSavePairingFile {
                    Text("Plug in an iPhone with iOS 17.4 or later, unlock it and tap Trust.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
    }

    private func seenText(_ client: PairingManager.PairedClient) -> String {
        if let seen = client.lastSeen {
            return "Last seen " + seen.formatted(.relative(presentation: .named))
        }
        return "Paired " + client.pairedAt.formatted(date: .abbreviated, time: .shortened)
    }
}

private struct AboutSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: AppIconImage.shared)
                .resizable()
                .frame(width: 112, height: 112)
                .shadow(color: Brand.indigo.opacity(0.35), radius: 14, y: 6)
            VStack(spacing: 4) {
                Text("iOS GPS Spoofer").font(Brand.title(24))
                Text(versionLine)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            HStack(spacing: 8) {
                badge("Instant live engine", symbol: "bolt.fill", colors: TileColors.live)
                badge("Routes & joystick", symbol: "gamecontroller.fill", colors: TileColors.purple)
                badge("Nothing installed on iPhone", symbol: "checkmark.shield.fill", colors: TileColors.brand)
            }
            Text("""
                Uses Apple's developer location-simulation service — the same one as Xcode's \
                Simulate Location — through pymobiledevice3. The real location comes back the \
                moment you stop, quit, or restart the phone.
                """)
                .multilineTextAlignment(.center)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 420)
            HStack(spacing: 10) {
                Button("Setup Checklist") { model.showWelcome = true }
                    .buttonStyle(BrandButtonStyle(kind: .secondary, large: false))
                Button("Show Data Folder") { model.revealDataFolder() }
                    .buttonStyle(BrandButtonStyle(kind: .secondary, large: false))
                if Updater.shared.canUpdate {
                    Button(Updater.shared.updateAvailable ? "Update…" : "Check for Updates") {
                        if Updater.shared.updateAvailable {
                            Updater.shared.installUpdate()
                        } else {
                            Task { await Updater.shared.check(userInitiated: true) }
                        }
                    }
                    .buttonStyle(BrandButtonStyle(kind: Updater.shared.updateAvailable ? .primary : .secondary, large: false))
                    .disabled(Updater.shared.state == .checking || Updater.shared.state == .updating)
                }
            }
            Text("For developing and testing location-aware apps on devices you own.")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .padding(28)
        .frame(maxWidth: .infinity)
    }

    private var versionLine: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "development build"
        if let commit = Updater.shared.commit {
            return "Version \(version) (\(commit.prefix(7)))"
        }
        return "Version \(version)"
    }

    private func badge(_ text: String, symbol: String, colors: [Color]) -> some View {
        HStack(spacing: 6) {
            IconTile(symbol: symbol, colors: colors, size: 18)
            Text(text).font(.caption.weight(.medium))
        }
        .padding(.leading, 4)
        .padding(.trailing, 9)
        .padding(.vertical, 4)
        .background(Color.primary.opacity(0.05), in: Capsule())
    }
}
