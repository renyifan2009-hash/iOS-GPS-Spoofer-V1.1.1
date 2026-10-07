import AppKit
import SpooferCore
import SwiftUI

/// The menu-bar icon: filled while a location is being simulated.
struct MenuBarLabel: View {
    var body: some View {
        let model = AppModel.shared
        Image(systemName: model.session != nil ? "location.fill" : "location")
    }
}

/// Quick controls in the menu bar (window style).
struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(LibraryStore.self) private var library
    @Environment(Preferences.self) private var prefs
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("iOS GPS Spoofer").font(.headline)
                Spacer()
                StatusPill(status: model.statusDisplay)
            }

            if let device = model.activeDevice {
                Label("\(device.deviceName) · \(device.modelName)", systemImage: device.symbolName)
                    .font(.callout)
            } else {
                Label("No iPhone connected", systemImage: "iphone.slash").font(.callout).foregroundStyle(.secondary)
            }

            if model.session != nil {
                VStack(alignment: .leading, spacing: 3) {
                    Text(model.devicePlaceName ?? model.devicePosition.map { Format.coordinate($0) } ?? model.statusDisplay.detail)
                        .font(.callout.weight(.medium))
                        .lineLimit(2)
                    if let progress = model.routeProgress {
                        ProgressView(value: progress.fraction).controlSize(.small)
                        Text(progress.finished ? "Arrived" : "\(Format.distance(progress.remaining, units: prefs.units)) to go")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if model.deviceSpeed > 0.05 {
                        Text(Format.speed(model.deviceSpeed, units: prefs.units)).font(.caption).foregroundStyle(.secondary)
                    }
                }
                HStack {
                    if model.canPauseRoute {
                        Button(model.isPaused ? "Resume" : "Pause") { model.togglePause() }
                    }
                    Spacer()
                    Button(role: .destructive) {
                        model.stop()
                    } label: {
                        Label("Stop", systemImage: "stop.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.red)
                }
            }

            if !library.favorites.isEmpty {
                Divider()
                Text("Teleport to").font(.caption).foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(library.favorites.prefix(8)) { place in
                        Button {
                            model.mode = .teleport
                            model.useSavedPlace(place, teleportNow: true)
                        } label: {
                            Label(place.name, systemImage: "star.fill")
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 3)
                        .disabled(model.selectedDevice == nil && model.session == nil)
                    }
                }
            }

            Divider()
            HStack {
                Button("Open Window") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 300)
    }
}
