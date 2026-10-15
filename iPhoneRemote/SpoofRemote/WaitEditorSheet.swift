import PhoneOnlyCore
import SwiftUI

/// How long to stop somewhere on a route: pick a quick time, or type one ("30", "45 min", "1h 15m", "1:30").
/// A number on its own is minutes. The line under the field says what it read, or why it can't.
struct WaitEditorSheet: View {
    let title: String
    let prompt: String
    let initial: Double
    /// What "no wait" is called here: "Leave now" at the start, "No stop" elsewhere.
    var zeroLabel = "No wait"
    let onSave: (Double) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var text = ""
    @FocusState private var focused: Bool

    private static let quick: [Double] = [0, 300, 900, 1800, 3600, 7200]

    private var trimmed: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var parsed: WaitDuration.Parsed { WaitDuration.parse(text) }

    private var seconds: Double? {
        if case .wait(let value) = parsed { return value }
        return nil
    }

    private var feedback: String {
        if trimmed.isEmpty { return "A number on its own is minutes. Up to 24 hours." }
        if let seconds { return seconds == 0 ? zeroLabel : "Waits \(WaitDuration.format(seconds))" }
        return parsed.description
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("30, 45 min or 1h 15m", text: $text)
                        .keyboardType(.numbersAndPunctuation)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .submitLabel(.done)
                        .focused($focused)
                        .onSubmit(save)
                        .font(.system(.title3, design: .rounded).weight(.semibold))
                        .accessibilityLabel("How long")
                } header: {
                    Text(prompt)
                } footer: {
                    Text(feedback)
                        .foregroundStyle(seconds == nil && !trimmed.isEmpty ? Brand.danger : Color.secondary)
                        .contentTransition(.opacity)
                        .accessibilityAddTraits(.updatesFrequently)
                }

                Section("Quick picks") {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 8)], spacing: 8) {
                        ForEach(Self.quick, id: \.self) { value in
                            quickButton(value)
                        }
                    }
                    .padding(.vertical, 4)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save).disabled(seconds == nil)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .onAppear {
            text = initial > 0 ? WaitDuration.format(initial) : ""
            focused = true
        }
    }

    /// A quick pick saves straight away: one tap for the usual times.
    private func quickButton(_ value: Double) -> some View {
        let selected = seconds == value && !trimmed.isEmpty
        return Button {
            onSave(value)
            dismiss()
        } label: {
            Text(value == 0 ? zeroLabel : WaitDuration.format(value))
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
                .minimumScaleFactor(0.8)
                .frame(maxWidth: .infinity, minHeight: 40)
                .foregroundStyle(selected ? Color.white : Color.primary)
                .background {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .fill(selected ? AnyShapeStyle(Brand.indigo) : AnyShapeStyle(Color.primary.opacity(0.07)))
                }
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private func save() {
        guard let seconds else { return }
        onSave(seconds)
        dismiss()
    }
}
