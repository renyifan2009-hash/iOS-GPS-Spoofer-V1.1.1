import SwiftUI

/// A small notice that a newer version of iOS GPS Spoofer is out, with a
/// button to the release page and a way to dismiss it. Shown on the main
/// screen and on the iPhone-only setup screen.
struct UpdateNoticeView: View {
    @Environment(UpdateChecker.self) private var updates
    @Environment(\.openURL) private var openURL

    var body: some View {
        if updates.updateAvailable {
            HStack(spacing: 12) {
                Image(systemName: "arrow.down.circle.fill")
                    .font(.system(size: 22, weight: .semibold))
                    .foregroundStyle(Brand.sky)
                VStack(alignment: .leading, spacing: 2) {
                    Text("A newer version is out")
                        .font(Brand.rounded(.subheadline))
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 8)
                Button("Get") { openURL(updates.releaseURL) }
                    .glassButton()
                    .fixedSize()
                Button {
                    withAnimation(Brand.spring) { updates.dismiss() }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(.secondary)
                        .frame(width: 30, height: 30)
                        .glassCircle()
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss")
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .glassSurface(cornerRadius: 18, tint: Brand.indigo)
            .transition(.rise)
        }
    }

    private var subtitle: String {
        if let version = updates.latestVersion {
            return "Reinstall SpoofRemote \(version) from the release page."
        }
        return "Reinstall SpoofRemote from the release page."
    }
}
