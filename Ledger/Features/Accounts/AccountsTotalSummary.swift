import SwiftUI

/// The total liquid balance, with a note naming the active accounts it leaves out because their
/// opening balance isn't set. When no account can be counted, no amount is shown, since ₱0
/// would be a guess.
struct AccountsTotalSummary: View {
    let liquidTotal: LiquidTotal

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("Total Liquid")
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.secondary)
            if liquidTotal.includedAccountIDs.isEmpty {
                Text(LiquidTotalCopy.unavailable)
                    .font(.system(.title, design: .rounded, weight: .semibold))
                    .foregroundStyle(.secondary)
            } else {
                MoneyText(liquidTotal.total)
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
            }
            if let note = LiquidTotalCopy.note(for: liquidTotal) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .foregroundStyle(.orange)
                        .accessibilityHidden(true)
                    Text(note)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.footnote)
                .padding(.top, 4)
            } else if liquidTotal.includedAccountIDs.isEmpty {
                Text("No active accounts.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}
