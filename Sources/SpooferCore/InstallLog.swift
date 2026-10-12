import Foundation

/// Reading the installer's log (`setup.sh` writes lines like `✗ The build failed.`). The app uses
/// it to tell someone why an update stopped instead of showing "Updating…" for ever.
public enum InstallLog {
    /// The first failure line in `text`, without colour codes or the ✗ mark, or nil.
    public static func failureHeadline(in text: String) -> String? {
        let ansi = try? NSRegularExpression(pattern: "\u{1B}\\[[0-9;]*m")
        for rawLine in text.split(whereSeparator: \.isNewline) {
            var line = String(rawLine)
            if let ansi { line = ansi.stringByReplacingMatches(in: line, range: NSRange(line.startIndex..., in: line), withTemplate: "") }
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("✗") else { continue }
            let message = trimmed.dropFirst().trimmingCharacters(in: .whitespaces)
            if !message.isEmpty { return message }
        }
        return nil
    }

    /// The installer's own explanation for a stop, from the end of the log file.
    public static func failureHeadline(inFileAt url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        let window: UInt64 = 64 * 1024
        try? handle.seek(toOffset: size > window ? size - window : 0)
        guard let data = try? handle.readToEnd() else { return nil }
        return failureHeadline(in: String(decoding: data, as: UTF8.self))
    }
}
