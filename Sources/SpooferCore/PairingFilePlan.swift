import Foundation

/// What the pairing-file assistant needs before it can make the file, said in words a person
/// can act on. The old menu item just went grey, so nobody could tell why or where it went.
public enum PairingFileReadiness: Equatable, Sendable {
    case ready(deviceName: String)
    case helperMissing
    case noDevice
    /// Plugged in, but the person hasn't tapped Trust on the iPhone yet.
    case needsTrust(deviceName: String)
    case iosTooOld(deviceName: String, version: String)

    public static func evaluate(helperAvailable: Bool, device: Device?) -> PairingFileReadiness {
        guard helperAvailable else { return .helperMissing }
        guard let device else { return .noDevice }
        guard device.isTrusted else { return .needsTrust(deviceName: device.deviceName) }
        guard device.majorVersion >= 17 else {
            return .iosTooOld(deviceName: device.deviceName, version: device.productVersion)
        }
        return .ready(deviceName: device.deviceName)
    }

    public var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    /// One line: how things stand.
    public var title: String {
        switch self {
        case .ready(let name): return "\(name) is ready"
        case .helperMissing: return "The iPhone helper isn't installed"
        case .noDevice: return "No iPhone is connected"
        case .needsTrust(let name): return "\(name) hasn't been trusted yet"
        case .iosTooOld(let name, let version): return "\(name) has iOS \(version)"
        }
    }

    /// What to do about it.
    public var instruction: String {
        switch self {
        case .ready:
            return "Click Create Pairing File."
        case .helperMissing:
            return "Open the setup checklist (Help ▸ Welcome & Setup Checklist) and click Install next to “Helper tool installed”."
        case .noDevice:
            return "Plug your iPhone into this Mac with a USB cable, unlock it, and tap Trust if it asks."
        case .needsTrust:
            return "Unlock the iPhone and tap Trust when it asks “Trust This Computer?”, then enter its passcode."
        case .iosTooOld:
            return "This needs iOS 17 or later. Update the iPhone in Settings ▸ General ▸ Software Update."
        }
    }
}

/// Where the pairing file is saved, and what it is called. It goes to the Desktop on purpose:
/// the file used to land wherever the save panel last was, and people could not find it.
public enum PairingFileLocation {
    public static let fileExtension = "mobiledevicepairing"

    /// "AnyWhere Pairing File – Sam's iPhone.mobiledevicepairing". Characters that are not
    /// allowed in a file name become dashes; an empty name becomes "iPhone".
    public static func fileName(forDevice name: String) -> String {
        let forbidden = CharacterSet(charactersIn: "/\\:").union(.controlCharacters).union(.newlines)
        var cleaned = name.unicodeScalars.map { forbidden.contains($0) ? "-" : String($0) }.joined()
        cleaned = cleaned.trimmingCharacters(in: .whitespaces)
        while cleaned.hasPrefix(".") { cleaned.removeFirst() }   // not a hidden file
        if cleaned.isEmpty { cleaned = "iPhone" }
        if cleaned.count > 60 { cleaned = String(cleaned.prefix(60)).trimmingCharacters(in: .whitespaces) }
        return "AnyWhere Pairing File – \(cleaned).\(fileExtension)"
    }

    /// The Desktop (the place people look); Downloads if there is no Desktop, then the
    /// temporary folder as a last resort. `ANYWHERE_PAIRING_DIR` overrides it, for tests,
    /// demos and CI, so they never write to a real Desktop.
    public static func defaultDirectory(fileManager fm: FileManager = .default,
                                        environment: [String: String] = ProcessInfo.processInfo.environment) -> URL {
        if let override = environment["ANYWHERE_PAIRING_DIR"], !override.isEmpty {
            let url = URL(fileURLWithPath: override, isDirectory: true)
            try? fm.createDirectory(at: url, withIntermediateDirectories: true)
            return url
        }
        for directory in [FileManager.SearchPathDirectory.desktopDirectory, .downloadsDirectory] {
            if let url = fm.urls(for: directory, in: .userDomainMask).first, fm.fileExists(atPath: url.path) {
                return url
            }
        }
        return fm.temporaryDirectory
    }

    public static func defaultURL(forDevice name: String, fileManager fm: FileManager = .default) -> URL {
        defaultDirectory(fileManager: fm).appendingPathComponent(fileName(forDevice: name))
    }
}
