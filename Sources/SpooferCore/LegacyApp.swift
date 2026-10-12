import Foundation

/// The product used to be "iOS GPS Spoofer.app". The old and new apps share one bundle ID
/// (so preferences, permissions and updates carry over), which means a copy of the old app
/// left in Applications makes macOS choose between the two whenever something opens "the
/// app". The installer removes it; someone who drags the new app in from the DMG still has it,
/// so the app offers to move it to the Trash.
public enum LegacyApp {
    public static let bundleName = "iOS GPS Spoofer.app"

    /// The places an app is normally installed.
    public static var standardDirectories: [URL] {
        var directories = [URL(fileURLWithPath: "/Applications", isDirectory: true)]
        directories.append(URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true).appendingPathComponent("Applications", isDirectory: true))
        return directories
    }

    /// Old-named copies found in `directories`, except `running` (the copy that is asking).
    public static func leftovers(in directories: [URL] = standardDirectories,
                                 excluding running: URL? = nil,
                                 fileManager fm: FileManager = .default) -> [URL] {
        let runningPath = running?.resolvingSymlinksInPath().standardizedFileURL.path
        var found: [URL] = []
        for directory in directories {
            let candidate = directory.appendingPathComponent(bundleName, isDirectory: true)
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: candidate.path, isDirectory: &isDirectory), isDirectory.boolValue else { continue }
            if candidate.resolvingSymlinksInPath().standardizedFileURL.path == runningPath { continue }
            found.append(candidate)
        }
        return found
    }
}
