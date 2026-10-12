import Foundation
import SpooferCore
import SwiftUI

/// "Stop spoofing after …": a fail-safe so the iPhone isn't left somewhere it isn't, for ever.
/// The rules (presets, parsing, wording, countdown) are in `Killswitch`, which has the tests.
extension AppModel {
    /// Start counting for the session that is running now. Nothing happens when the setting is Never.
    func armKillswitch(now: Date = Date()) {
        killswitchTask?.cancel()
        killswitchTask = nil
        guard session != nil, let deadline = Killswitch.deadline(from: now, minutes: prefs.autoStopMinutes) else {
            killswitchDeadline = nil
            return
        }
        killswitchDeadline = deadline
        // Short naps instead of one long sleep: if the Mac's clock is changed the deadline is still
        // checked against the real time within a minute.
        killswitchTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self, let deadline = self.killswitchDeadline else { return }
                let left = Killswitch.remaining(until: deadline, now: Date())
                if left <= 0.5 {
                    self.killswitchReached()
                    return
                }
                try? await Task.sleep(for: .seconds(min(left, 60)))
            }
        }
    }

    func disarmKillswitch() {
        killswitchTask?.cancel()
        killswitchTask = nil
        killswitchDeadline = nil
    }

    /// The time is up: put the real location back, and say so.
    private func killswitchReached() {
        killswitchDeadline = nil
        killswitchTask = nil
        guard session != nil else { return }
        let how = Killswitch.label(minutes: prefs.autoStopMinutes)
        appendLog("Auto-stop: \(how) of spoofing is up. Restoring the real location…", level: .warning)
        showToast(Toast(symbol: "timer", title: "Spoofing stopped automatically",
                        subtitle: "\(how) is up. The real location is coming back.", style: .info), duration: 8)
        stop()
    }

    /// From the menu or Settings. While spoofing is running, the new time counts from now.
    func setAutoStop(minutes: Int) {
        let minutes = Killswitch.sanitize(minutes: minutes)
        guard minutes != prefs.autoStopMinutes else { return }
        prefs.autoStopMinutes = minutes
        if session != nil { armKillswitch() }
        appendLog(minutes > 0 ? "Auto-stop: spoofing will stop after \(Killswitch.label(minutes: minutes))."
                              : "Auto-stop turned off.", level: .info)
    }

    func chooseCustomAutoStop() {
        let current = prefs.autoStopMinutes
        guard let text = promptForText(title: "Stop Automatically After",
                                       message: "Type a time, such as 45 minutes, 1.5 hours or 1:30. The longest is 24 hours.",
                                       defaultValue: current > 0 ? Killswitch.label(minutes: current) : "") else { return }
        guard let minutes = Killswitch.parse(text) else {
            warn("That isn't a time", "Try 45 minutes or 1.5 hours.", log: "Couldn't read “\(text)” as a time for Auto-stop.")
            return
        }
        setAutoStop(minutes: minutes)
    }
}

/// The choices, shared by the Location menu and Settings. The style is the caller's.
struct AutoStopPicker: View {
    var body: some View {
        let model = AppModel.shared
        let current = Preferences.shared.autoStopMinutes
        Picker("Stop Automatically After", selection: Binding(get: { Preferences.shared.autoStopMinutes },
                                                              set: { model.setAutoStop(minutes: $0) })) {
            Text("Never").tag(0)
            ForEach(Killswitch.presetMinutes, id: \.self) { Text(Killswitch.label(minutes: $0)).tag($0) }
            // A time typed with Custom… that isn't one of the presets still shows as the chosen one.
            if current > 0, !Killswitch.presetMinutes.contains(current) {
                Text(Killswitch.label(minutes: current)).tag(current)
            }
        }
    }
}
