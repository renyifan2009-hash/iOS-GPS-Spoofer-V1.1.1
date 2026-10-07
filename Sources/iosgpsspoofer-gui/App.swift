import AppKit
import SwiftUI
import SpooferCore

@main
struct SpooferGUIApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("iOS GPS Spoofer", id: "main") {
            ContentView()
                .environment(AppModel.shared)
                .environment(Preferences.shared)
                .environment(LibraryStore.shared)
                .frame(minWidth: 960, minHeight: 600)
        }
        .defaultSize(width: 1360, height: 840)
        .commands { AppCommands() }

        Settings {
            SettingsView()
                .environment(AppModel.shared)
                .environment(Preferences.shared)
                .environment(LibraryStore.shared)
        }

        MenuBarExtra(isInserted: menuBarInserted) {
            MenuBarContent()
                .environment(AppModel.shared)
                .environment(Preferences.shared)
                .environment(LibraryStore.shared)
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
        CommandMenu("Location") {
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
            Button(model.targetIsFavorite ? "Remove Target from Favorites" : "Add Target to Favorites…") {
                model.toggleFavoriteForTarget()
            }
            .keyboardShortcut("d")
            Divider()
            Button("Fit Map") { model.fitMap() }
                .keyboardShortcut("0")
            Button(Preferences.shared.followDevice ? "Stop Following Device" : "Follow Device") {
                Preferences.shared.followDevice.toggle()
            }
            .keyboardShortcut("l")
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        signal(SIGPIPE, SIG_IGN)
        TerminationGuard.install()
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        MainActor.assumeIsolated { AppModel.shared.bootstrap() }

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
