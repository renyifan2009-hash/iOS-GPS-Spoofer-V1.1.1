import AppKit
import Foundation

// `iosgpsspoofer-gui --render-icon <dir.iconset>` writes the app icon PNGs and
// exits (package-dmg.sh uses it), so the icon has a single source of truth.
// Otherwise, run the app.
if let flag = ProcessInfo.processInfo.arguments.firstIndex(of: "--render-icon"),
   flag + 1 < ProcessInfo.processInfo.arguments.count {
    let directory = URL(fileURLWithPath: ProcessInfo.processInfo.arguments[flag + 1])
    do {
        try AppIconRenderer.writeIconset(to: directory)
        exit(0)
    } catch {
        FileHandle.standardError.write(Data("icon rendering failed: \(error)\n".utf8))
        exit(1)
    }
}

MainActor.assumeIsolated {
    SpooferGUIApp.main()
}
