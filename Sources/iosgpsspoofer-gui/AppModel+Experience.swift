import Foundation
import SpooferCore

/// One line of the setup checklist (welcome sheet, connect card).
struct SetupCheck: Identifiable, Equatable {
    enum State: Equatable { case ok, pending, warning, failed }
    let id: String
    let title: String
    let detail: String
    let state: State
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
                                     detail: "pymobiledevice3 wasn't found — install it or choose it in Settings.",
                                     state: .failed))
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
                                     detail: "Plug it in with a data cable, unlock it and tap Trust.", state: .failed))
        }

        switch (selectedDevice, developerModeEnabled) {
        case (nil, _):
            checks.append(SetupCheck(id: "devmode", title: "Developer Mode on",
                                     detail: "Checked once an iPhone is connected.", state: .pending))
        case (_, true?):
            checks.append(SetupCheck(id: "devmode", title: "Developer Mode on", detail: "Enabled", state: .ok))
        case (_, false?):
            checks.append(SetupCheck(id: "devmode", title: "Developer Mode on",
                                     detail: "Settings ▸ Privacy & Security ▸ Developer Mode, then restart the phone.",
                                     state: .failed))
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

    // MARK: - Developer Mode

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
}
