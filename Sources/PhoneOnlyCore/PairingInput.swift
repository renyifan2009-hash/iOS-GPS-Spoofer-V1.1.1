import Foundation

/// What a person types or pastes to pair the iPhone app with a Mac: the
/// six-digit code, and (when the Mac isn't found by itself) its address.
public enum PairingInput {
    /// The digits in `text` as plain 0 to 9, no more than `length` of them.
    ///
    /// Spaces and dashes are dropped, so "482 913" and "482-913" work. Digits
    /// from other scripts (Arabic-Indic, full-width) become the ASCII digit
    /// they stand for, because the Mac's code is always ASCII. Superscripts,
    /// fractions and circled numbers are not digits here and are dropped.
    public static func code(from text: String, length: Int) -> String {
        var digits = ""
        for character in text {
            guard let digit = asciiDigit(character) else { continue }
            digits.append(digit)
            if digits.count == length { break }
        }
        return digits
    }

    private static func asciiDigit(_ character: Character) -> Character? {
        let scalars = character.unicodeScalars
        guard scalars.count == 1, let scalar = scalars.first,
              scalar.properties.numericType == .decimal,
              let value = scalar.properties.numericValue, (0...9).contains(value) else { return nil }
        return Character(String(Int(value)))
    }

    /// An address and port typed in by hand.
    public struct Address: Equatable, Sendable {
        public var host: String
        public var port: UInt16

        public init(host: String, port: UInt16) {
            self.host = host
            self.port = port
        }
    }

    public enum AddressProblem: Error, Equatable, Sendable {
        case noAddress
        case badPort
    }

    /// The address and port the person typed, or what is wrong with them. An
    /// empty port means the usual one. A port that is not a number from 1 to
    /// 65535 is an error: it is never swapped for the usual one behind the
    /// person's back.
    public static func address(host: String, port: String, defaultPort: UInt16) -> Result<Address, AddressProblem> {
        let host = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return .failure(.noAddress) }
        let port = port.trimmingCharacters(in: .whitespacesAndNewlines)
        if port.isEmpty { return .success(Address(host: host, port: defaultPort)) }
        guard port.allSatisfy({ $0.isASCII && $0.isNumber }), let number = UInt16(port), number >= 1 else {
            return .failure(.badPort)
        }
        return .success(Address(host: host, port: number))
    }

    /// Plain words for `AddressProblem`.
    public static func message(for problem: AddressProblem) -> String {
        switch problem {
        case .noAddress: "Type the Mac's address first."
        case .badPort: "The port must be a number from 1 to 65535."
        }
    }
}
