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
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 10) {
                Image(nsImage: AppIconImage.shared)
                    .resizable()
                    .frame(width: 30, height: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text("iOS GPS Spoofer").font(Brand.title(14, weight: .semibold))
                    Text(model.activeDevice.map { "\($0.deviceName) · \($0.modelName)" } ?? "No iPhone connected")
                        .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
                Spacer()
                StatusPill(status: model.statusDisplay)
            }

            if model.session != nil {
                VStack(alignment: .leading, spacing: 8) {
                    HStack(spacing: 10) {
                        IconTile(symbol: model.statusDisplay.symbol, colors: TileColors.brand, size: 28)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(model.devicePlaceName ?? model.devicePosition.map { Format.coordinate($0) }
                                 ?? model.statusDisplay.detail)
                                .font(.system(size: 13, weight: .semibold))
                                .lineLimit(2)
                            if model.deviceSpeed > 0.05 {
                                Text(Format.speed(model.deviceSpeed, units: prefs.units))
                                    .font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    }
                    if let progress = model.routeProgress {
                        ScrubBar(fraction: progress.fraction, interactive: false)
                        Text(progress.finished ? "Arrived" : "\(Format.distance(progress.remaining, units: prefs.units)) to go")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    HStack {
                        if model.canPauseRoute {
                            Button(model.isPaused ? "Resume" : "Pause") { model.togglePause() }
                                .buttonStyle(BrandButtonStyle(kind: .secondary, large: false))
                        }
                        Spacer()
                        Button {
                            model.stop()
                        } label: {
                            Label("Stop", systemImage: "stop.fill")
                        }
                        .buttonStyle(BrandButtonStyle(kind: .danger, large: false))
                    }
                }
                .padding(12)
                .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            }

            if !library.favorites.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    SectionHeader("Teleport to", systemImage: "star.fill")
                    ForEach(library.favorites.prefix(8)) { place in
                        Button {
                            model.mode = .teleport
                            model.useSavedPlace(place, teleportNow: true)
                        } label: {
                            HStack(spacing: 8) {
                                IconTile(symbol: "star.fill", colors: TileColors.yellow, size: 20)
                                Text(place.name).lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 2)
                        .disabled(model.selectedDevice == nil && model.session == nil)
                    }
                }
            }

            Divider()
            HStack {
                Button("Open iOS GPS Spoofer") {
                    openWindow(id: "main")
                    NSApp.activate()
                }
                .buttonStyle(BrandButtonStyle(kind: .primary, large: false))
                Spacer()
                Button("Quit") { NSApp.terminate(nil) }
                    .buttonStyle(BrandButtonStyle(kind: .secondary, large: false))
            }
        }
        .padding(16)
        .frame(width: 320)
    }
}
