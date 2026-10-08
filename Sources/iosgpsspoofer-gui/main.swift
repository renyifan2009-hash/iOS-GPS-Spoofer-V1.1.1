import AppKit
import Foundation
import SpooferCore

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

// `--install-helper` runs the app's own pymobiledevice3 installer (the
// Install button) in the terminal, printing its progress, and exits.
if ProcessInfo.processInfo.arguments.contains("--install-helper") {
    let outcome = HelperInstaller.perform(
        step: { print("==> \($0)") },
        output: { print("    \($0)") })
    switch outcome {
    case .installed(let version):
        print("Installed pymobiledevice3 \(version) in \(AppSupport.helperEnvironment.path)")
        exit(0)
    case .needsDeveloperTools:
        print("Apple's Command Line Tools are needed first: xcode-select --install")
        exit(1)
    case .failed(let message):
        print("Failed: \(message)")
        exit(1)
    }
}

MainActor.assumeIsolated {
    SpooferGUIApp.main()
}
