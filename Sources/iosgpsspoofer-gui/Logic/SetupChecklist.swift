import Foundation

/// One line of the setup checklist (welcome sheet, connect card).
struct SetupCheck: Identifiable, Equatable {
    enum State: Equatable {
        case ok, pending, warning, failed
        /// Not done yet, and nothing for the person to do: it happens by itself later.
        case later
    }
    /// A button on the row that fixes the problem.
    enum Fix: Equatable {
        case installHelper
        case revealDeveloperMode
        case connectionHelp

        var label: String {
            switch self {
            case .installHelper: return "Install"
            // The switch is hidden in the iPhone's Settings until the Mac asks for it.
            case .revealDeveloperMode: return "Show the Switch"
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

/// Where Apple's developer support (the disk image every location tool needs) stands on the
/// selected iPhone. It is loaded by the first Start, needs the internet once, and the iPhone must
/// be unlocked. The app learns how it went from what the session reports.
enum DeveloperSupportState: Equatable {
    case later, settingUp, ready, trouble

    /// - Parameters:
    ///   - connecting: the message while the session is connecting, if it is.
    ///   - reconnecting: the message while the session is trying again, if it is.
    ///   - ready: a session has already got going on this iPhone during this run.
    static func resolve(connecting: String?, reconnecting: String?, ready: Bool) -> DeveloperSupportState {
        if let reconnecting, SessionWording.isDeveloperSupportTrouble(reconnecting) { return .trouble }
        if let connecting, SessionWording.isSettingUpDeveloperSupport(connecting) { return .settingUp }
        return ready ? .ready : .later
    }
}

/// Plain-English versions of what the session says while it works.
enum SessionWording {
    static let settingUpDeveloperSupport =
        "Setting up Apple's developer support on the iPhone. Needs the internet once. Keep the iPhone unlocked."

    /// The session's own "Mounting the developer disk image…" is a name for the same thing.
    static func isSettingUpDeveloperSupport(_ message: String) -> Bool {
        message.lowercased().contains("developer disk image")
    }

    /// The retry advice for a failed mount: "Couldn't load Apple's developer support …".
    static func isDeveloperSupportTrouble(_ message: String) -> Bool {
        message.lowercased().contains("developer support")
    }

    static func friendly(connecting message: String) -> String {
        isSettingUpDeveloperSupport(message) ? settingUpDeveloperSupport : message
    }
}

/// Everything the checklist shows, as plain values.
struct SetupInputs {
    struct IPhone: Equatable {
        var name: String
        var model: String
        var iOS: String
        var trusted: Bool
    }
    enum Engine: Equatable {
        case checking
        case live(version: String)
        case classicOnly
    }

    var helperInstalled: Bool
    var helperVersion: String?
    var iPhone: IPhone?
    var hasLookedForDevices: Bool
    /// The helper failed to list iPhones more than once in a row, with this first line of error.
    var deviceListError: String? = nil
    var developerMode: Bool?
    var developerSupport: DeveloperSupportState
    var engine: Engine
}

enum SetupChecklist {
    static let developerSupportID = "support"

    static func checks(_ i: SetupInputs) -> [SetupCheck] {
        [helperRow(i), deviceRow(i), developerModeRow(i), developerSupportRow(i), engineRow(i)]
    }

    /// The "All set" mark. A row that waits for the first use, and the classic engine (which
    /// works, just less smoothly), don't hold it back.
    static func isComplete(_ checks: [SetupCheck]) -> Bool {
        checks.allSatisfy { check in
            switch check.state {
            case .ok, .later: return true
            case .warning: return check.id == "engine"
            case .pending, .failed: return false
            }
        }
    }

    // MARK: Rows

    private static func helperRow(_ i: SetupInputs) -> SetupCheck {
        if i.helperInstalled {
            return SetupCheck(id: "tool", title: "Helper tool installed",
                              detail: "pymobiledevice3 \(i.helperVersion ?? "found")", state: .ok)
        }
        return SetupCheck(id: "tool", title: "Helper tool installed",
                          detail: "The helper tool isn't installed yet. Click Install. It takes about a minute.",
                          state: .failed, fix: .installHelper)
    }

    private static func deviceRow(_ i: SetupInputs) -> SetupCheck {
        let title = "iPhone connected & trusted"
        if let phone = i.iPhone {
            if !phone.trusted {
                return SetupCheck(id: "device", title: title,
                                  detail: "An iPhone is plugged in, but it hasn't been trusted yet. Unlock it and tap Trust, then enter its passcode.",
                                  state: .warning, fix: .connectionHelp)
            }
            return SetupCheck(id: "device", title: title,
                              detail: "\(phone.name) · \(phone.model) · iOS \(phone.iOS)", state: .ok)
        }
        if !i.helperInstalled {
            // Nothing can be looked for yet: not a spinner that never ends.
            return SetupCheck(id: "device", title: title,
                              detail: "Looks for your iPhone once the helper tool is installed.", state: .later)
        }
        if !i.hasLookedForDevices {
            return SetupCheck(id: "device", title: title, detail: "Looking for devices…", state: .pending)
        }
        if let error = i.deviceListError {
            return SetupCheck(id: "device", title: title,
                              detail: "The helper tool couldn't look for iPhones: \(error). Try installing it again.",
                              state: .failed, fix: .installHelper)
        }
        return SetupCheck(id: "device", title: title,
                          detail: "Plug it in with a data cable, unlock it and tap Trust.", state: .failed,
                          fix: .connectionHelp)
    }

    private static func developerModeRow(_ i: SetupInputs) -> SetupCheck {
        let title = "Developer Mode on"
        guard i.iPhone != nil else {
            // Nothing to check until an iPhone is there: not a spinner that never ends.
            return SetupCheck(id: "devmode", title: title, detail: "Checked once an iPhone is connected.", state: .later)
        }
        switch i.developerMode {
        case true?:
            return SetupCheck(id: "devmode", title: title, detail: "Enabled", state: .ok)
        case false?:
            return SetupCheck(id: "devmode", title: title,
                              detail: "Turn it on in the iPhone's Settings ▸ Privacy & Security ▸ Developer Mode. The iPhone restarts, then tap Turn On. Don't see the switch? Click Show the Switch.",
                              state: .failed, fix: .revealDeveloperMode)
        case nil:
            return SetupCheck(id: "devmode", title: title,
                              detail: "Couldn't check yet. It's checked again when you start.", state: .warning)
        }
    }

    private static func developerSupportRow(_ i: SetupInputs) -> SetupCheck {
        let title = "Apple's developer support"
        let id = developerSupportID
        switch i.developerSupport {
        case .later:
            return SetupCheck(id: id, title: title,
                              detail: "Set up by itself the first time you teleport. Needs the internet once. Keep the iPhone unlocked.",
                              state: .later)
        case .settingUp:
            return SetupCheck(id: id, title: title,
                              detail: "Setting up now. This can take a minute. Keep the iPhone unlocked.", state: .pending)
        case .ready:
            return SetupCheck(id: id, title: title, detail: "Ready on this iPhone", state: .ok)
        case .trouble:
            return SetupCheck(id: id, title: title,
                              detail: "Couldn't set it up yet. Check that this Mac is online and keep the iPhone unlocked. It tries again by itself.",
                              state: .warning, fix: .connectionHelp)
        }
    }

    private static func engineRow(_ i: SetupInputs) -> SetupCheck {
        let title = "Instant live engine"
        switch i.engine {
        case .checking:
            return SetupCheck(id: "engine", title: title, detail: "Checking…", state: .pending)
        case .live(let version):
            return SetupCheck(id: "engine", title: title,
                              detail: "Ready (pymobiledevice3 \(version)). Smooth routes and the joystick work.", state: .ok)
        case .classicOnly:
            return SetupCheck(id: "engine", title: title,
                              detail: "Not available here, so the classic engine is used. The joystick needs the live engine.",
                              state: .warning)
        }
    }
}
