import AppKit
import SpooferCore
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings()
                .tabItem { Label("General", systemImage: "gearshape") }
            EngineSettings()
                .tabItem { Label("Engine", systemImage: "bolt.horizontal") }
            MovementSettings()
                .tabItem { Label("Movement", systemImage: "figure.walk.motion") }
            AboutSettings()
                .tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 520)
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
            Toggle("Keep the moving device on screen", isOn: $prefs.followDevice)
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
                Text("Small random changes make routes look less robotic to apps that inspect movement.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Defaults") {
                LabeledContent("Route speed") {
                    SpeedField(metresPerSecond: $prefs.defaultRouteSpeed, units: prefs.units)
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

private struct AboutSettings: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "location.circle.fill")
                .font(.system(size: 54))
                .foregroundStyle(Color.accentColor.gradient)
            Text("iOS GPS Spoofer").font(.title2.bold())
            Text("Version \(Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "development")")
                .foregroundStyle(.secondary)
            Text("""
                Uses Apple's developer location-simulation service — the same one as Xcode's \
                Simulate Location — through pymobiledevice3. Nothing is installed on the iPhone, and \
                the real location comes back when you stop, quit, or reboot the phone.
                """)
                .multilineTextAlignment(.center)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: 400)
            Text("For developing and testing location-aware apps on devices you own.")
                .font(.caption).foregroundStyle(.tertiary)
        }
        .padding(24)
        .frame(maxWidth: .infinity)
    }
}
