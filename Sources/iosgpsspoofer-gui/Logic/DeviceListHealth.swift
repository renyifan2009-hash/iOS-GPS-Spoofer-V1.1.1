import Foundation

/// Whether the helper tool can list iPhones at all. A single failed scan happens (a cable
/// wobble, a busy Mac). Two in a row, with the helper installed, means the helper itself is
/// the problem, and the person should hear that instead of "plug in your iPhone".
struct DeviceListHealth: Equatable {
    /// Scans in a row that must fail before the helper is blamed.
    static let threshold = 2

    private(set) var failures = 0
    private(set) var lastError: String?

    mutating func succeeded() {
        failures = 0
        lastError = nil
    }

    /// Returns true for the one failure that crosses the line, so it is logged once and not
    /// every few seconds.
    @discardableResult
    mutating func failed(_ message: String) -> Bool {
        failures += 1
        lastError = message
        return failures == Self.threshold
    }

    var isFailing: Bool { failures >= Self.threshold }

    /// The first line of what went wrong, once it is clear the helper is at fault.
    var error: String? { isFailing ? lastError : nil }
}

/// What the Devices list in the sidebar shows when it has no iPhone to show.
enum SidebarEmptyState: Equatable {
    case helperMissing
    case searching
    case listFailed(String)
    case noIPhone

    static func resolve(helperInstalled: Bool, hasLookedOnce: Bool, listError: String?) -> SidebarEmptyState {
        // Without the helper nothing was ever looked for: no spinner, and no "plug it in".
        if !helperInstalled { return .helperMissing }
        if let listError { return .listFailed(listError) }
        return hasLookedOnce ? .noIPhone : .searching
    }
}
