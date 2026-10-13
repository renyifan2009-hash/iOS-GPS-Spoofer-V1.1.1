import Foundation

/// What goes into a bug report must not carry the things that identify the iPhone or let someone act as its
/// owner: the device's UDID, private keys and certificates, long encoded blobs (pairing records are
/// base64 inside a plist), tokens, and an Apple ID. Location and place names are left in on purpose: a
/// developer can't debug a route without them, and the person copies the report by hand.
public enum DiagnosticsRedactor {
    public static func redact(_ text: String) -> String {
        var s = text
        for rule in rules {
            s = rule.regex.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s),
                                                    withTemplate: rule.template)
        }
        return redactEncodedBlobs(in: s)
    }

    /// Long runs of base64 or hex (certificates, pairing records, tokens), except file paths, which look
    /// the same to a pattern but are what a bug report needs. Told apart by what they are made of: random
    /// base64 is about half capital letters and has a slash every 64 characters or so, while a path has
    /// several slashes and is mostly lowercase.
    private static func redactEncodedBlobs(in text: String) -> String {
        let matches = blob.matches(in: text, range: NSRange(text.startIndex..., in: text))
        var out = text
        for match in matches.reversed() {
            guard let range = Range(match.range, in: out) else { continue }
            let run = out[range]
            if looksLikeAPath(run) { continue }
            out.replaceSubrange(range, with: "<redacted data>")
        }
        return out
    }

    private static func looksLikeAPath(_ run: Substring) -> Bool {
        let slashes = run.filter { $0 == "/" }.count
        let letters = run.filter(\.isLetter).count
        let capitals = run.filter(\.isUppercase).count
        return slashes >= 3 && letters > 0 && capitals * 4 <= letters
    }

    /// "\/" is how JSON writes a slash, so a key in a JSON dump is not cut into short pieces by it.
    private static let blob = try! NSRegularExpression(pattern: #"(?:\\/|[A-Za-z0-9+/_-]){48,}={0,2}"#)

    private struct Rule {
        let regex: NSRegularExpression
        let template: String
        init(_ pattern: String, _ template: String, options: NSRegularExpression.Options = [.caseInsensitive]) {
            // The patterns are fixed in this file; a typo should fail loudly in the tests, not skip a rule.
            self.regex = try! NSRegularExpression(pattern: pattern, options: options)
            self.template = template
        }
    }

    /// The secret fields of a pairing record, by name: a lockdown record's keys and escrow bag, a Remote
    /// Pairing identity's private key and its `alt_irk`, plus the usual token and password names.
    private static let secretNames =
        #"token|secret|password|passwd|api[_-]?key|(?:host|root)?private[_-]?key|alt[_-]?irk|escrow[_-]?bag"#
    /// What names the Mac or the iPhone in a pairing record (the UUID-shaped ones; the Wi-Fi address has its own rule).
    private static let idNames = #"HostID|SystemBUID|identifier"#
    private static let uuid = #"[0-9A-F]{8}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{4}-[0-9A-F]{12}"#

    /// Order matters: whole blocks first, then the smaller shapes inside what is left.
    private static let rules: [Rule] = [
        // A key or certificate block, however many lines.
        Rule(#"-----BEGIN [A-Z0-9 ]+-----[\s\S]*?-----END [A-Z0-9 ]+-----"#, "<redacted key>"),
        // An unterminated block (the log was cut off): everything from the header on is key material.
        Rule(#"-----BEGIN [A-Z0-9 ]+-----[\s\S]*"#, "<redacted key>"),
        // A property list's binary field, whole: pairing records are plists, and a 32-byte key is only 44
        // characters of base64, too short for the long-blob rule. The field name before it stays.
        Rule(#"<data>[\s\S]*?</data>"#, "<redacted data>"),
        // ... and one that was cut off before its end tag.
        Rule(#"<data>[\s\S]*"#, "<redacted data>"),
        // Key bytes printed as a list of numbers, the way Rust prints a Vec<u8> (one line, or one number per
        // line with {:#?}). Sixteen or more numbers up to 999 in a row is bytes, not a setting.
        Rule(#"\[\s*(?:\d{1,3}\s*,\s*){15,}\d{1,3}\s*,?\s*\]"#, "<redacted data>"),
        // Bytes printed as \x escapes, the way Python prints them.
        Rule(#"(?:\\x[0-9A-F]{2}){8,}"#, "<redacted data>"),
        // A header: the whole value, including a scheme word in front of it.
        Rule(#"\b(authorization)(\s*[:=]\s*)(?:(?:bearer|basic|token)\s+)?[^\s,;"']+"#, "$1$2<redacted>"),
        Rule(#"\bbearer\s+[A-Z0-9._~+/=-]+"#, "Bearer <redacted>"),
        // key = value for secrets, with the name or the value in quotes (JSON, Python) and a b'...' prefix.
        Rule(#"\b("# + secretNames + #")(["']?\s*[:=]\s*|\s+)((?:[bBrR]{1,2}["']|["'])?)(?!<redacted)[^\s,;"']+"#,
             "$1$2$3<redacted>"),
        // The ids that name the Mac and the iPhone in a pairing record: in a plist ...
        Rule(#"(<key>(?:"# + idNames + #"|WiFiMACAddress)</key>\s*<string>)[^<]*(</string>)"#, "$1<redacted>$2"),
        // ... and in a dump (JSON, Python, Rust).
        Rule(#"\b("# + idNames + #")(["']?\s*[:=]\s*["']?)"# + uuid, "$1$2<redacted>"),
        // An Apple ID (or any address).
        Rule(#"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#, "<email>"),
        // A UDID: 00008110-001A2B3C4D5E601E (iPhone XS and later) ...
        Rule(#"\b[0-9A-F]{8}-[0-9A-F]{16}\b"#, "<udid>"),
        // ... and the 40-character form of older iPhones.
        Rule(#"\b[0-9A-F]{40}\b"#, "<udid>"),
        // A hardware (MAC) address: six pairs, so a time or an IPv6 address doesn't match.
        Rule(#"\b(?:[0-9A-F]{2}:){5}[0-9A-F]{2}\b"#, "<mac>"),
        // The Mac user's name inside a home folder path.
        Rule(#"/Users/[^/\s"']+"#, "/Users/<user>", options: []),
    ]
}
