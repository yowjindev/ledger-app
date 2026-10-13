import SwiftUI

/// An account in a list: kind symbol, name, kind, and current balance with the opening balance
/// beneath it. Without an opening balance it says so and shows no current balance.
struct AccountListRow: View {
    let balance: AccountBalance

    @Environment(\.moneyFormatter) private var formatter
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let stacksVertically = dynamicTypeSize.isAccessibilitySize
        let layout = stacksVertically
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 6))
            : AnyLayout(HStackLayout(alignment: .center, spacing: 12))
        layout {
            HStack(spacing: 12) {
                SymbolBadge(
                    systemName: account.kind.systemImage,
                    tint: account.isArchived ? .secondary : .accentColor
                )
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.name)
                        .font(.body)
                    Text(account.kind.title)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            if !stacksVertically {
                Spacer(minLength: 8)
            }
            balanceColumn(alignment: stacksVertically ? .leading : .trailing)
                .padding(.leading, stacksVertically ? 48 : 0)
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var account: AccountSnapshot { balance.account }

    @ViewBuilder
    private func balanceColumn(alignment: HorizontalAlignment) -> some View {
        if let current = balance.currentBalance, let opening = balance.openingBalance {
            VStack(alignment: alignment, spacing: 2) {
                MoneyText(current)
                    .font(.body.weight(.semibold))
                Text("Opening \(formatter.string(opening))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        } else {
            // Beside the name it always takes two lines, like the amount and caption shown when
            // the balance is known. Below the name it wraps only as needed.
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Image(systemName: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange)
                Text(alignment == .trailing ? "Opening balance\nnot set" : "Opening balance not set")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(alignment == .trailing ? .trailing : .leading)
            }
            .font(.subheadline)
        }
    }

    /// For example "GCash, E-wallet, current balance ₱3,881.00, opening balance ₱4,230.00".
    private var accessibilityText: String {
        var parts = [account.name, account.kind.title]
        if account.isArchived {
            parts.append("Archived")
        }
        if let current = balance.currentBalance, let opening = balance.openingBalance {
            parts.append("current balance \(formatter.string(current, alwaysShowCentavos: true))")
            parts.append("opening balance \(formatter.string(opening, alwaysShowCentavos: true))")
        } else {
            parts.append("opening balance not set, current balance unknown")
        }
        return parts.joined(separator: ", ")
    }
}
