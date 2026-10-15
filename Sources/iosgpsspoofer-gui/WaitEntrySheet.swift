import PhoneOnlyCore
import SwiftUI

/// Type how long a route waits at one of its stops: "45", "20 min", "1h 30m", "1:30". A number on its own
/// is minutes. The text under the field says what it read, or why it can't.
struct WaitEntrySheet: View {
    let title: String
    let initial: TimeInterval
    let onSave: (TimeInterval) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var focused: Bool

    private var parsed: WaitDuration.Parsed { WaitDuration.parse(text) }

    private var seconds: TimeInterval? {
        if case .wait(let value) = parsed { return value }
        return nil
    }

    private static let quick: [TimeInterval] = [300, 900, 1800, 3600, 7200]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(title).font(.headline)
            TextField("45 min, 1h 30m or 1:30", text: $text)
                .textFieldStyle(.roundedBorder)
                .focused($focused)
                .onSubmit(save)
                .accessibilityLabel("How long to wait")
            Text(text.trimmingCharacters(in: .whitespaces).isEmpty
                 ? "A number on its own is minutes. Up to 24 hours."
                 : (seconds.map { $0 == 0 ? "No wait" : "Waits \(WaitDuration.format($0))" } ?? parsed.description))
                .font(.callout)
                .foregroundStyle(seconds == nil && !text.trimmingCharacters(in: .whitespaces).isEmpty
                                 ? Color.red : Color.secondary)
                .accessibilityAddTraits(.updatesFrequently)
            HStack(spacing: 6) {
                ForEach(Self.quick, id: \.self) { value in
                    Button(WaitDuration.format(value)) { text = WaitDuration.format(value) }
                        .controlSize(.small)
                }
            }
            HStack {
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Save", action: save)
                    .keyboardShortcut(.defaultAction)
                    .disabled(seconds == nil)
            }
        }
        .padding(20)
        .frame(width: 360)
        .onAppear {
            text = initial > 0 ? WaitDuration.format(initial) : ""
            focused = true
        }
    }

    private func save() {
        guard let seconds else { return }
        onSave(seconds)
        dismiss()
    }
}
