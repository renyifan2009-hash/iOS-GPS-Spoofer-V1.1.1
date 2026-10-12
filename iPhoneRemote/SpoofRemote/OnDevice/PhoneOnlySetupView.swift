import SwiftUI
import UniformTypeIdentifiers

/// Setting up the iPhone-only mode: what's needed, what's done, and how to
/// do the rest. Each step gets a tick once it's ready.
struct PhoneOnlySetupView: View {
    @Environment(OnDeviceController.self) private var phone
    @Environment(UpdateChecker.self) private var updates
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var importing = false
    @State private var confirmRemove = false

    /// LocalDevVPN on the App Store (the link its GitHub README gives).
    static let localDevVPN = URL(string: "https://apps.apple.com/app/localdevvpn/id6755608044")!

    var body: some View {
        NavigationStack {
            ZStack {
                AuroraBackground()
                ScrollView {
                    VStack(spacing: 16) {
                        header
                        UpdateNoticeView()
                        if !OnDeviceController.isSupported {
                            step(done: false, symbol: "iphone.slash", title: "Needs iOS 17.4 or later",
                                 detail: "This iPhone has iOS \(UIDevice.current.systemVersion). Update it in Settings ▸ General ▸ Software Update, or use your Mac instead.")
                        }
                        pairingStep
                        vpnStep
                        step(done: nil, symbol: "hammer.fill", title: "Developer Mode on",
                             detail: "Settings ▸ Privacy & Security ▸ Developer Mode. AnyWhere on your Mac helps you turn it on.")
                        step(done: nil, symbol: "arrow.clockwise", title: "After a restart",
                             detail: "When this iPhone restarts, connect it to your Mac once and open AnyWhere. It loads Apple's developer support again.")
                        if let error = phone.lastError {
                            VStack(alignment: .leading, spacing: 8) {
                                Label(error, systemImage: "exclamationmark.triangle.fill")
                                    .font(.subheadline)
                                if let detail = phone.lastErrorDetail {
                                    // For a bug report: which step failed, and how.
                                    Text(detail)
                                        .font(.caption2.monospaced())
                                        .foregroundStyle(.secondary)
                                        .fixedSize(horizontal: false, vertical: true)
                                        .textSelection(.enabled)
                                }
                            }
                            .padding(14)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .glassSurface(cornerRadius: 18, tint: Brand.warning)
                            .transition(.rise)
                        }
                        footnote
                    }
                    .padding(20)
                    .animation(Brand.spring, value: phone.isSetUp)
                    .animation(Brand.spring, value: phone.loopbackReachable)
                    .animation(Brand.spring, value: phone.pairingFileIsTooOld)
                    .animation(Brand.spring, value: phone.lastError)
                    .animation(Brand.spring, value: phone.importError)
                    .animation(Brand.spring, value: updates.updateAvailable)
                }
            }
            .navigationTitle("This iPhone")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: Self.pairingTypes) { result in
                switch result {
                case .success(let url): phone.importPairingFile(from: url)
                case .failure(let error): phone.reportImportFailure(error)
                }
            }
            .confirmationDialog("Remove the pairing file?", isPresented: $confirmRemove, titleVisibility: .visible) {
                Button("Remove", role: .destructive) { phone.removePairingFile() }
            } message: {
                Text("This iPhone goes back to its real location. To use this mode again, open a new pairing file from your Mac.")
            }
            .sensoryFeedback(.success, trigger: phone.isSetUp) { _, isSetUp in isSetUp }
            .sensoryFeedback(.error, trigger: phone.importFailures)
            .onChange(of: phone.importFailures) {
                // The message is in the pairing card, by the button. Say it aloud for VoiceOver.
                if let error = phone.importError { AccessibilityNotification.Announcement(error).post() }
            }
        }
        .environment(\.colorScheme, .dark)
        .task { await phone.checkLoopback() }
        .onChange(of: scenePhase) { _, phase in
            // Back from LocalDevVPN: see whether it's on now.
            if phase == .active { Task { await phone.checkLoopback() } }
        }
    }

    /// `.mobiledevicepairing` files, and plain plists for records saved by other tools.
    static var pairingTypes: [UTType] {
        [UTType(filenameExtension: "mobiledevicepairing") ?? .data, .propertyList, .xml, .data]
    }

    // MARK: - Pieces

    private var header: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle().fill(Brand.gradient).frame(width: 74, height: 74)
                    .shadow(color: Brand.indigo.opacity(0.6), radius: 20, y: 8)
                Image(systemName: "iphone.gen3.radiowaves.left.and.right")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.white)
            }
            Text("Use this iPhone on its own")
                .font(Brand.rounded(.title2))
                .multilineTextAlignment(.center)
            Text("Set it up once with your Mac. After that, change the location right here, on Wi-Fi or cellular.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(.white)
        .padding(.top, 8)
    }

    private var pairingStep: some View {
        // Added, but this iPhone's iOS only takes the newer kind of file.
        let tooOld = phone.pairingFileIsTooOld
        return step(done: phone.isSetUp && !tooOld, symbol: "key.fill", title: pairingTitle(tooOld: tooOld),
                    detail: pairingDetail(tooOld: tooOld)) {
            VStack(alignment: .leading, spacing: 10) {
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 8) { pairingButtons(tooOld: tooOld) }
                    VStack(alignment: .leading, spacing: 8) { pairingButtons(tooOld: tooOld) }
                }
                if let error = phone.importError {
                    // Right under the button that caused it, not at the bottom of the screen.
                    Label(error, systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(Brand.warning)
                        .fixedSize(horizontal: false, vertical: true)
                        .transition(.rise)
                }
            }
        }
    }

    private func pairingTitle(tooOld: Bool) -> String {
        if !phone.isSetUp { return "Add the pairing file" }
        return tooOld ? "This pairing file is too old" : "Pairing file added"
    }

    private func pairingDetail(tooOld: Bool) -> String {
        if !phone.isSetUp {
            return "On your Mac, plug this iPhone in and open AnyWhere. Choose File ▸ Pairing File for the iPhone App…, click Create Pairing File, then Send with AirDrop. Here, tap Accept and pick AnyWhere. If you saved it to Files instead, tap Choose File below and pick it from Downloads."
        }
        if tooOld {
            return "This iPhone's iOS needs a newer kind of pairing file. On your Mac, update AnyWhere, plug this iPhone in and choose File ▸ Pairing File for the iPhone App… again. Then AirDrop it here."
        }
        let held = "It's in this iPhone's Keychain. It lets this app talk to the iPhone like your Mac does."
        // Which file it is, so a file left from before a reinstall isn't a mystery.
        guard let source = phone.pairingSource else { return held }
        return "\(source.summary()). \(held)"
    }

    @ViewBuilder
    private func pairingButtons(tooOld: Bool) -> some View {
        if !phone.isSetUp || tooOld {
            Button {
                phone.clearImportError()
                importing = true
            } label: {
                Label("Choose File", systemImage: "folder")
                    .fixedSize()
            }
            .glassButton()
        }
        if phone.isSetUp {
            Button("Remove", role: .destructive) { confirmRemove = true }
                .glassButton()
        }
    }

    private var vpnStep: some View {
        let reachable = phone.loopbackReachable
        return step(done: phone.checkingLoopback ? nil : reachable,
                    symbol: "network.badge.shield.half.filled",
                    title: reachable == true ? "LocalDevVPN is on" : "Turn on LocalDevVPN",
                    detail: reachable == true
                        ? "It lets this app reach the iPhone's own developer services."
                        : "Get the free LocalDevVPN app, open it and tap Connect. It lets this app reach the iPhone's own developer services, and leaves your other traffic alone.") {
            // Side by side when they fit, one above the other when not.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { vpnButtons(reachable) }
                VStack(alignment: .leading, spacing: 8) { vpnButtons(reachable) }
            }
        }
    }

    @ViewBuilder
    private func vpnButtons(_ reachable: Bool?) -> some View {
        if reachable != true {
            Link(destination: Self.localDevVPN) {
                Label("Get LocalDevVPN", systemImage: "arrow.up.right.square")
                    .fixedSize()
            }
            .glassButton()
        }
        Button {
            Task { await phone.checkLoopback() }
        } label: {
            Group {
                if phone.checkingLoopback {
                    ProgressView().controlSize(.small)
                } else {
                    Label("Check", systemImage: "arrow.clockwise")
                }
            }
            .fixedSize()
        }
        .glassButton()
        .disabled(phone.checkingLoopback)
    }

    private var footnote: some View {
        Text("The location stays while AnyWhere runs; the blue pill in the status bar shows it's holding one. Stop, or restart the iPhone, to get the real location back. The pairing file never leaves this iPhone.")
            .font(.footnote)
            .foregroundStyle(.secondary)
            .multilineTextAlignment(.center)
            .padding(.horizontal, 8)
    }

    /// One step: a status mark, what it is, how to do it, and an optional button.
    private func step(done: Bool?, symbol: String, title: String, detail: String) -> some View {
        step(done: done, symbol: symbol, title: title, detail: detail) { EmptyView() }
    }

    private func step<Actions: View>(done: Bool?, symbol: String, title: String, detail: String,
                                     @ViewBuilder actions: () -> Actions) -> some View {
        HStack(alignment: .top, spacing: 14) {
            ZStack {
                Circle()
                    .fill(done == true ? AnyShapeStyle(Brand.live) : AnyShapeStyle(Color.white.opacity(0.12)))
                    .frame(width: 34, height: 34)
                Image(systemName: done == true ? "checkmark" : symbol)
                    .font(.system(size: 15, weight: .bold))
                    .foregroundStyle(done == false ? Brand.warning : .white)
                    .contentTransition(.symbolEffect(.replace))
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(title)
                    .font(Brand.rounded(.headline))
                    .contentTransition(.opacity)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                actions()
                    .font(.subheadline.weight(.semibold))
                    .padding(.top, 2)
            }
            Spacer(minLength: 0)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(cornerRadius: 22)
        .foregroundStyle(.white)
    }
}
