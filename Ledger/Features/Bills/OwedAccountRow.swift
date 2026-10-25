import SwiftUI

/// A credit card, pay later account, or loan in a list: what it owes, and beneath it what's
/// left of its limit, or a detail line such as "6 of 12 paid".
struct OwedAccountRow: View {
    let balance: AccountBalance
    /// What's left of the limit, when the account has one.
    var available: Money?
    /// Replaces the limit line, for example a loan's progress.
    var detail: String?

    @Environment(\.moneyFormatter) private var formatter

    var body: some View {
        AdaptiveRowLayout {
            HStack(spacing: 12) {
                SymbolBadge(systemName: account.kind.systemImage, tint: account.isArchived ? .secondary : .accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.name)
                    Text(account.kind.title)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        } trailing: {
            VStack(alignment: .trailing, spacing: 2) {
                if let owed = balance.owed {
                    Text(owed.isNegative ? "\(formatter.string(owed.magnitude)) credit" : formatter.string(owed))
                        .font(.body.weight(.semibold))
                        .monospacedDigit()
                } else {
                    Text("Not set")
                        .foregroundStyle(.secondary)
                }
                if let caption {
                    Text(caption)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var account: AccountSnapshot { balance.account }

    private var caption: String? {
        if let detail { return detail }
        return available.map { "\(formatter.string($0)) left of limit" }
    }

    private var accessibilityText: String {
        var parts = [account.name, account.kind.title]
        if let owed = balance.owed {
            parts.append(owed.isNegative
                ? "credit \(formatter.string(owed.magnitude, alwaysShowCentavos: true))"
                : "owes \(formatter.string(owed, alwaysShowCentavos: true))")
        }
        if let caption { parts.append(caption) }
        return parts.joined(separator: ", ")
    }
}
