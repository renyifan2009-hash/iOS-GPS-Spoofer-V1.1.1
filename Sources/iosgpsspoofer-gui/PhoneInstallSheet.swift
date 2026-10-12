import AppKit
import SpooferCore
import SwiftUI

/// File ▸ Install AnyWhere on iPhone…
struct PhoneInstallSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    private let installer = PhoneInstaller.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            phoneCard
            stepOne
            if case .ready(let downloaded) = installer.step { stepTwo(downloaded) }
            Divider()
            footer
        }
        .padding(24)
        .frame(width: 560)
        .animation(.easeOut(duration: 0.2), value: installer.step)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(nsImage: AppIconImage.shared).resizable().frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 4) {
                Text("Put AnyWhere on your iPhone").font(Brand.title(20))
                Text("Apple only lets an app run on an iPhone if it is signed with an Apple ID. AnyWhere gets you the app and checks it. A signing tool you choose does the signing, with your own Apple ID. AnyWhere never sees it.")
                    .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var phoneCard: some View {
        HStack(spacing: 10) {
            switch installer.onPhone {
            case .unknown:
                IconTile(symbol: "iphone.slash", colors: TileColors.gray, size: 24)
                Text("Plug in your iPhone to see whether it already has AnyWhere.").font(.callout).foregroundStyle(.secondary)
            case .checking:
                ProgressView().controlSize(.small).frame(width: 24, height: 24)
                Text("Looking at your iPhone…").font(.callout).foregroundStyle(.secondary)
            case .notInstalled:
                IconTile(symbol: "arrow.down.app", colors: TileColors.orange, size: 24)
                Text("AnyWhere isn't on \(model.selectedDevice?.deviceName ?? "your iPhone") yet.").font(.callout)
            case .installed(let version):
                IconTile(symbol: "checkmark", colors: TileColors.live, size: 24)
                Text("AnyWhere \(version) is on \(model.selectedDevice?.deviceName ?? "your iPhone").").font(.callout)
            case .unreadable:
                IconTile(symbol: "questionmark", colors: TileColors.gray, size: 24)
                Text("Couldn't read the apps on your iPhone. Unlock it and try again.").font(.callout).foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .padding(12)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }

    @ViewBuilder
    private var stepOne: some View {
        switch installer.step {
        case .idle, .failed:
            VStack(alignment: .leading, spacing: 10) {
                Button { installer.fetch() } label: {
                    Label("1. Get the iPhone app", systemImage: "arrow.down.circle.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(BrandButtonStyle(kind: .primary))
                if case .failed(let message) = installer.step {
                    Label(message, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption).foregroundStyle(Brand.warning).fixedSize(horizontal: false, vertical: true)
                }
            }
        case .downloading(let text):
            HStack(spacing: 10) { ProgressView().controlSize(.small); Text(text).font(.callout) }
        case .ready(let downloaded):
            HStack(spacing: 10) {
                IconTile(symbol: "checkmark", colors: TileColors.live, size: 22)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Got AnyWhere \(downloaded.info.version) (build \(downloaded.info.build))").font(.system(size: 13, weight: .semibold))
                    Text(downloaded.checksumVerified
                         ? "The checksum matches the release, and the app inside is AnyWhere. Saved in Downloads."
                         : "The app inside is AnyWhere. This release has no checksum file to check against. Saved in Downloads.")
                        .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                Button("Show in Finder") { installer.reveal(downloaded) }
                    .buttonStyle(BrandButtonStyle(kind: .secondary, large: false)).fixedSize()
            }
        }
    }

    private func stepTwo(_ downloaded: PhoneInstaller.Downloaded) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("2. Sign it and put it on the iPhone").font(.system(size: 13, weight: .semibold))
            if installer.sideloaders.isEmpty {
                Text("You need a signing tool. Sideloadly and AltStore are free, and both sign the app with your own Apple ID. Install one, then drag the file into it.")
                    .font(.callout).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Button("Get Sideloadly") { open("https://sideloadly.io") }
                        .buttonStyle(BrandButtonStyle(kind: .secondary, large: false))
                    Button("Get AltStore") { open("https://altstore.io") }
                        .buttonStyle(BrandButtonStyle(kind: .secondary, large: false))
                }
            } else {
                ForEach(installer.sideloaders, id: \.name) { tool in
                    Button { installer.open(downloaded, with: tool) } label: {
                        Label("Open in \(tool.name)", systemImage: "arrow.up.forward.app").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(BrandButtonStyle(kind: .primary))
                }
                Text("If the tool doesn't take the file, drag it in from Finder.").font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("After it's installed").font(.system(size: 12, weight: .semibold))
                Text("• On the iPhone, open Settings ▸ General ▸ VPN & Device Management and trust your Apple ID.")
                Text("• Turn on Developer Mode in Settings ▸ Privacy & Security.")
                Text("• A free Apple ID lets the app open for 7 days. Install it again from the same tool when it stops opening. A paid Apple Developer account lasts a year.")
            }
            .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack {
            Button("Make the Pairing File…") {
                dismiss()
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(450))
                    model.openPairingFileAssistant()
                }
            }
            .buttonStyle(BrandButtonStyle(kind: .secondary, large: false))
            Spacer()
            Button("Done") { dismiss() }
                .buttonStyle(BrandButtonStyle(kind: .secondary, large: false))
                .keyboardShortcut(.cancelAction)
        }
    }

    private func open(_ string: String) {
        if let url = URL(string: string) { NSWorkspace.shared.open(url) }
    }
}
