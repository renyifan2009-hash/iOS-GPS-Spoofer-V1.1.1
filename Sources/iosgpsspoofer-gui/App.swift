import AppKit
import SwiftUI
import SpooferCore

/// Entry point is `main.swift` (it handles `--render-icon` first).
struct SpooferGUIApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("iOS GPS Spoofer", id: "main") {
            ContentView()
                .environment(AppModel.shared)
                .environment(Preferences.shared)
                .environment(LibraryStore.shared)
                .tint(Brand.accent)
                .frame(minWidth: 1040, minHeight: 640)
        }
        .defaultSize(width: 1400, height: 860)
        .commands { AppCommands() }

        Settings {
            SettingsView()
                .environment(AppModel.shared)
                .environment(Preferences.shared)
                .environment(LibraryStore.shared)
                .tint(Brand.accent)
        }

        MenuBarExtra(isInserted: menuBarInserted) {
            MenuBarContent()
                .environment(AppModel.shared)
                .environment(Preferences.shared)
                .environment(LibraryStore.shared)
                .tint(Brand.accent)
        } label: {
            MenuBarLabel()
        }
        .menuBarExtraStyle(.window)
    }

    private var menuBarInserted: Binding<Bool> {
        Binding(
            get: { Preferences.shared.showMenuBarExtra },
            set: { Preferences.shared.showMenuBarExtra = $0 }
        )
    }
}

struct AppCommands: Commands {
    var body: some Commands {
        let model = AppModel.shared
        CommandGroup(after: .appInfo) {
            Button("Check for Updates…") {
                Task { await Updater.shared.check(userInitiated: true) }
            }
            .disabled(!Updater.shared.canUpdate)
        }
        CommandGroup(replacing: .newItem) {
            Button("Import Route…") { model.importRouteWithPanel() }
                .keyboardShortcut("o")
            Button("Export Route as GPX…") { model.exportRouteWithPanel() }
                .keyboardShortcut("e", modifiers: [.command, .shift])
            Button("Save Route to Library…") { model.saveRouteToLibrary() }
                .keyboardShortcut("s")
        }
        CommandGroup(after: .sidebar) {
            Button("Toggle Inspector") { model.showInspector.toggle() }
                .keyboardShortcut("i", modifiers: [.command, .option])
        }
        // Items that change with the model live in a View: a View's body is
        // re-evaluated when the @Observable state it reads changes.
        CommandMenu("Location") {
            LocationMenuItems()
        }
        CommandGroup(replacing: .help) {
            Button("Welcome & Setup Checklist") { model.showWelcome = true }
            Button("Connecting an iPhone…") { model.showConnectionHelp = true }
            Divider()
            Button("Copy Diagnostics") { model.copyDiagnostics() }
        }
    }
}

struct LocationMenuItems: View {
    var body: some View {
        let model = AppModel.shared
        let following = model.isFollowingDevice && model.session != nil
        Button(model.hasSession ? "Stop & Restore Real Location" : "Start") { model.primaryAction() }
            .keyboardShortcut(.return, modifiers: .command)
        Button(model.isPaused ? "Resume Route" : "Pause Route") { model.togglePause() }
            .keyboardShortcut("p", modifiers: [.command, .shift])
            .disabled(!model.canPauseRoute)
        Divider()
        Button("Teleport Mode") { model.mode = .teleport }
            .keyboardShortcut("1")
        Button("Route Mode") { model.mode = .route }
            .keyboardShortcut("2")
        Button("Joystick Mode") { model.mode = .joystick }
            .keyboardShortcut("3")
        Divider()
        Button("Search Places…") { model.searchFocusRequest += 1 }
            .keyboardShortcut("f")
        Button("Paste Coordinates or Maps Link") { model.pasteFromClipboard() }
            .keyboardShortcut("v", modifiers: [.command, .shift])
        Button("Copy Target Coordinates") { if let t = model.target { model.copyCoordinates(t) } }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .disabled(model.target == nil)
        Button(model.targetIsFavorite ? "Remove Target from Favorites" : "Add Target to Favorites…") {
            model.toggleFavoriteForTarget()
        }
        .keyboardShortcut("d")
        .disabled(model.target == nil)
        Divider()
        Button("Fit Map") { model.fitMap() }
            .keyboardShortcut("0")
        Button(following ? "Stop Following iPhone" : "Re-center on iPhone") {
            if following { model.stopFollowingDevice() } else { model.recenterOnDevice() }
        }
        .keyboardShortcut("l")
        .disabled(model.session == nil || model.devicePosition == nil)
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        signal(SIGPIPE, SIG_IGN)
        TerminationGuard.install()
        // A raw SwiftPM build has no bundle (so no .icns): draw the icon instead.
        if Bundle.main.bundleIdentifier == nil {
            NSApp.applicationIconImage = AppIconRenderer.image(size: 512)
        }
        MainActor.assumeIsolated {
            #if DEBUG
            let snapshot = DebugSnapshot.isOn
            DebugSnapshot.start()
            #else
            let snapshot = false
            #endif
            if !snapshot {
                NSApp.setActivationPolicy(.regular)
                NSApp.activate()
            }
            AppModel.shared.bootstrap()
            RemoteHost.shared.bootstrap()
        }

        // Mop up children orphaned by a previous force-kill. Off-main: it
        // runs pgrep/ps and waits for them.
        DispatchQueue.global(qos: .utility).async {
            let reaped = ChildProcessRegistry.sweepStrays()
            Task { @MainActor in AppModel.shared.completeStartupSweep(reaped: reaped) }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    // AppKit calls these on the main thread.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let session = MainActor.assumeIsolated { AppModel.shared.session }
        guard let session else { return .terminateNow }

        DispatchQueue.global(qos: .userInitiated).async {
            session.stopBlocking()
            DispatchQueue.main.async { NSApp.reply(toApplicationShouldTerminate: true) }
        }
        return .terminateLater
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated { AppModel.shared.session }?.stopBlocking()
    }
}
