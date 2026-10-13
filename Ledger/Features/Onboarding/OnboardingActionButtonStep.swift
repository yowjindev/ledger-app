import SwiftUI

/// The last onboarding step: how to run Ledger from the Action Button.
struct OnboardingActionButtonStep: View {
    let onDone: () -> Void

    @ScaledMetric(relativeTo: .title2) private var numberColumnWidth = 32

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 32) {
                VStack(spacing: 16) {
                    SymbolBadge(systemName: "button.vertical.left.press.fill", size: 88)
                    Text("Set Up the Action Button")
                        .font(.largeTitle.bold())
                    Text("Press it to log a transaction in seconds, from anywhere.")
                        .font(.body)
                        .foregroundStyle(.secondary)
                }
                .multilineTextAlignment(.center)
                .frame(maxWidth: .infinity)

                VStack(alignment: .leading, spacing: 20) {
                    instruction(1, "Open **Settings** and tap **Action Button**.")
                    instruction(2, "Swipe to **Shortcut**, then tap **Choose a Shortcut**.")
                    instruction(3, "Choose **Ledger**, then **Ledger Menu**, or **Log Expense** for the fastest expense logging.")
                }

                Text("On an iPhone without an Action Button, you can run the same shortcuts with Siri or from Spotlight. The full guide is in Ledger Settings.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 32)
            .padding(.vertical, 40)
        }
        .defaultScrollAnchor(.center, for: .alignment)
        .scrollBounceBehavior(.basedOnSize)
        .safeAreaBar(edge: .bottom) {
            Button(action: onDone) {
                ContrastingButtonTitle("Done", fillsWidth: true)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.horizontal, 24)
            .padding(.bottom, 12)
        }
        .toolbar(.hidden, for: .navigationBar)
    }

    private func instruction(_ number: Int, _ text: LocalizedStringKey) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 14) {
            Image(systemName: "\(number).circle.fill")
                .font(.title2)
                .foregroundStyle(.tint)
                .frame(width: numberColumnWidth)
                .accessibilityHidden(true)
            Text(text)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(Text("Step \(number): \(Text(text))"))
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        OnboardingActionButtonStep {}
    }
}
#endif
