import SwiftUI

/// One transaction in a list: symbol, category or "Transfer", account, time, signed amount, and type.
struct TransactionRow: View {
    let transaction: LedgerTransaction
    /// Show the date as well as the time (for lists that aren't grouped by day).
    var showsDate = false

    @Environment(\.moneyFormatter) private var formatter
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let summary = TransactionSummary(transaction)
        HStack(spacing: 12) {
            SymbolBadge(systemName: summary.symbolName, tint: LedgerTheme.badgeTint(for: summary.kind))
            if dynamicTypeSize.isAccessibilitySize {
                // Stacked so the amount gets the full width and never breaks mid-number.
                VStack(alignment: .leading, spacing: 4) {
                    details(summary)
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        amount(summary)
                        kind(summary)
                    }
                }
            } else {
                details(summary)
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    amount(summary)
                    kind(summary)
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(summary.accessibilityLabel(formatter: formatter))
    }

    private func details(_ summary: TransactionSummary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(summary.title)
                .font(.body)
                .lineLimit(1)
            // The account name gives way before the date and time, which are never cut off;
            // when even that doesn't fit, they move to a second line.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 4) {
                    Text(summary.accountLine)
                        .lineLimit(1)
                    Text("·")
                    Text(when(summary.occurredAt))
                        .lineLimit(1)
                        .fixedSize()
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text(summary.accountLine)
                        .lineLimit(1)
                    Text(when(summary.occurredAt))
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
    }

    private func amount(_ summary: TransactionSummary) -> some View {
        Text(summary.signedAmountText(formatter: formatter))
            .font(.body.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(LedgerTheme.amountColor(for: summary.kind))
            .lineLimit(1)
            .minimumScaleFactor(0.5)
    }

    private func kind(_ summary: TransactionSummary) -> some View {
        Text(summary.kind?.title ?? "")
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    /// Time only, or a short date and time when `showsDate` is set; the year appears only for
    /// earlier years.
    private func when(_ date: Date) -> String {
        guard showsDate else { return date.formatted(date: .omitted, time: .shortened) }
        let isThisYear = Calendar.current.isDate(date, equalTo: .now, toGranularity: .year)
        let style: Date.FormatStyle = isThisYear
            ? .dateTime.month(.abbreviated).day().hour().minute()
            : .dateTime.month(.abbreviated).day().year().hour().minute()
        return date.formatted(style)
    }
}
