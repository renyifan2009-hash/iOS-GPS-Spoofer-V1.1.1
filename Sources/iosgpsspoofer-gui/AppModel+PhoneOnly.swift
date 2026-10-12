import AppKit
import PhoneOnlyCore
import SpooferCore
import UniformTypeIdentifiers

/// Where the pairing-file assistant is.
enum PairingFileState: Equatable {
    case idle
    case working
    case ready(PairingFileResult)
    case failed(String)
}

struct PairingFileResult: Equatable {
    let url: URL
    let deviceName: String
    /// Set when the file lacks the part newer iOS versions need: why. It still works on older iOS.
    let olderIOSOnly: String?
}

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
        /// Whether a pairing file can be made right now, and if not, why.
    var pairingReadiness: PairingFileReadiness {
        PairingFileReadiness.evaluate(helperAvailable: pmd != nil, device: selectedDevice)
    }

    /// Kept for callers that only need a yes or no.
    var canSavePairingFile: Bool { pairingReadiness.isReady }

    private static let lastPairingFileKey = "lastPairingFilePath"
    private static let lastPairingFileDeviceKey = "lastPairingFileDevice"

    /// Open the assistant. If a file made earlier is still on this Mac, show it again, so
    /// "where did it go?" always has an answer.
    func openPairingFileAssistant() {
        if case .idle = pairingFileState, let remembered = rememberedPairingFile() {
            pairingFileState = .ready(remembered)
        }
        showPairingFile = true
    }

    private func rememberedPairingFile() -> PairingFileResult? {
        let defaults = UserDefaults.standard
        guard let path = defaults.string(forKey: Self.lastPairingFileKey),
              FileManager.default.fileExists(atPath: path) else {
            defaults.removeObject(forKey: Self.lastPairingFileKey)
            return nil
        }
        return PairingFileResult(url: URL(fileURLWithPath: path),
                                 deviceName: defaults.string(forKey: Self.lastPairingFileDeviceKey) ?? "your iPhone",
                                 olderIOSOnly: nil)
    }

    /// Make the selected iPhone's pairing file. It goes to the Desktop unless `chooseLocation`
    /// asks for a save panel. The file should hold two identities; if the one newer iOS
    /// versions need couldn't be made, the result says so instead of passing off a file that
    /// won't work.
    func createPairingFile(chooseLocation: Bool = false) {
        guard case .ready = pairingReadiness, let pmd, let device = selectedDevice else { return }
        if case .working = pairingFileState { return }

        var destination = PairingFileLocation.defaultURL(forDevice: device.deviceName)
        if chooseLocation {
            let panel = NSSavePanel()
            panel.title = "Save Pairing File"
            panel.message = "This file lets AnyWhere on \(device.deviceName) act as this Mac, so send it to no one else."
            panel.nameFieldStringValue = destination.lastPathComponent
            panel.directoryURL = destination.deletingLastPathComponent()
            panel.allowedContentTypes = [UTType(filenameExtension: PairingFileLocation.fileExtension) ?? .data]
            panel.canCreateDirectories = true
            guard panel.runModal() == .OK, let url = panel.url else { return }
            destination = url
        }

        let udid = device.udid
        let name = device.deviceName
        let target = destination
        pairingFileState = .working
        appendLog("Making the pairing file for \(name)…", level: .info)
        Task.detached(priority: .userInitiated) {
            // Sendable results only: what failed, or what the file is missing.
            let failure: String?
            let remotePairingProblem: String?
            do {
                remotePairingProblem = try pmd.exportPairingFile(udid: udid, to: target).remotePairingProblem
                failure = nil
            } catch {
                failure = SpoofSession.firstLine(of: error)
                remotePairingProblem = nil
            }
            await MainActor.run {
                let model = AppModel.shared
                if let failure {
                    model.pairingFileState = .failed(failure)
                    model.appendLog("Couldn't make the pairing file: \(failure)", level: .error)
                    return
                }
                let defaults = UserDefaults.standard
                defaults.set(target.path, forKey: Self.lastPairingFileKey)
                defaults.set(name, forKey: Self.lastPairingFileDeviceKey)
                model.pairingFileState = .ready(PairingFileResult(url: target, deviceName: name, olderIOSOnly: remotePairingProblem))
                if let remotePairingProblem {
                    // Still worth sending: it works where the iPhone answers lockdown through LocalDevVPN.
                    model.appendLog("Saved \(target.lastPathComponent) without the part newer iOS versions need, "
                        + "so it only works on older iOS. Reason: \(remotePairingProblem)", level: .warning)
                } else {
                    model.appendLog("Saved \(target.lastPathComponent) in \(target.deletingLastPathComponent().lastPathComponent).",
                                    level: .success)
                }
                // The iPhone is plugged in now: a good moment to check its AnyWhere app, so an
                // old one is caught before it's AirDropped a file it can't use.
                model.checkSpoofRemoteVersion()
            }
        }
    }

    /// Send the file to the iPhone with AirDrop; Finder, selected, if AirDrop isn't available.
    func sharePairingFile() {
        guard case .ready(let result) = pairingFileState else { return }
        if let airDrop = NSSharingService(named: .sendViaAirDrop), airDrop.canPerform(withItems: [result.url]) {
            airDrop.perform(withItems: [result.url])
        } else {
            NSWorkspace.shared.activateFileViewerSelecting([result.url])
            showToast(Toast(symbol: "exclamationmark.triangle.fill", title: "AirDrop isn't available",
                            subtitle: "The file is selected in Finder. Send it to the iPhone another way.", style: .warning), duration: 6)
        }
    }

    func revealPairingFile() {
        guard case .ready(let result) = pairingFileState else { return }
        NSWorkspace.shared.activateFileViewerSelecting([result.url])
    }

    /// The file is a key to the iPhone: once it has been sent, it should not stay on the Mac.
    func removePairingFileFromMac() {
        guard case .ready(let result) = pairingFileState else { return }
        try? FileManager.default.removeItem(at: result.url)
        UserDefaults.standard.removeObject(forKey: Self.lastPairingFileKey)
        UserDefaults.standard.removeObject(forKey: Self.lastPairingFileDeviceKey)
        pairingFileState = .idle
        appendLog("Removed \(result.url.lastPathComponent) from this Mac.", level: .info)
        showToast(Toast(symbol: "trash.fill", title: "Removed from this Mac",
                        subtitle: "The iPhone keeps its own copy.", style: .success))
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
                    model.appendLog("Couldn't check the AnyWhere app's version on \(name): \(failure)", level: .debug)
                    return
                }
                if let version, version < SpoofRemote.expected {
                    model.oldSpoofRemote = OldSpoofRemote(deviceName: name, installed: version.displayString)
                    model.appendLog("\(name) has an older AnyWhere app (\(version.displayString)). The newest is on the "
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
