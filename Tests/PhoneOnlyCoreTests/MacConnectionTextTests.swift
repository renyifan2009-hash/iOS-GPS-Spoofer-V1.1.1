import Foundation
import XCTest
@testable import PhoneOnlyCore

final class MacConnectionTextTests: XCTestCase {
    func testPolicyDeniedIsTheLocalNetworkError() {
        XCTAssertTrue(MacConnectionText.isLocalNetworkDenied(dnsErrorCode: -65570))
        XCTAssertFalse(MacConnectionText.isLocalNetworkDenied(dnsErrorCode: -65563))   // service not running
        XCTAssertFalse(MacConnectionText.isLocalNetworkDenied(dnsErrorCode: 0))
    }

    /// Every failure that Local Network being off can cause points at the setting.
    func testReachFailuresMentionLocalNetwork() throws {
        let codes: [URLError.Code] = [.cannotConnectToHost, .cannotFindHost, .timedOut, .networkConnectionLost,
                                      .notConnectedToInternet, .dnsLookupFailed]
        for code in codes {
            let message = try XCTUnwrap(MacConnectionText.message(forURLError: code), "\(code)")
            XCTAssertTrue(message.contains("Local Network"), "\(code): \(message)")
            XCTAssertTrue(message.contains("Settings ▸ Privacy & Security ▸ Local Network"), "\(code): \(message)")
            XCTAssertTrue(message.hasPrefix("Can't reach the Mac."))
        }
    }

    func testOtherErrorsKeepTheSystemsWords() {
        XCTAssertNil(MacConnectionText.message(forURLError: .badURL))
        XCTAssertNil(MacConnectionText.message(forURLError: .cancelled))
    }

    func testBlockedCardTellsWhereToGo() {
        XCTAssertTrue(MacConnectionText.blockedBody.contains("Settings ▸ Privacy & Security ▸ Local Network"))
        XCTAssertFalse(MacConnectionText.blockedTitle.isEmpty)
    }

    func testPlainCopyHasNoSemicolonsOrEmDashes() {
        let strings = [MacConnectionText.localNetworkHint, MacConnectionText.blockedTitle, MacConnectionText.blockedBody,
                       MacConnectionText.unpairedNotice,
                       MacConnectionText.message(forURLError: .timedOut) ?? ""]
        for string in strings {
            XCTAssertFalse(string.contains(";"), string)
            XCTAssertFalse(string.contains("—"), string)
        }
    }

    // MARK: - The 401 notice (iphone-app-03)

    func testTheMacsOwnSentenceIsKept() {
        let message = "This iPhone isn't paired with Studio Mac. Pair again with the code shown on the Mac."
        XCTAssertEqual(MacConnectionText.unpairedNotice(fromServerMessage: message), message)
    }

    func testAnUnreadableAnswerGetsTheStandInNotice() {
        for message in [nil, "", "  ", "The Mac answered with error 401."] {
            XCTAssertEqual(MacConnectionText.unpairedNotice(fromServerMessage: message), MacConnectionText.unpairedNotice,
                           "\(String(describing: message))")
        }
        XCTAssertTrue(MacConnectionText.unpairedNotice.contains("Pair again"))
    }
}
