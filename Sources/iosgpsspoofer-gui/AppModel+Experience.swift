import AppKit
import Foundation
import SpooferCore

// `SetupCheck` and the checklist rules are in Logic/SetupChecklist.swift (unit tested).

extension AppModel {

    // MARK: - Toasts

    /// Show a transient confirmation over the map; the newest replaces any other.
    func showToast(_ toast: Toast, duration: TimeInterval = 2.8) {
        toastTask?.cancel()
        self.toast = toast
        // A note that fades by itself is gone before VoiceOver would reach it: say it out loud.
        NSAccessibility.post(element: NSApp as Any, notification: .announcementRequested,
                             userInfo: [.announcement: [toast.title, toast.subtitle].compactMap { $0 }.joined(separator: ". "),
                                        .priority: NSAccessibilityPriorityLevel.high.rawValue])
        let id = toast.id
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(Int(duration * 1000)))
            guard !Task.isCancelled, let self, self.toast?.id == id else { return }
            self.toast = nil
        }
    }

    func dismissToast() {
        toastTask?.cancel()
        toast = nil
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

    /// Live checklist of everything needed to spoof (the rows and their words are in
    /// Logic/SetupChecklist.swift).
    var setupChecks: [SetupCheck] {
        SetupChecklist.checks(setupInputs)
    }

    var setupInputs: SetupInputs {
        let phone = selectedDevice.map {
            SetupInputs.IPhone(name: $0.deviceName, model: $0.modelName, iOS: $0.productVersion, trusted: $0.isTrusted)
        }
        let engine: SetupInputs.Engine
        switch engineStatus {
        case .checking: engine = .checking
        case .live(let version): engine = .live(version: version)
        case .classicOnly: engine = .classicOnly
        }
        return SetupInputs(helperInstalled: pmd != nil, helperVersion: pymobiledevice3Version, iPhone: phone,
                           hasLookedForDevices: hasRefreshedOnce, deviceListError: deviceListError,
                           developerMode: developerModeEnabled,
                           developerSupport: developerSupportState, engine: engine)
    }

    /// What the sidebar's Devices list says when it has no iPhone.
    var sidebarEmptyState: SidebarEmptyState {
        .resolve(helperInstalled: pmd != nil, hasLookedOnce: hasRefreshedOnce, listError: deviceListError)
    }

    var setupIsComplete: Bool {
        SetupChecklist.isComplete(setupChecks)
    }

    /// How Apple's developer support stands on the selected iPhone, from what the session says.
    var developerSupportState: DeveloperSupportState {
        var connecting: String?
        var reconnecting: String?
        switch sessionState {
        case .connecting(let message): connecting = message
        case .reconnecting(let message): reconnecting = message
        default: break
        }
        let ready = selectedUDID.map { developerSupportReady.contains($0) } ?? false
        return .resolve(connecting: connecting, reconnecting: reconnecting, ready: ready)
    }

    func performFix(_ fix: SetupCheck.Fix) {
        switch fix {
        case .installHelper: HelperInstaller.shared.install()
        case .revealDeveloperMode: revealDeveloperMode()
        case .connectionHelp:
            // A sheet can't open on top of the Welcome sheet: close that first.
            if showWelcome {
                showWelcome = false
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(450))
                    AppModel.shared.showConnectionHelp = true
                }
            } else {
                showConnectionHelp = true
            }
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
            "AnyWhere \(version) (commit \(commit), built \(built))",
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
