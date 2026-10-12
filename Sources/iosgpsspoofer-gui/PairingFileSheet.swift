import AppKit
import SpooferCore
import SwiftUI

/// File ▸ Pairing File for the iPhone App…
///
/// Makes the file AnyWhere on the iPhone needs for its iPhone-only mode, and then does not let
/// the person lose it: it says what is missing when it can't be made, saves to the Desktop,
/// shows where it went, sends it with AirDrop, and says what to tap on the iPhone.
struct PairingFileSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            // Once the file exists the question "can it be made?" is answered.
            if !isReady { readiness }
            content
            Divider()
            footer
        }
        .padding(24)
        .frame(width: 540)
        .animation(.easeOut(duration: 0.2), value: model.pairingFileState)
    }

    // MARK: - Pieces

    private var isReady: Bool {
        if case .ready = model.pairingFileState { return true }
        return false
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            IconTile(symbol: "key.fill", colors: TileColors.brand, size: 40)
            VStack(alignment: .leading, spacing: 4) {
                Text("Pairing file for the iPhone app").font(Brand.title(20))
                Text("""
                    AnyWhere on your iPhone needs one file from this Mac, once. It proves to the iPhone \
                    that the app is a computer it trusts. Keep it private: whoever has it can act as this Mac.
                    """)
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var readiness: some View {
        let state = model.pairingReadiness
        return HStack(alignment: .top, spacing: 10) {
            IconTile(symbol: state.isReady ? "checkmark" : "exclamationmark",
                     colors: state.isReady ? TileColors.live : TileColors.orange, size: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(state.title).font(.system(size: 13, weight: .semibold))
                Text(state.instruction).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            if case .noDevice = state {
                Button("Connection help") { model.showConnectionHelp = true }
                    .buttonStyle(BrandButtonStyle(kind: .secondary, large: false))
                    .fixedSize()
            }
        }
        .padding(14)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.06)))
    }

    @ViewBuilder
    private var content: some View {
        switch model.pairingFileState {
        case .idle:
            VStack(alignment: .leading, spacing: 10) {
                Button {
                    model.createPairingFile()
                } label: {
                    Label("Create Pairing File", systemImage: "key.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(BrandButtonStyle(kind: .primary))
                .disabled(!model.pairingReadiness.isReady)
                .keyboardShortcut(.defaultAction)
                Text("It is saved on your Desktop. Keep the iPhone plugged in and unlocked.")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Making it also turns on “Show this iPhone when on Wi-Fi” for this iPhone. You can turn that off later in Finder.")
                    .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        case .working:
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Making the file… keep the iPhone plugged in and unlocked.").font(.callout)
            }
        case .ready(let result):
            ready(result)
        case .failed(let message):
            VStack(alignment: .leading, spacing: 10) {
                Label(message.prefix(1).uppercased() + message.dropFirst(), systemImage: "exclamationmark.triangle.fill")
                    .font(.callout).foregroundStyle(Brand.warning)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try Again") { model.createPairingFile() }
                    .buttonStyle(BrandButtonStyle(kind: .primary, large: false))
                    .disabled(!model.pairingReadiness.isReady)
            }
        }
    }

    private func ready(_ result: PairingFileResult) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            // Where it is: the thing people could not find.
            HStack(spacing: 10) {
                Image(nsImage: NSWorkspace.shared.icon(forFile: result.url.path))
                    .resizable().frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 2) {
                    Label("Pairing file created", systemImage: "checkmark.circle.fill")
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(Brand.live)
                    Text(result.url.lastPathComponent).font(.caption)
                        .lineLimit(2).truncationMode(.middle)
                        .textSelection(.enabled)
                    Text("In the folder “\(result.url.deletingLastPathComponent().lastPathComponent)” on this Mac")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button("Show in Finder") { model.revealPairingFile() }
                    .buttonStyle(BrandButtonStyle(kind: .secondary, large: false))
                    .fixedSize()
            }
            .padding(12)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(Color.primary.opacity(0.06)))

            if let problem = result.olderIOSOnly {
                Label("""
                    This file works on older iOS only. The part newer iOS versions need could not be added: \(problem)
                    """, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption).foregroundStyle(Brand.warning)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Button {
                model.sharePairingFile()
            } label: {
                Label("Send to \(result.deviceName) with AirDrop", systemImage: "airplayaudio")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(BrandButtonStyle(kind: .primary))
            .keyboardShortcut(.defaultAction)

            VStack(alignment: .leading, spacing: 8) {
                Text("Then, on \(result.deviceName)").font(.system(size: 12, weight: .semibold))
                step(1, "Tap **Accept** when AirDrop asks.")
                step(2, "Pick **AnyWhere** in the list that appears. If you pick Save to Files instead, open AnyWhere, tap **This iPhone**, tap **Choose File** and pick it from Downloads.")
                step(3, "AnyWhere shows a green tick next to “Pairing file added”.")
            }
            Text("AirDrop needs Wi-Fi and Bluetooth on for both. If it doesn't show your iPhone, click Show in Finder and send the file another way.")
                .font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func step(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("\(number)")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(.white)
                .frame(width: 18, height: 18)
                .background(Brand.accent, in: Circle())
            Text(text).font(.callout).fixedSize(horizontal: false, vertical: true)
        }
    }

    private var footer: some View {
        HStack {
            if case .ready = model.pairingFileState {
                Button("Remove File from This Mac", role: .destructive) { model.removePairingFileFromMac() }
                    .buttonStyle(BrandButtonStyle(kind: .secondary, large: false))
                    .help("Delete the file after it has been sent. The iPhone keeps its own copy.")
            } else if case .idle = model.pairingFileState, model.pairingReadiness.isReady {
                Button("Save Somewhere Else…") { model.createPairingFile(chooseLocation: true) }
                    .buttonStyle(BrandButtonStyle(kind: .secondary, large: false))
            }
            Spacer()
            Button("Done") { dismiss() }
                .buttonStyle(BrandButtonStyle(kind: .secondary, large: false))
                .keyboardShortcut(.cancelAction)
        }
    }
}
