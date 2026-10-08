import AppKit
import SpooferCore
import UniformTypeIdentifiers

/// Setting up the iPhone-only mode: the SpoofRemote app on the iPhone changes
/// its own location, without a Mac, once it has the iPhone's pairing file.
/// See docs/PHONE-ONLY.md.
extension AppModel {
    /// Plugged in, trusted, and new enough (iOS 17.4) for the iPhone-only mode.
    var canSavePairingFile: Bool {
        guard pmd != nil, let device = selectedDevice else { return false }
        return device.supportsUserspaceTunnel
    }

    /// Save the selected iPhone's pairing file, then offer to AirDrop it.
    func savePairingFile() {
        guard let pmd, let device = selectedDevice else { return }
        guard device.supportsUserspaceTunnel else {
            appendLog("The iPhone-only mode needs iOS 17.4 or later. \(device.deviceName) has iOS \(device.productVersion).",
                      level: .warning)
            return
        }
        let panel = NSSavePanel()
        panel.title = "Save iPhone Pairing File"
        panel.message = """
            Send this file to \(device.deviceName) and open it with SpoofRemote. \
            It lets SpoofRemote act as this Mac towards that iPhone, so send it to no one else.
            """
        panel.nameFieldStringValue = "\(device.deviceName.replacingOccurrences(of: "/", with: "-")).mobiledevicepairing"
        panel.allowedContentTypes = [UTType(filenameExtension: "mobiledevicepairing") ?? .data]
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let udid = device.udid
        let name = device.deviceName
        appendLog("Saving the pairing file for \(name)…", level: .info)
        Task.detached(priority: .userInitiated) {
            let error: String? = {
                do {
                    try pmd.exportPairingFile(udid: udid, to: url)
                    return nil
                } catch {
                    return SpoofSession.firstLine(of: error)
                }
            }()
            await MainActor.run {
                let model = AppModel.shared
                if let error {
                    model.appendLog("Couldn't save the pairing file: \(error)", level: .error)
                    model.showToast(Toast(symbol: "exclamationmark.triangle.fill", title: "Couldn't save the pairing file",
                                          subtitle: "Unlock the iPhone, tap Trust if asked, and try again.", style: .warning))
                    return
                }
                model.appendLog("Saved \(url.lastPathComponent). Open it on \(name) with SpoofRemote.", level: .success)
                // AirDrop is the easy way across; Finder if it isn't available.
                if let airDrop = NSSharingService(named: .sendViaAirDrop), airDrop.canPerform(withItems: [url]) {
                    airDrop.perform(withItems: [url])
                } else {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
            }
        }
    }
}
