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

    private static let blob = try! NSRegularExpression(pattern: #"[A-Za-z0-9+/_-]{48,}={0,2}"#)

    private struct Rule {
        let regex: NSRegularExpression
        let template: String
        init(_ pattern: String, _ template: String, options: NSRegularExpression.Options = [.caseInsensitive]) {
            // The patterns are fixed in this file; a typo should fail loudly in the tests, not skip a rule.
            self.regex = try! NSRegularExpression(pattern: pattern, options: options)
            self.template = template
        }
    }

    /// Order matters: whole blocks first, then the smaller shapes inside what is left.
    private static let rules: [Rule] = [
        // A key or certificate block, however many lines.
        Rule(#"-----BEGIN [A-Z0-9 ]+-----[\s\S]*?-----END [A-Z0-9 ]+-----"#, "<redacted key>"),
        // An unterminated block (the log was cut off): everything from the header on is key material.
        Rule(#"-----BEGIN [A-Z0-9 ]+-----[\s\S]*"#, "<redacted key>"),
        // A header: the whole value, including a scheme word in front of it.
        Rule(#"\b(authorization)(\s*[:=]\s*)(?:(?:bearer|basic|token)\s+)?[^\s,;"']+"#, "$1$2<redacted>"),
        Rule(#"\bbearer\s+[A-Z0-9._~+/=-]+"#, "Bearer <redacted>"),
        // key = value for secrets
        Rule(#"\b(token|secret|password|passwd|api[_-]?key|private[_-]?key)(\s*[:=]\s*|\s+)(?!<redacted)[^\s,;"']+"#,
             "$1$2<redacted>"),
        // An Apple ID (or any address).
        Rule(#"[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}"#, "<email>"),
        // A UDID: 00008110-001A2B3C4D5E601E (iPhone XS and later) ...
        Rule(#"\b[0-9A-F]{8}-[0-9A-F]{16}\b"#, "<udid>"),
        // ... and the 40-character form of older iPhones.
        Rule(#"\b[0-9A-F]{40}\b"#, "<udid>"),
        // The Mac user's name inside a home folder path.
        Rule(#"/Users/[^/\s"']+"#, "/Users/<user>", options: []),
    ]
}
