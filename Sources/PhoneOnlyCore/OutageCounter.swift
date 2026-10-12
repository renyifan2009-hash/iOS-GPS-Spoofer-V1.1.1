import Foundation

/// Tells a Mac that has gone away from a request that was merely stopped.
///
/// The iPhone app asks the Mac for its status every few seconds. One failed
/// check can be a hiccup, so the app says "offline" only after two in a row.
/// A check that was cancelled is not a failure at all: the app cancels its
/// own checks when it goes to the background or when the Mac is unpaired.
/// Counting those as failures made the app say "Mac is offline" for a Mac
/// that was fine, or that was no longer paired.
public struct OutageCounter: Equatable, Sendable {
    /// How a request ended, as far as the Mac's health goes.
    public enum Outcome: Equatable, Sendable {
        /// The Mac answered, or the app didn't get to ask.
        case answered
        /// The request failed: no connection, no answer, a time-out.
        case failed
        /// The request was stopped on this side. Says nothing about the Mac.
        case cancelled

        /// For the error a request threw.
        public init(error: Error) {
            if error is CancellationError || (error as? URLError)?.code == .cancelled {
                self = .cancelled
            } else {
                self = .failed
            }
        }
    }

    /// Failed checks in a row.
    public private(set) var failures = 0

    /// Two in a row.
    public static let failuresBeforeOffline = 2

    public init() {}

    /// Count the outcome of a check. Returns whether it counted.
    @discardableResult
    public mutating func record(_ outcome: Outcome) -> Bool {
        switch outcome {
        case .answered:
            failures = 0
            return true
        case .failed:
            failures += 1
            return true
        case .cancelled:
            return false
        }
    }

    public mutating func reset() {
        failures = 0
    }

    public var isOffline: Bool { failures >= Self.failuresBeforeOffline }

    /// Whether to look for the Mac again, in case its address changed: on the
    /// second failure in a row and every fifth after that.
    public var shouldLookAgain: Bool {
        failures == Self.failuresBeforeOffline || (failures > 0 && failures % 5 == 0)
    }
}
