import SwiftUI

/// A small notice that a newer version of AnyWhere is out, with a
/// button to the release page and a way to dismiss it. Shown on the main
/// screen and on the iPhone-only setup screen.
struct UpdateNoticeView: View {
    @Environment(UpdateChecker.self) private var updates
    @Environment(\.openURL) private var openURL

    var body: some View {
        if updates.updateAvailable {
            VStack(alignment: .leading, spacing: 8) {
                HStack(alignment: .top, spacing: 12) {
                    Image(systemName: "arrow.down.circle.fill")
                        .font(.system(size: 22, weight: .semibold))
                        .foregroundStyle(Brand.skyText)
                        .padding(.top, 2)
                        .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("A newer version is out")
                            .font(Brand.rounded(.subheadline))
                        Text(subtitle)
                            .font(.caption)
                            // Lighter than "secondary": that is too faint on the deep blue.
                            .foregroundStyle(.white.opacity(0.85))
                    }
                    .fixedSize(horizontal: false, vertical: true)
                    Spacer(minLength: 0)
                    Button {
                        withAnimation(Brand.spring) { updates.dismiss() }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 30, height: 30)
                            .glassCircle()
                            // The circle stays small to look right. The part that answers a tap is 44 points.
                            .frame(width: 44, height: 44)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Dismiss")
                    .accessibilityHint("Hides this notice until a newer version comes out.")
                    // The button is bigger than it looks. Pull it into the corner so the text keeps its width.
                    .padding(.trailing, -8)
                    .padding(.top, -8)
                }
                Button {
                    openURL(updates.releaseURL)
                } label: {
                    Text("Get").frame(maxWidth: .infinity).foregroundStyle(.white)
                }
                .glassButton()
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassSurface(cornerRadius: 18, tint: Brand.indigo)
            // The tint is a deep blue in light mode too, so the words are light on it.
            .environment(\.colorScheme, .dark)
            .tint(Brand.sky)
            .transition(.rise)
        }
    }

    private var subtitle: String {
        if let version = updates.latestVersion {
            return "Reinstall AnyWhere \(version) from the release page."
        }
        return "Reinstall AnyWhere from the release page."
    }
}
