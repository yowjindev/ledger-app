import SwiftUI

/// The first onboarding screen: what Ledger does, in three lines.
struct OnboardingWelcomeStep: View {
    let onContinue: () -> Void

    @ScaledMetric(relativeTo: .title2) private var symbolColumnWidth = 36

    var body: some View {
        ScrollView {
            VStack(spacing: 44) {
                VStack(spacing: 24) {
                    WelcomeAppGlyph()
                    Text("Welcome to Ledger")
                        .font(.largeTitle.bold())
                        .multilineTextAlignment(.center)
                }
                VStack(alignment: .leading, spacing: 28) {
                    feature("Log in seconds with the Action Button", systemImage: "bolt.fill")
                    feature("Balances come only from your own entries", systemImage: "square.and.pencil")
                    feature("Stored on this iPhone, no account needed", systemImage: "lock.iphone")
                }
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 40)
            .frame(maxWidth: .infinity)
        }
        .defaultScrollAnchor(.center, for: .alignment)
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaBar(edge: .bottom) {
            Button(action: onContinue) {
                ContrastingButtonTitle("Get Started", fillsWidth: true)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 24)
            .padding(.bottom, 12)
        }
        .toolbar(.hidden, for: .navigationBar)
    }

    private func feature(_ text: LocalizedStringKey, systemImage: String) -> some View {
        HStack(spacing: 16) {
            Image(systemName: systemImage)
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: symbolColumnWidth)
                .accessibilityHidden(true)
            Text(text)
                .font(.headline)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// The app icon's peso sign on its emerald tile. The colors match the icon artwork, which looks
/// the same in light and dark mode.
private struct WelcomeAppGlyph: View {
    var body: some View {
        Image(systemName: "pesosign")
            .font(.system(size: 50, weight: .semibold))
            .foregroundStyle(.white)
            .frame(width: 96, height: 96)
            .background(
                LinearGradient(
                    colors: [
                        Color(red: 0.020, green: 0.200, blue: 0.165),
                        Color(red: 0.047, green: 0.420, blue: 0.341),
                    ],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                ),
                in: .rect(cornerRadius: 22, style: .continuous)
            )
            .accessibilityHidden(true)
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        OnboardingWelcomeStep {}
    }
}
#endif
