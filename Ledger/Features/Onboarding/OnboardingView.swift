import SwiftUI

/// First-run setup, shown full screen until it's finished or skipped: a welcome, opening
/// balances for the starting accounts, and how to put Ledger on the Action Button.
struct OnboardingView: View {
    /// Setup screens in order. They're separate steps rather than swipeable pages, so opening
    /// balances are saved, and any error shown, before the last step appears.
    enum Step: Hashable {
        case welcome
        case openingBalances
        case actionButton
    }

    let onFinish: () -> Void

    @State private var step: Step

    init(onFinish: @escaping () -> Void) {
        self.init(startingAt: .welcome, onFinish: onFinish)
    }

    /// Starts at a later step, for previews.
    init(startingAt step: Step, onFinish: @escaping () -> Void) {
        self.onFinish = onFinish
        _step = State(initialValue: step)
    }

    var body: some View {
        NavigationStack {
            switch step {
            case .welcome:
                OnboardingWelcomeStep {
                    show(.openingBalances)
                }
            case .openingBalances:
                OnboardingBalancesStep(onSkip: onFinish) {
                    show(.actionButton)
                }
            case .actionButton:
                OnboardingActionButtonStep(onDone: onFinish)
            }
        }
    }

    private func show(_ next: Step) {
        withAnimation {
            step = next
        }
    }
}

#if DEBUG
#Preview("Welcome") {
    OnboardingView {}
        .ledgerPreview(sampleData: false)
}

#Preview("Opening Balances") {
    OnboardingView(startingAt: .openingBalances) {}
        .ledgerPreview(sampleData: false)
}

#Preview("Action Button") {
    OnboardingView(startingAt: .actionButton) {}
        .ledgerPreview(sampleData: false)
}
#endif
