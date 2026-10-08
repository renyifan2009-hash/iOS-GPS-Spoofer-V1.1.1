import RemoteAPI
import SwiftUI

/// Find the Mac, enter the code it shows, done. Also shows the current
/// pairing and lets you connect by address when Bonjour can't see the Mac.
struct PairingView: View {
    @Environment(ConnectionManager.self) private var connection
    @Environment(\.dismiss) private var dismiss

    private enum Step: Equatable {
        case list
        case code(ConnectionManager.DiscoveredMac?)
        case manual
    }

    @State private var step: Step = .list
    @State private var code = ""
    @State private var host = ""
    @State private var port = String(RemoteAPI.defaultPort)
    @State private var shakes = 0
    @State private var paired = false

    var body: some View {
        NavigationStack {
            ZStack {
                AuroraBackground()
                ScrollView {
                    VStack(spacing: 22) {
                        header
                        Group {
                            switch step {
                            case .list:
                                macList
                            case .code(let mac):
                                codeEntry(for: mac)
                            case .manual:
                                manualEntry
                            }
                        }
                        .transition(.rise)
                        if let error = connection.lastError, !paired {
                            Label(error, systemImage: "exclamationmark.triangle.fill")
                                .font(.subheadline)
                                .padding(14)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .glassSurface(cornerRadius: 18, tint: Brand.warning)
                                .transition(.rise)
                        }
                        helpCard
                    }
                    .padding(20)
                    .animation(Brand.spring, value: step)
                    .animation(Brand.spring, value: connection.lastError)
                }
                .scrollDismissesKeyboard(.interactively)

                if paired {
                    successBadge
                        .transition(.scale(scale: 0.6).combined(with: .opacity))
                }
            }
            .environment(\.colorScheme, .dark)
            .navigationTitle("Your Mac")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if step == .list {
                        Button("Done") { dismiss() }
                    } else {
                        Button("Back") { withAnimation(Brand.spring) { step = .list; code = "" } }
                    }
                }
            }
            .sensoryFeedback(.error, trigger: shakes)
            .sensoryFeedback(.success, trigger: paired)
        }
        .onAppear {
            connection.lastError = nil
            connection.startBrowsing()
        }
    }

    // MARK: - Pieces

    private var header: some View {
        VStack(spacing: 10) {
            ZStack {
                Circle().fill(Brand.gradient).frame(width: 74, height: 74)
                    .shadow(color: Brand.indigo.opacity(0.6), radius: 20, y: 8)
                Image(systemName: "laptopcomputer.and.iphone")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.white)
                    .symbolEffect(.pulse, options: .repeating, isActive: step == .list && connection.discovered.isEmpty)
            }
            Text(title)
                .font(Brand.rounded(.title2))
                .multilineTextAlignment(.center)
                .contentTransition(.opacity)
            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
        }
        .foregroundStyle(.white)
        .padding(.top, 8)
    }

    private var title: String {
        switch step {
        case .list: return connection.isPaired ? "Connected Mac" : "Find your Mac"
        case .code(let mac): return "Enter the code from \(mac?.displayName ?? "your Mac")"
        case .manual: return "Connect by address"
        }
    }

    private var subtitle: String {
        switch step {
        case .list: return "Your Mac keeps the iPhone's simulated location alive. This app tells it where to go."
        case .code: return "Six digits, shown when the helper starts and in the Mac app under Settings ▸ iPhone Remote."
        case .manual: return "Use one of the addresses the Mac lists, e.g. 172.20.10.2 on your iPhone's hotspot."
        }
    }

    @ViewBuilder
    private var macList: some View {
        VStack(spacing: 12) {
            if let server = connection.server {
                currentServer(server)
            }
            ForEach(connection.discovered) { mac in
                Button {
                    connection.lastError = nil
                    withAnimation(Brand.spring) { step = .code(mac) }
                } label: {
                    HStack(spacing: 14) {
                        IconTile(symbol: "laptopcomputer", size: 42)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(mac.displayName).font(.headline)
                            Text(connection.isPaired(with: mac) ? "Paired · tap to pair again" : "Tap to pair")
                                .font(.subheadline).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    }
                    .padding(14)
                    .glassSurface(cornerRadius: 22, interactive: true)
                }
                .buttonStyle(.plain)
                .transition(.rise)
            }
            if connection.discovered.isEmpty {
                HStack(spacing: 12) {
                    ProgressView()
                    Text("Looking for Macs on this network…")
                        .font(.subheadline).foregroundStyle(.secondary)
                    Spacer()
                }
                .padding(16)
                .glassSurface(cornerRadius: 22)
            }
            Button {
                connection.lastError = nil
                withAnimation(Brand.spring) { step = .manual }
            } label: {
                Label("Enter an address instead", systemImage: "keyboard")
                    .frame(maxWidth: .infinity)
            }
            .glassButton()
        }
        .animation(Brand.spring, value: connection.discovered)
    }

    private func currentServer(_ server: ConnectionManager.Server) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 14) {
                IconTile(symbol: "checkmark.seal.fill", colors: [Color(red: 0.25, green: 0.86, blue: 0.62), Brand.live], size: 42)
                VStack(alignment: .leading, spacing: 2) {
                    Text(server.name).font(.headline)
                    Text("\(server.host):\(String(server.port))")
                        .font(.subheadline.monospaced()).foregroundStyle(.secondary)
                }
                Spacer()
                linkBadge
            }
            Button(role: .destructive) {
                Task { await connection.unpair() }
            } label: {
                Text("Unpair").frame(maxWidth: .infinity)
            }
            .glassButton()
        }
        .padding(16)
        .glassSurface(cornerRadius: 24)
    }

    @ViewBuilder
    private var linkBadge: some View {
        switch connection.link {
        case .online:
            Label("Online", systemImage: "circle.fill").font(.caption.weight(.semibold)).foregroundStyle(Brand.live)
        case .connecting:
            Label("Connecting", systemImage: "circle.dotted").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
        case .offline:
            Label("Offline", systemImage: "circle").font(.caption.weight(.semibold)).foregroundStyle(Brand.warning)
        case .unpaired:
            EmptyView()
        }
    }

    private func codeEntry(for mac: ConnectionManager.DiscoveredMac?) -> some View {
        VStack(spacing: 18) {
            CodeField(code: $code) { submit(mac: mac) }
                .keyframeAnimator(initialValue: 0.0, trigger: shakes) { content, offset in
                    content.offset(x: offset)
                } keyframes: { _ in
                    KeyframeTrack {
                        CubicKeyframe(-14, duration: 0.06)
                        CubicKeyframe(12, duration: 0.07)
                        CubicKeyframe(-8, duration: 0.07)
                        CubicKeyframe(5, duration: 0.07)
                        CubicKeyframe(0, duration: 0.08)
                    }
                }
            Button {
                submit(mac: mac)
            } label: {
                HStack(spacing: 8) {
                    if connection.isWorking { ProgressView().tint(.white) }
                    Text(connection.isWorking ? "Pairing…" : "Pair")
                }
                .frame(maxWidth: .infinity)
            }
            .prominentButton()
            .disabled(code.count < RemoteAPI.pairingCodeLength || connection.isWorking)
        }
    }

    private var manualEntry: some View {
        VStack(spacing: 14) {
            HStack(spacing: 10) {
                TextField("Mac address, e.g. 192.168.1.20", text: $host)
                    .keyboardType(.numbersAndPunctuation)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                TextField("Port", text: $port)
                    .keyboardType(.numberPad)
                    .frame(width: 70)
            }
            .padding(16)
            .glassSurface(cornerRadius: 20)
            CodeField(code: $code, autoFocus: false) { submit(mac: nil) }
                .keyframeAnimator(initialValue: 0.0, trigger: shakes) { content, offset in
                    content.offset(x: offset)
                } keyframes: { _ in
                    KeyframeTrack {
                        CubicKeyframe(-14, duration: 0.06)
                        CubicKeyframe(12, duration: 0.07)
                        CubicKeyframe(-8, duration: 0.07)
                        CubicKeyframe(0, duration: 0.1)
                    }
                }
            Button {
                submit(mac: nil)
            } label: {
                Text(connection.isWorking ? "Connecting…" : "Connect & Pair").frame(maxWidth: .infinity)
            }
            .prominentButton()
            .disabled(host.trimmingCharacters(in: .whitespaces).isEmpty
                      || code.count < RemoteAPI.pairingCodeLength || connection.isWorking)
        }
    }

    private var helpCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("On your Mac", systemImage: "info.circle.fill")
                .font(.subheadline.weight(.semibold))
            Text("Run `iosgpsspoof serve` in Terminal, or open **iOS GPS Spoofer ▸ Settings ▸ iPhone Remote** and turn it on. Connect the iPhone to the Mac with a cable once and tap Trust.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .glassSurface(cornerRadius: 20)
        .foregroundStyle(.white)
    }

    private var successBadge: some View {
        VStack(spacing: 12) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64, weight: .semibold))
                .foregroundStyle(.white, Brand.live)
                .symbolEffect(.bounce, value: paired)
            Text("Paired").font(Brand.rounded(.title2))
        }
        .padding(32)
        .glassSurface(cornerRadius: 32)
    }

    private func submit(mac: ConnectionManager.DiscoveredMac?) {
        guard code.count == RemoteAPI.pairingCodeLength, !connection.isWorking else { return }
        Task {
            let ok: Bool
            if let mac {
                ok = await connection.pair(with: mac, code: code)
            } else {
                let address = host.trimmingCharacters(in: .whitespaces)
                ok = await connection.pair(host: address, port: UInt16(port) ?? RemoteAPI.defaultPort, code: code)
            }
            if ok {
                withAnimation(Brand.spring) { paired = true }
                try? await Task.sleep(for: .seconds(1.1))
                dismiss()
            } else {
                shakes += 1
                withAnimation(Brand.snappy) { code = "" }
            }
        }
    }
}

/// Six glass boxes over an invisible field (so the one-time-code keyboard
/// and paste both work).
struct CodeField: View {
    @Binding var code: String
    var autoFocus = true
    var onComplete: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        ZStack {
            TextField("", text: $code)
                .keyboardType(.numberPad)
                .textContentType(.oneTimeCode)
                .focused($focused)
                .opacity(0.02)
                .onChange(of: code) { _, newValue in
                    let digits = String(newValue.filter(\.isNumber).prefix(RemoteAPI.pairingCodeLength))
                    if digits != newValue {
                        code = digits      // onChange runs again with the cleaned value
                    } else if digits.count == RemoteAPI.pairingCodeLength {
                        onComplete()
                    }
                }
            HStack(spacing: 8) {
                ForEach(0..<RemoteAPI.pairingCodeLength, id: \.self) { index in
                    let character = digit(at: index)
                    let isNext = index == code.count && focused
                    Text(character ?? " ")
                        .font(.system(size: 28, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .frame(width: 44, height: 58)
                        .glassSurface(cornerRadius: 14, tint: isNext ? Brand.indigo : nil)
                        .overlay {
                            RoundedRectangle(cornerRadius: 14, style: .continuous)
                                .strokeBorder(isNext ? Brand.sky : .clear, lineWidth: 1.5)
                        }
                        .scaleEffect(isNext ? 1.06 : 1)
                        .contentTransition(.numericText())
                    if index == 2 {
                        Capsule().fill(.white.opacity(0.4)).frame(width: 10, height: 3)
                    }
                }
            }
            .animation(Brand.snappy, value: code)
            .contentShape(Rectangle())
            .onTapGesture { focused = true }
        }
        .onAppear { if autoFocus { focused = true } }
    }

    private func digit(at index: Int) -> String? {
        guard index < code.count else { return nil }
        return String(code[code.index(code.startIndex, offsetBy: index)])
    }
}
