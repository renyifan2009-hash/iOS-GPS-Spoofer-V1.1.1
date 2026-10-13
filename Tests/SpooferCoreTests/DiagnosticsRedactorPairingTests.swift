import PhoneOnlyCore
import XCTest
@testable import SpooferCore

/// A pairing record is the most sensitive thing this project handles: whoever holds one can act as the
/// Mac the iPhone trusts. `Copy Diagnostics` and the app log must never carry one, in any of the shapes a
/// log line or a pasted file can give it. These tests build made-up records (the bytes below are
/// generated from a formula, not taken from any device) in the shapes the app and its tools print,
/// and check that nothing secret survives while the field names stay, so a report still says
/// what was in the file.
final class DiagnosticsRedactorPairingTests: XCTestCase {
    private func redact(_ s: String) -> String { DiagnosticsRedactor.redact(s) }

    // MARK: Fake records

    /// The same count and seed always give the same stand-in "key"; none of it is a real one.
    private func bytes(_ count: Int, seed: Int) -> Data {
        var out = Data()
        for index in 0..<count {
            let value: Int = (index * 53 + seed * 31 + 7) % 251
            out.append(UInt8(value))
        }
        return out
    }

    /// Bytes as Python prints them: \x0c\xc8...
    private func hexEscapes(_ data: Data) -> String {
        var out = ""
        for byte in data { out += String(format: "\\x%02x", Int(byte)) }
        return out
    }

    /// Bytes as the decimal numbers Rust prints in a Vec<u8>.
    private func decimals(_ data: Data) -> [String] {
        var out: [String] = []
        for byte in data { out.append(String(Int(byte))) }
        return out
    }

    /// Text shaped like a PEM block: a header, base64 lines of 64, a footer.
    private func pem(_ label: String, bodyBytes: Int, seed: Int) -> Data {
        let body = bytes(bodyBytes, seed: seed).base64EncodedString(options: [.lineLength64Characters, .endLineWithLineFeed])
        return Data("-----BEGIN \(label)-----\n\(body)\n-----END \(label)-----\n".utf8)
    }

    private static let hostID = "3F9C2B7E-5A41-4D8E-9B6A-0C1D2E3F4A5B"
    private static let systemBUID = "8E2D4C6A-1B3F-4A5C-8D7E-9F0A1B2C3D4E"
    private static let wifiMAC = "a4:5e:60:c1:22:9b"
    private static let identifier = "5B7A9C1E-2D3F-4E6A-8B0C-1D2E3F4A5B6C"

    /// The binary fields of a record, by their names: a lockdown record (certificates and keys the iPhone
    /// gave the Mac when it was trusted) and a Remote Pairing identity (an Ed25519 key and the name the iPhone
    /// knows it by). `public` is the one part that is not a secret.
    private var secretData: [String: Data] {
        var fields: [String: Data] = [:]
        fields["DeviceCertificate"] = pem("CERTIFICATE", bodyBytes: 700, seed: 1)
        fields["HostCertificate"] = pem("CERTIFICATE", bodyBytes: 700, seed: 2)
        fields["HostPrivateKey"] = pem("RSA PRIVATE KEY", bodyBytes: 1190, seed: 3)
        fields["RootCertificate"] = pem("CERTIFICATE", bodyBytes: 700, seed: 4)
        fields["RootPrivateKey"] = pem("RSA PRIVATE KEY", bodyBytes: 1190, seed: 5)
        fields["EscrowBag"] = bytes(190, seed: 6)
        fields["private_key"] = bytes(32, seed: 8)     // 44 characters in base64: shorter than any "long blob" rule
        fields["alt_irk"] = bytes(16, seed: 9)         // 24 characters
        return fields
    }

    private var publicKey: Data { bytes(32, seed: 7) }

    /// Strings that name the Mac or the iPhone.
    private var identifiers: [String: String] {
        var fields: [String: String] = [:]
        fields["HostID"] = Self.hostID
        fields["SystemBUID"] = Self.systemBUID
        fields["WiFiMACAddress"] = Self.wifiMAC
        fields["identifier"] = Self.identifier
        return fields
    }

    private func fakeRecordPlist() throws -> String {
        var dictionary: [String: Any] = secretData
        dictionary["public_key"] = publicKey
        for (key, value) in identifiers { dictionary[key] = value }
        let data = try PropertyListSerialization.data(fromPropertyList: dictionary, format: .xml, options: 0)
        // The fixture has to be shaped like the real thing, or the tests below would prove nothing.
        let record = try PairingRecord(data: data)
        XCTAssertTrue(record.hasLockdownRecord, "the fake record should look like a lockdown record")
        XCTAssertNotNil(record.remotePairing, "and carry a Remote Pairing identity")
        return String(decoding: data, as: UTF8.self)
    }

    /// Fails if a stretch of this value's base64 text is still in the output, wherever it was line-wrapped.
    private func assertNoTrace(of data: Data, named name: String, in output: String,
                               file: StaticString = #filePath, line: UInt = #line) {
        let text = data.base64EncodedString()
        let squeezed = output.filter { !$0.isWhitespace }
        let window = 16
        var start = text.startIndex
        while let end = text.index(start, offsetBy: window, limitedBy: text.endIndex) {
            let piece = String(text[start..<end])
            if squeezed.contains(piece) {
                XCTFail("\(name) is still in the output: \"\(piece)\"", file: file, line: line)
                return
            }
            start = text.index(start, offsetBy: 4)
        }
    }

    private func assertNoIdentifiers(in output: String, file: StaticString = #filePath, line: UInt = #line) {
        for (name, value) in identifiers {
            XCTAssertFalse(output.contains(value), "\(name) is still in the output", file: file, line: line)
        }
    }

    // MARK: A record pasted or dumped as it is

    func testAWholePairingFileIsHiddenButItsFieldNamesStay() throws {
        let plist = try fakeRecordPlist()
        let report = "iPhone: iPhone 16 Pro Max, iOS 26.6\n\(plist)\nSession: Live (live engine)"
        let out = redact(report)

        for (name, value) in secretData { assertNoTrace(of: value, named: name, in: out) }
        assertNoTrace(of: publicKey, named: "public_key", in: out)   // the whole <data> element goes, public or not
        assertNoIdentifiers(in: out)

        for name in Array(secretData.keys) + ["public_key"] + Array(identifiers.keys) {
            XCTAssertTrue(out.contains("<key>\(name)</key>"), "the field name \(name) should stay, so a report says what was in the file")
        }
        XCTAssertTrue(out.hasPrefix("iPhone: iPhone 16 Pro Max, iOS 26.6\n"), "the lines before it stay")
        XCTAssertTrue(out.hasSuffix("\nSession: Live (live engine)"), "and the lines after it")
    }

    func testTheShortKeysOfAPlistAreHiddenToo() throws {
        // A 32-byte key is 44 characters of base64 and a 16-byte one is 24: too short for the long-blob rule,
        // so only the plist rule stands between them and a bug report.
        let plist = try fakeRecordPlist()
        let out = redact(plist)
        assertNoTrace(of: bytes(32, seed: 8), named: "private_key", in: out)
        assertNoTrace(of: bytes(16, seed: 9), named: "alt_irk", in: out)
    }

    func testARecordCutOffInTheMiddleOfAKeyStillHidesWhatShowed() throws {
        let plist = try fakeRecordPlist()
        let marker = try XCTUnwrap(plist.range(of: "<key>HostPrivateKey</key>"))
        let afterTag = try XCTUnwrap(plist.range(of: "<data>", range: marker.upperBound..<plist.endIndex))
        let cut = plist.index(afterTag.upperBound, offsetBy: 160)
        let shown = String(plist[afterTag.upperBound..<cut]).filter { !$0.isWhitespace }
        let out = redact(String(plist[..<cut]))
        XCTAssertFalse(out.filter { !$0.isWhitespace }.contains(String(shown.prefix(24))), "the part of the key that was cut off is still in the output")
        XCTAssertTrue(out.contains("<key>HostPrivateKey</key>"))
    }

    // MARK: Dumps of the same record

    func testARecordDumpedAsJSONIsHidden() throws {
        var dictionary: [String: String] = identifiers
        for (name, value) in secretData { dictionary[name] = value.base64EncodedString() }
        dictionary["public_key"] = publicKey.base64EncodedString()
        let json = try JSONSerialization.data(withJSONObject: dictionary, options: [.prettyPrinted, .sortedKeys])
        let out = redact("pairing: " + String(decoding: json, as: UTF8.self))

        for (name, value) in secretData { assertNoTrace(of: value, named: name, in: out) }
        assertNoIdentifiers(in: out)
        for name in dictionary.keys { XCTAssertTrue(out.contains("\"\(name)\""), "the field name \(name) should stay") }
    }

    func testARecordPrintedAsAPythonDictIsHidden() throws {
        let pemKey = String(decoding: secretData["HostPrivateKey"]!, as: UTF8.self).replacingOccurrences(of: "\n", with: "\\n")
        let escapes = hexEscapes(bytes(32, seed: 8))
        let irk = bytes(16, seed: 9).base64EncodedString()
        var text = "{'HostPrivateKey': b'\(pemKey)', 'private_key': b'\(escapes)', 'alt_irk': b'\(irk)', "
        text += "'HostID': '\(Self.hostID)', 'SystemBUID': '\(Self.systemBUID)', "
        text += "'WiFiMACAddress': '\(Self.wifiMAC)'}"
        let out = redact(text)

        XCTAssertFalse(out.contains("BEGIN"), "the key block should be gone")
        XCTAssertFalse(out.contains(String(escapes.prefix(40))), "the \\x byte escapes should be gone")
        assertNoTrace(of: bytes(16, seed: 9), named: "alt_irk", in: out)
        XCTAssertFalse(out.contains(Self.hostID))
        XCTAssertFalse(out.contains(Self.systemBUID))
        XCTAssertFalse(out.contains(Self.wifiMAC))
        for name in ["HostPrivateKey", "private_key", "alt_irk", "HostID"] { XCTAssertTrue(out.contains(name)) }
    }

    func testByteArraysPrintedTheWayRustPrintsThemAreHidden() {
        let key = decimals(bytes(32, seed: 8))
        let list = key.joined(separator: ", ")
        let oneLine = "RpPairingFile { identifier: \"\(Self.identifier)\", private_key: [\(list)], ok: true }"
        let outOne = redact(oneLine)
        XCTAssertFalse(outOne.contains(key.prefix(8).joined(separator: ", ")), "the byte list should be gone")
        XCTAssertFalse(outOne.contains(Self.identifier))
        XCTAssertTrue(outOne.contains("ok: true"), "the rest of the line stays")

        // {:#?} puts one number on each line, with a trailing comma.
        var pretty = "RpPairingFile {\n    private_key: [\n"
        for number in key { pretty += "        \(number),\n" }
        pretty += "    ],\n    ok: true,\n}"
        let outPretty = redact(pretty)
        let pair = "\(key[3]),\n        \(key[4])"
        XCTAssertFalse(outPretty.contains(pair), "the pretty-printed byte list should be gone")
        XCTAssertTrue(outPretty.contains("ok: true,"))
    }

    // MARK: Not too eager

    func testAMACAddressIsHiddenButATimeOrAnIPv6AddressIsNot() {
        XCTAssertEqual(redact("Wi-Fi a4:5e:60:c1:22:9b joined"), "Wi-Fi <mac> joined")
        XCTAssertEqual(redact("lower A4:5E:60:C1:22:9B case"), "lower <mac> case")
        for untouched in ["[05:14:51] Teleported to Eiffel Tower", "Mac at fd12:3456:789a::1 port 47653",
                          "Mac at 192.168.1.20 port 47653", "route took 01:02:03:04:05 hours"] {
            XCTAssertEqual(redact(untouched), untouched)
        }
    }

    func testShortListsOfNumbersAreNotMistakenForKeyBytes() {
        for untouched in ["speeds [5, 10, 15, 20, 25] km/h", "waits: [30, 60, 120]",
                          "version 11.0.0 build 24G222 on port 47653, 12 stops, 3 waits"] {
            XCTAssertEqual(redact(untouched), untouched)
        }
    }

    func testFieldNamesAloneAreNotHidden() {
        // "private_key" with nothing after it is a name, not a secret.
        for untouched in ["pairing file has: HostID, SystemBUID, WiFiMACAddress, private_key, alt_irk",
                          "Remote Pairing identity: yes (identifier, public_key, private_key)"] {
            XCTAssertEqual(redact(untouched), untouched)
        }
    }

    // MARK: Stable

    func testRedactingAPairingRecordTwiceChangesNothingMore() throws {
        let plist = try fakeRecordPlist()
        var base64Fields: [String: String] = [:]
        for (name, value) in secretData { base64Fields[name] = value.base64EncodedString() }
        let jsonData = try JSONSerialization.data(withJSONObject: base64Fields, options: [.prettyPrinted, .sortedKeys])
        let json = String(decoding: jsonData, as: UTF8.self)
        let escapes = hexEscapes(bytes(32, seed: 8))
        let python = "{'private_key': b'\(escapes)', 'HostID': '\(Self.hostID)'}"
        let rust = "private_key: [\(decimals(bytes(32, seed: 8)).joined(separator: ", "))]"
        let cutOff = String(plist.prefix(900))
        for text in [plist, json, python, rust, cutOff] {
            let once = redact(text)
            XCTAssertEqual(redact(once), once)
        }
    }
}
