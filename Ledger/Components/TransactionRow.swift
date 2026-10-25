import SwiftUI

/// One transaction in a list: symbol, category or "Transfer", account, time, signed amount, and type.
struct TransactionRow: View {
    let transaction: LedgerTransaction
    /// Show the date as well as the time (for lists that aren't grouped by day).
    var showsDate = false

    @Environment(\.moneyFormatter) private var formatter

    var body: some View {
        let summary = TransactionSummary(transaction)
        HistoryRowLayout(
            symbolName: summary.symbolName,
            tint: LedgerTheme.badgeTint(for: summary.kind),
            title: summary.title,
            accountLine: summary.accountLine,
            occurredAt: summary.occurredAt,
            amountText: summary.signedAmountText(formatter: formatter),
            amountColor: LedgerTheme.amountColor(for: summary.kind),
            caption: summary.kind?.title ?? "",
            accessibilityLabel: summary.accessibilityLabel(formatter: formatter),
            showsDate: showsDate
        )
    }
}

/// The layout of a history row: symbol, title, account and time, then the signed amount over a caption.
struct HistoryRowLayout: View {
    let symbolName: String
    let tint: Color
    let title: String
    let accountLine: String
    let occurredAt: Date
    let amountText: String
    let amountColor: Color
    let caption: String
    let accessibilityLabel: String
    var showsDate = false

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        HStack(spacing: 12) {
            SymbolBadge(systemName: symbolName, tint: tint)
            if dynamicTypeSize.isAccessibilitySize {
                // Stacked so the amount gets the full width and never breaks mid-number.
                VStack(alignment: .leading, spacing: 4) {
                    details
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        amount
                        captionText
                    }
                }
            } else {
                details
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 2) {
                    amount
                    captionText
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
    }

    private var details: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(.body)
                .lineLimit(1)
            // The account name gives way before the date and time, which are never cut off;
            // when even that doesn't fit, they move to a second line.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 4) {
                    Text(accountLine)
                        .lineLimit(1)
                    Text("·")
                    Text(when)
                        .lineLimit(1)
                        .fixedSize()
                }
                VStack(alignment: .leading, spacing: 0) {
                    Text(accountLine)
                        .lineLimit(1)
                    Text(when)
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
    }

    private var amount: some View {
        Text(amountText)
            .font(.body.weight(.semibold))
            .monospacedDigit()
            .foregroundStyle(amountColor)
            .lineLimit(1)
            .minimumScaleFactor(0.5)
    }

    private var captionText: some View {
        Text(caption)
            .font(.caption)
            .foregroundStyle(.secondary)
    }

    /// Time only, or a short date and time when `showsDate` is set; the year appears only for
    /// earlier years.
    private var when: String {
        guard showsDate else { return occurredAt.formatted(date: .omitted, time: .shortened) }
        let isThisYear = Calendar.current.isDate(occurredAt, equalTo: .now, toGranularity: .year)
        let style: Date.FormatStyle = isThisYear
            ? .dateTime.month(.abbreviated).day().hour().minute()
            : .dateTime.month(.abbreviated).day().year().hour().minute()
        return occurredAt.formatted(style)
    }
}
