import AppKit
import Foundation
import Observation
import PhoneOnlyCore
import SpooferCore

/// "Install AnyWhere on iPhone…": gets the iPhone app, checks it is the real one, and hands it to
/// the signing tool the person already has. It never signs anything and never sees an Apple ID.
@MainActor
@Observable
final class PhoneInstaller {
    static let shared = PhoneInstaller()

    enum Step: Equatable {
        case idle
        case downloading(String)
        case ready(Downloaded)
        case failed(String)
    }

    struct Downloaded: Equatable {
        let url: URL
        let info: PhoneApp.Info
        /// True when the release's checksum file matched; false when the release had none to check against.
        let checksumVerified: Bool
    }

    /// What is on the connected iPhone.
    enum OnPhone: Equatable {
        case unknown
        case checking
        case notInstalled
        case installed(String)
        case unreadable
    }

    var isPresented = false
    var step: Step = .idle
    var onPhone: OnPhone = .unknown
    var sideloaders: [PhoneApp.Sideloader] = []

    private init() {}

    func open() {
        sideloaders = PhoneApp.installedSideloaders()
        if case .failed = step { step = .idle }
        isPresented = true
        refreshOnPhone()
    }

    /// Which AnyWhere is on the plugged-in iPhone, if any (the same read the update banner uses).
    func refreshOnPhone() {
        let model = AppModel.shared
        guard let pmd = model.pmd, let device = model.selectedDevice, device.isTrusted else {
            onPhone = .unknown
            return
        }
        onPhone = .checking
        let udid = device.udid
        Task.detached(priority: .utility) {
            let result: OnPhone
            do {
                if let version = try pmd.installedSpoofRemoteVersion(udid: udid) {
                    result = .installed(version.displayString)
                } else {
                    result = .notInstalled
                }
            } catch {
                result = .unreadable
            }
            await MainActor.run {
                // The iPhone may have been swapped while this ran.
                guard AppModel.shared.selectedUDID == udid else { return }
                PhoneInstaller.shared.onPhone = result
            }
        }
    }

    // MARK: - Getting the app

    /// Download the iPhone app from the newest release, check it, and keep it in Downloads.
    func fetch() {
        if case .downloading = step { return }
        step = .downloading("Downloading AnyWhere for the iPhone…")
        Task {
            do {
                let downloaded = try await Self.download()
                step = .ready(downloaded)
                AppModel.shared.appendLog("Downloaded \(downloaded.url.lastPathComponent) (\(downloaded.info.version), build \(downloaded.info.build)).",
                                          level: .success)
            } catch {
                let message = (error as? PhoneInstallError)?.description ?? SpoofSession.firstLine(of: error)
                step = .failed(message)
                AppModel.shared.appendLog("Couldn't get the iPhone app: \(message)", level: .warning)
            }
        }
    }

    nonisolated private static func download() async throws -> Downloaded {
        let checksums = await fetchChecksums()
        var lastError: Error = PhoneInstallError.noRelease
        for name in PhoneApp.assetNames {
            guard let url = PhoneApp.downloadURL(asset: name) else { continue }
            do {
                let (temporary, response) = try await URLSession.shared.download(from: url)
                defer { try? FileManager.default.removeItem(at: temporary) }
                guard let http = response as? HTTPURLResponse, http.statusCode == 200 else {
                    lastError = PhoneInstallError.noRelease
                    continue
                }
                var verified = false
                if let checksums, let expected = PhoneApp.expectedChecksum(for: name, inChecksumFile: checksums) {
                    let actual = try PhoneApp.sha256(ofFileAt: temporary)
                    guard actual == expected else { throw PhoneInstallError.checksumMismatch }
                    verified = true
                }
                let info = try PhoneApp.verify(ipa: temporary)
                let destination = try place(temporary, version: info.version)
                return Downloaded(url: destination, info: info, checksumVerified: verified)
            } catch let error as PhoneApp.Problem {
                throw PhoneInstallError.problem(error)
            } catch let error as PhoneInstallError {
                throw error
            } catch {
                lastError = error
            }
        }
        throw lastError
    }

    nonisolated private static func fetchChecksums() async -> String? {
        guard let url = PhoneApp.downloadURL(asset: PhoneApp.checksumsName),
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    /// Into Downloads, where people look, under a name that says what it is.
    nonisolated private static func place(_ temporary: URL, version: String) throws -> URL {
        let fm = FileManager.default
        let folder = fm.urls(for: .downloadsDirectory, in: .userDomainMask).first ?? fm.temporaryDirectory
        let safeVersion = version.filter { $0.isNumber || $0 == "." }
        let destination = folder.appendingPathComponent("AnyWhere\(safeVersion.isEmpty ? "" : " " + safeVersion).ipa")
        try? fm.removeItem(at: destination)
        try fm.copyItem(at: temporary, to: destination)
        return destination
    }

    // MARK: - Handing it on

    func reveal(_ downloaded: Downloaded) {
        NSWorkspace.shared.activateFileViewerSelecting([downloaded.url])
    }

    /// Open the file in the signing tool, which asks the person for their Apple ID itself.
    func open(_ downloaded: Downloaded, with sideloader: PhoneApp.Sideloader) {
        let configuration = NSWorkspace.OpenConfiguration()
        let url = downloaded.url
        let name = sideloader.name
        // The handler runs on a system queue, so it must not be main-actor isolated itself.
        NSWorkspace.shared.open([url], withApplicationAt: sideloader.appURL, configuration: configuration) { @Sendable _, error in
            guard error != nil else { return }
            // The tool didn't take the file: show it, so it can be dragged in.
            Task { @MainActor in
                NSWorkspace.shared.activateFileViewerSelecting([url])
                AppModel.shared.showToast(Toast(symbol: "arrow.up.doc", title: "Drag the file into \(name)",
                                                subtitle: "It's selected in Finder.", style: .info), duration: 6)
            }
        }
    }
}

enum PhoneInstallError: Error, CustomStringConvertible {
    case noRelease
    case checksumMismatch
    case problem(PhoneApp.Problem)

    var description: String {
        switch self {
        case .noRelease:
            return "There's no iPhone app on the newest release yet. Check the Releases page, or build it with Xcode (see docs/IPHONE-REMOTE.md)."
        case .checksumMismatch:
            return "The download doesn't match the release's checksum, so it was thrown away. Try again."
        case .problem(let problem):
            return problem.description
        }
    }
}
