import AppKit
import Foundation
import SpooferCore

/// One line of the setup checklist (welcome sheet, connect card).
struct SetupCheck: Identifiable, Equatable {
    enum State: Equatable { case ok, pending, warning, failed }
    /// A button on the row that fixes the problem.
    enum Fix: Equatable {
        case installHelper
        case revealDeveloperMode
        case connectionHelp

        var label: String {
            switch self {
            case .installHelper: return "Install"
            case .revealDeveloperMode: return "Show on iPhone"
            case .connectionHelp: return "Help"
            }
        }
    }
    let id: String
    let title: String
    let detail: String
    let state: State
    var fix: Fix? = nil
}

extension AppModel {

    // MARK: - Toasts

    /// Show a transient confirmation over the map; the newest replaces any other.
    func showToast(_ toast: Toast, duration: TimeInterval = 2.8) {
        toastTask?.cancel()
        self.toast = toast
        let id = toast.id
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(duration * 1000)))
            guard !Task.isCancelled, let self, self.toast?.id == id else { return }
            self.toast = nil
        }
    }

    func teleportToast(_ point: GeoPoint, name: String?) -> Toast {
        Toast(symbol: "location.fill", title: "Teleported",
              subtitle: name ?? Format.coordinate(point), style: .success)
    }

    // MARK: - Welcome

    func finishWelcome() {
        showWelcome = false
        UserDefaults.standard.set(true, forKey: StateKey.welcomed)
    }

    /// Live checklist of everything needed to spoof.
    var setupChecks: [SetupCheck] {
        var checks: [SetupCheck] = []

        if pmd != nil {
            checks.append(SetupCheck(id: "tool", title: "Helper tool installed",
                                     detail: "pymobiledevice3 \(pymobiledevice3Version ?? "found")", state: .ok))
        } else {
            checks.append(SetupCheck(id: "tool", title: "Helper tool installed",
                                     detail: "pymobiledevice3 isn't installed yet. Click Install (about a minute).",
                                     state: .failed, fix: .installHelper))
        }

        if let device = selectedDevice {
            checks.append(SetupCheck(id: "device", title: "iPhone connected & trusted",
                                     detail: "\(device.deviceName) · \(device.modelName) · iOS \(device.productVersion)",
                                     state: .ok))
        } else if !hasRefreshedOnce || pmd == nil {
            checks.append(SetupCheck(id: "device", title: "iPhone connected & trusted",
                                     detail: "Looking for devices…", state: .pending))
        } else {
            checks.append(SetupCheck(id: "device", title: "iPhone connected & trusted",
                                     detail: "Plug it in with a data cable, unlock it and tap Trust.", state: .failed,
                                     fix: .connectionHelp))
        }

        switch (selectedDevice, developerModeEnabled) {
        case (nil, _):
            checks.append(SetupCheck(id: "devmode", title: "Developer Mode on",
                                     detail: "Checked once an iPhone is connected.", state: .pending))
        case (_, true?):
            checks.append(SetupCheck(id: "devmode", title: "Developer Mode on", detail: "Enabled", state: .ok))
        case (_, false?):
            checks.append(SetupCheck(id: "devmode", title: "Developer Mode on",
                                     detail: "On the iPhone: Settings ▸ Privacy & Security ▸ Developer Mode. It restarts; then tap Turn On.",
                                     state: .failed, fix: .revealDeveloperMode))
        case (_, nil):
            checks.append(SetupCheck(id: "devmode", title: "Developer Mode on",
                                     detail: "Couldn't check yet — it's verified when you start.", state: .warning))
        }

        switch engineStatus {
        case .checking:
            checks.append(SetupCheck(id: "engine", title: "Instant live engine",
                                     detail: "Checking…", state: .pending))
        case .live(let version):
            checks.append(SetupCheck(id: "engine", title: "Instant live engine",
                                     detail: "Ready (pymobiledevice3 \(version)) — smooth routes & joystick", state: .ok))
        case .classicOnly:
            checks.append(SetupCheck(id: "engine", title: "Instant live engine",
                                     detail: "Unavailable — using the compatible classic engine.", state: .warning))
        }
        return checks
    }

    var setupIsComplete: Bool {
        setupChecks.allSatisfy { $0.state == .ok }
    }

    func performFix(_ fix: SetupCheck.Fix) {
        switch fix {
        case .installHelper: HelperInstaller.shared.install()
        case .revealDeveloperMode: revealDeveloperMode()
        case .connectionHelp: showConnectionHelp = true
        }
    }

    // MARK: - Developer Mode

    /// The Developer Mode switch is hidden in the iPhone's Settings until a
    /// developer tool asks for it: ask. `automatic` does it once per iPhone,
    /// quietly, as soon as Developer Mode reads off.
    func revealDeveloperMode(automatic: Bool = false) {
        guard let pmd, let device = selectedDevice else { return }
        let udid = device.udid
        if automatic {
            guard !developerModeRevealed.contains(udid) else { return }
        }
        developerModeRevealed.insert(udid)
        Task.detached(priority: .utility) {
            let error: String? = {
                do {
                    _ = try pmd.run(["amfi", "reveal-developer-mode", "--udid", udid], timeout: 30)
                    return nil
                } catch {
                    return SpoofSession.firstLine(of: error)
                }
            }()
            await MainActor.run {
                let model = AppModel.shared
                if let error {
                    model.appendLog("Couldn't show the Developer Mode switch on the iPhone: \(error)", level: .warning)
                    if !automatic {
                        model.showToast(Toast(symbol: "exclamationmark.triangle.fill", title: "Couldn't reach the iPhone",
                                              subtitle: "Unlock it, tap Trust if asked, and try again.", style: .warning))
                    }
                    return
                }
                model.appendLog("The Developer Mode switch is now in the iPhone's Settings ▸ Privacy & Security.", level: .info)
                model.showToast(Toast(symbol: "hammer.fill", title: "Now turn on Developer Mode",
                                      subtitle: "On the iPhone: Settings ▸ Privacy & Security ▸ Developer Mode",
                                      style: .info), duration: 6)
            }
        }
    }

    /// Ask the selected device whether Developer Mode is on (runs in the background).
    func checkDeveloperMode() {
        guard let pmd, let device = selectedDevice else {
            developerModeEnabled = nil
            return
        }
        let udid = device.udid
        developerModeCheckedUDID = udid
        developerModeCheckedAt = Date()
        Task.detached(priority: .utility) {
            let output = try? pmd.run(["amfi", "developer-mode-status", "--udid", udid], timeout: 30)
            let value = output?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            let enabled: Bool? = value == "true" ? true : (value == "false" ? false : nil)
            await MainActor.run {
                let model = AppModel.shared
                guard model.selectedUDID == udid else { return }
                let was = model.developerModeEnabled
                model.developerModeEnabled = enabled
                if enabled == true, was == false {
                    model.appendLog("Developer Mode is on now.", level: .success)
                }
                if enabled == false { model.revealDeveloperMode(automatic: true) }
                if enabled == false, was != false {
                    model.appendLog("Developer Mode is off on this iPhone: Settings ▸ Privacy & Security ▸ Developer Mode.",
                                    level: .warning)
                }
            }
        }
    }

    /// No device yet, nothing running: show the big "connect" card.
    var shouldShowConnectCard: Bool {
        setupError == nil && hasRefreshedOnce && devices.isEmpty && session == nil && !connectCardDismissed
    }

    // MARK: - Diagnostics

    /// Everything a developer needs to help from afar: versions, setup, the
    /// iPhone, and the recent activity log (with pymobiledevice3's output).
    var diagnosticsReport: String {
        let info = Bundle.main.infoDictionary ?? [:]
        let version = info["CFBundleShortVersionString"] as? String ?? "development build"
        let commit = (info["SpooferGitCommit"] as? String).flatMap { $0.isEmpty ? nil : String($0.prefix(7)) } ?? "unknown"
        let built = info["SpooferBuildDate"] as? String ?? "unknown"
        #if arch(arm64)
        let chip = "Apple silicon"
        #else
        let chip = "Intel"
        #endif
        var lines = [
            "iOS GPS Spoofer \(version) (commit \(commit), built \(built))",
            "macOS \(ProcessInfo.processInfo.operatingSystemVersionString), \(chip)",
            "pymobiledevice3: \(pymobiledevice3Version ?? "unknown version") at \(pmd?.displayPath ?? "not found")",
        ]
        switch engineStatus {
        case .checking: lines.append("Live engine: still checking")
        case .live(let v): lines.append("Live engine: ready (\(v))")
        case .classicOnly(let reason): lines.append("Live engine: unavailable (\(reason))")
        }
        lines.append("Engine setting: \(prefs.enginePreference.label), tunnel setting: \(prefs.transport.label)")
        if let device = activeDevice {
            let devMode = developerModeEnabled.map { $0 ? "on" : "off" } ?? "unknown"
            let tunnel = device.isLegacy ? "lockdown service" : prefs.transport.resolved(for: device).label
            lines.append("iPhone: \(device.modelName) (\(device.productType)), iOS \(device.productVersion), "
                         + "\(device.isUSB ? "USB" : "Wi-Fi"), Developer Mode \(devMode), tunnel \(tunnel)")
        } else {
            lines.append("iPhone: none connected (\(devices.count) listed)")
        }
        lines.append("Session: \(session == nil ? "none" : "\(statusDisplay.title) (\(sessionEngine?.label ?? "?") engine)")")
        lines.append("")
        lines.append("Recent activity:")
        let time = DateFormatter()
        time.dateFormat = "HH:mm:ss"
        lines += log.suffix(150).map { "[\(time.string(from: $0.date))] \($0.text)" }
        return lines.joined(separator: "\n")
    }

    func copyDiagnostics() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(diagnosticsReport, forType: .string)
        showToast(Toast(symbol: "doc.on.clipboard.fill", title: "Diagnostics copied",
                        subtitle: "Paste them into a message to the developer.", style: .info), duration: 4)
    }
}
