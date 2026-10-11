import AppKit
import PhoneOnlyCore
import SpooferCore
import UniformTypeIdentifiers

/// A connected iPhone with an older SpoofRemote than this code expects.
struct OldSpoofRemote: Equatable {
    let deviceName: String
    /// The version on the iPhone, for the log (e.g. "1.1 (2)").
    let installed: String
}

/// Setting up the iPhone-only mode: the SpoofRemote app on the iPhone changes
/// its own location, without a Mac, once it has the iPhone's pairing file.
/// See docs/PHONE-ONLY.md.
extension AppModel {
    /// Plugged in, trusted, and new enough (iOS 17.4) for the iPhone-only mode.
    var canSavePairingFile: Bool {
        guard pmd != nil, let device = selectedDevice else { return false }
        return device.supportsUserspaceTunnel
    }

    /// Save the selected iPhone's pairing file, then offer to AirDrop it. The
    /// file should hold two identities; if the one newer iOS versions need
    /// couldn't be made, say so instead of handing over a file that won't work.
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
            // Sendable results only: what failed, or what the file is missing.
            let failure: String?
            let remotePairingProblem: String?
            do {
                remotePairingProblem = try pmd.exportPairingFile(udid: udid, to: url).remotePairingProblem
                failure = nil
            } catch {
                failure = SpoofSession.firstLine(of: error)
                remotePairingProblem = nil
            }
            await MainActor.run {
                let model = AppModel.shared
                if let failure {
                    model.appendLog("Couldn't save the pairing file: \(failure)", level: .error)
                    model.showToast(Toast(symbol: "exclamationmark.triangle.fill", title: "Couldn't save the pairing file",
                                          subtitle: "Unlock the iPhone, tap Trust if asked, and try again.", style: .warning))
                    return
                }
                if let remotePairingProblem {
                    // Still worth sending: it works where the iPhone answers lockdown through LocalDevVPN.
                    model.appendLog("Saved \(url.lastPathComponent) without the part newer iOS versions need, "
                        + "so it only works on older iOS. Reason: \(remotePairingProblem)", level: .warning)
                    model.showToast(Toast(symbol: "exclamationmark.triangle.fill", title: "Saved, for older iOS only",
                                          subtitle: "The part newer iOS needs couldn't be added. Activity says why.",
                                          style: .warning), duration: 7)
                } else {
                    model.appendLog("Saved \(url.lastPathComponent). Open it on \(name) with SpoofRemote.", level: .success)
                }
                // AirDrop is the easy way across; Finder if it isn't available.
                if let airDrop = NSSharingService(named: .sendViaAirDrop), airDrop.canPerform(withItems: [url]) {
                    airDrop.perform(withItems: [url])
                } else {
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                }
                // The iPhone is plugged in now: a good moment to check its
                // SpoofRemote, so an old one is caught before it's AirDropped a
                // file it can't use.
                model.checkSpoofRemoteVersion()
            }
        }
    }

    /// Read which SpoofRemote is on the selected iPhone and, if it's older than
    /// this code expects, raise a banner that links to the releases page. Runs
    /// in the background and never blocks normal use: a SpoofRemote that isn't
    /// installed says nothing, and a failed read is logged and ignored. See
    /// docs/PHONE-ONLY.md.
    func checkSpoofRemoteVersion() {
        guard let pmd, let device = selectedDevice else { return }
        let udid = device.udid
        let name = device.deviceName
        spoofRemoteCheckedUDID = udid
        Task.detached(priority: .utility) {
            // Reduce to Sendable values before hopping to the main actor.
            let version: SpoofRemoteVersion?
            let failure: String?
            do {
                version = try pmd.installedSpoofRemoteVersion(udid: udid)
                failure = nil
            } catch {
                version = nil
                failure = SpoofSession.firstLine(of: error)
            }
            await MainActor.run {
                let model = AppModel.shared
                guard model.selectedUDID == udid else { return }
                if let failure {
                    // Stay quiet on screen; just note it for a bug report.
                    model.appendLog("Couldn't check the SpoofRemote version on \(name): \(failure)", level: .debug)
                    return
                }
                if let version, version < SpoofRemote.expected {
                    model.oldSpoofRemote = OldSpoofRemote(deviceName: name, installed: version.displayString)
                    model.appendLog("\(name) has an older SpoofRemote (\(version.displayString)). The newest is on the "
                        + "releases page. The iPhone-only mode can fail until it's updated.", level: .warning)
                } else {
                    // Current, or not installed: nothing to warn about.
                    model.oldSpoofRemote = nil
                }
            }
        }
    }

    /// Open the releases page, to update SpoofRemote on the iPhone.
    func openSpoofRemoteReleases() {
        guard let url = URL(string: SpoofRemote.releasesLatestURL) else { return }
        NSWorkspace.shared.open(url)
    }
}
