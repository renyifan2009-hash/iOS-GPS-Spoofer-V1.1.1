import XCTest

/// Checks on the Mac app's own source text, for copy mistakes that only show on screen. The
/// app target has no test target, so these read the files directly.
final class GUICopyTests: XCTestCase {
    private var guiSources: URL {
        // <repo>/Tests/SpooferCoreTests/GUICopyTests.swift  ->  <repo>/Sources/iosgpsspoofer-gui
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/iosgpsspoofer-gui", isDirectory: true)
    }

    private func swiftFiles() throws -> [URL] {
        let enumerator = FileManager.default.enumerator(at: guiSources, includingPropertiesForKeys: nil)
        let files = (enumerator?.allObjects as? [URL] ?? []).filter { $0.pathExtension == "swift" }
        XCTAssertFalse(files.isEmpty, "found no sources under \(guiSources.path)")
        return files
    }

    private func lines(of url: URL) throws -> [String] {
        try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
    }

    /// A line continuation lost in a multi-line string once left 29 spaces in the middle of a
    /// sentence in Settings, shown as a wide gap. Three spaces in a row, after a character that
    /// isn't a quote, is never intended in this code (aligned comments are skipped).
    func testNoStrayRunsOfSpacesInText() throws {
        var found: [String] = []
        for file in try swiftFiles() {
            for (index, line) in try lines(of: file).enumerated() {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("//") { continue }
                let range = NSRange(line.startIndex..., in: line)
                let match = try NSRegularExpression(pattern: #"[^\s"] {3,}[^\s/]"#).firstMatch(in: line, range: range)
                if match != nil { found.append("\(file.lastPathComponent):\(index + 1): \(trimmed.prefix(80))") }
            }
        }
        XCTAssertEqual(found, [], "runs of spaces inside text")
    }

    /// Labels that were renamed because they misled. They must not come back by a merge.
    func testRenamedLabelsStayRenamed() throws {
        let gone = ["Start Route From Here", "Show on iPhone", "The CLI can use it as @name"]
        for file in try swiftFiles() {
            let text = try String(contentsOf: file, encoding: .utf8)
            for phrase in gone {
                XCTAssertFalse(text.contains(phrase), "\(file.lastPathComponent) still says “\(phrase)”")
            }
        }
    }
}
