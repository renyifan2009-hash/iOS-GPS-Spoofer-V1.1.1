import Foundation
import XCTest
@testable import PhoneOnlyCore

final class PairingInputTests: XCTestCase {
    // MARK: - The code

    func testPlainDigitsPassThrough() {
        XCTAssertEqual(PairingInput.code(from: "482913", length: 6), "482913")
        XCTAssertEqual(PairingInput.code(from: "48", length: 6), "48")
        XCTAssertEqual(PairingInput.code(from: "", length: 6), "")
    }

    func testSeparatorsAndLettersAreDropped() {
        XCTAssertEqual(PairingInput.code(from: "482 913", length: 6), "482913")
        XCTAssertEqual(PairingInput.code(from: "482-913", length: 6), "482913")
        XCTAssertEqual(PairingInput.code(from: "Code: 4a8b2c", length: 6), "482")
    }

    func testTooManyDigitsAreCutAtTheLength() {
        XCTAssertEqual(PairingInput.code(from: "48291377", length: 6), "482913")
    }

    /// The Mac's code is ASCII. A keyboard with Arabic-Indic digits must
    /// still produce a code that matches it, not one that never will.
    func testDigitsFromOtherScriptsBecomeAscii() {
        XCTAssertEqual(PairingInput.code(from: "٤٨٢٩١٣", length: 6), "482913")         // Arabic-Indic
        XCTAssertEqual(PairingInput.code(from: "۴۸۲۹۱۳", length: 6), "482913")         // Persian
        XCTAssertEqual(PairingInput.code(from: "４８２９１３", length: 6), "482913")      // full-width
    }

    func testSuperscriptsFractionsAndCircledNumbersAreNotDigits() {
        XCTAssertEqual(PairingInput.code(from: "²½①", length: 6), "")
        XCTAssertEqual(PairingInput.code(from: "4²8½2①", length: 6), "482")
    }

    func testEveryCharacterOfTheResultIsAnAsciiDigit() {
        let mixed = PairingInput.code(from: "٤8٢９1۳", length: 6)
        XCTAssertEqual(mixed, "482913")
        XCTAssertTrue(mixed.allSatisfy { $0.isASCII && $0.isNumber })
    }

    // MARK: - The address

    func testAddressWithDefaultPort() throws {
        let address = try PairingInput.address(host: " 192.168.1.20 ", port: "", defaultPort: 8421).get()
        XCTAssertEqual(address, PairingInput.Address(host: "192.168.1.20", port: 8421))
    }

    func testAddressWithPort() throws {
        let address = try PairingInput.address(host: "172.20.10.2", port: " 9000 ", defaultPort: 8421).get()
        XCTAssertEqual(address, PairingInput.Address(host: "172.20.10.2", port: 9000))
    }

    func testNoAddress() {
        XCTAssertEqual(PairingInput.address(host: "", port: "8421", defaultPort: 8421), .failure(.noAddress))
        XCTAssertEqual(PairingInput.address(host: "   ", port: "", defaultPort: 8421), .failure(.noAddress))
    }

    /// A port that doesn't parse used to be swapped for the usual one without a word.
    func testABadPortIsAnErrorNotTheDefault() {
        for port in ["abc", "99999", "65536", "0", "-1", "80.5", "８０", "٨٠"] {
            XCTAssertEqual(PairingInput.address(host: "10.0.0.2", port: port, defaultPort: 8421),
                           .failure(.badPort), "port \(port)")
        }
    }

    func testPortBoundaries() throws {
        XCTAssertEqual(try PairingInput.address(host: "h", port: "1", defaultPort: 8421).get().port, 1)
        XCTAssertEqual(try PairingInput.address(host: "h", port: "65535", defaultPort: 8421).get().port, 65535)
    }

    func testProblemsHavePlainMessages() {
        for problem in [PairingInput.AddressProblem.noAddress, .badPort] {
            let message = PairingInput.message(for: problem)
            XCTAssertFalse(message.isEmpty)
            XCTAssertFalse(message.contains(";"))
            XCTAssertFalse(message.contains("—"))
        }
    }
}
