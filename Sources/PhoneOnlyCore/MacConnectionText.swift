import Foundation

/// What the iPhone app says when it can't reach the Mac, and how it tells
/// that iOS is blocking it. iOS asks once for "Local Network" access the first
/// time an app looks for devices on the Wi-Fi. If the person tapped Don't
/// Allow, every attempt fails, and the failure looks just like a Mac that is
/// switched off. So the messages point at the setting.
public enum MacConnectionText {
    /// Where to turn Local Network back on.
    public static let localNetworkSetting = "Settings ▸ Privacy & Security ▸ Local Network"

    /// Added to the failures that Local Network being off can cause.
    public static let localNetworkHint = "If it still fails, allow Local Network for AnyWhere in \(localNetworkSetting)."

    /// `kDNSServiceErr_PolicyDenied` from dns_sd.h. When the person has said
    /// no to Local Network, the search for Macs waits with this error.
    public static let dnsPolicyDenied: Int32 = -65570

    public static func isLocalNetworkDenied(dnsErrorCode: Int32) -> Bool {
        dnsErrorCode == dnsPolicyDenied
    }

    /// The card shown in place of "Looking for Macs…" once the search can't
    /// run, with the setting it points at.
    public static let blockedTitle = "Allow Local Network"
    public static let blockedBody = "AnyWhere can't look for your Mac. Turn on Local Network for AnyWhere in "
        + "\(localNetworkSetting). Also check that Wi-Fi is on."

    /// The words for a network error while talking to the Mac, or nil when the
    /// system's own words will do.
    public static func message(forURLError code: URLError.Code) -> String? {
        switch code {
        case .cannotConnectToHost, .cannotFindHost, .timedOut, .networkConnectionLost,
             .notConnectedToInternet, .dnsLookupFailed:
            return "Can't reach the Mac. Check that it is awake with iPhone Remote turned on, "
                + "and that both are on the same network. \(localNetworkHint)"
        default:
            return nil
        }
    }

    /// Said when the Mac no longer accepts this iPhone's pairing and the
    /// Mac's own words aren't usable.
    public static let unpairedNotice = "The Mac no longer knows this iPhone, so it was unpaired. "
        + "Pair again with the code shown on the Mac."

    /// The notice for a 401 from the Mac. The Mac's own sentence says which
    /// Mac and what to do, so it is used when it came from the Mac. The
    /// stand-in the app makes when the Mac sent nothing readable
    /// ("The Mac answered with error 401.") is replaced.
    public static func unpairedNotice(fromServerMessage message: String?) -> String {
        guard let message = message?.trimmingCharacters(in: .whitespacesAndNewlines), !message.isEmpty,
              !message.hasPrefix("The Mac answered with error") else { return unpairedNotice }
        return message
    }
}
