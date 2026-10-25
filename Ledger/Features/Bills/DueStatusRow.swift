import SwiftUI

/// One due in Coming up: what it's for, when it's due, and what's left to pay. Overdue dues are
/// marked in red with an icon, so the state never depends on color alone.
struct DueStatusRow: View {
    let status: DueStatus
    let name: String
    let systemImage: String
    let today: CalendarDay
    let calendar: Calendar

    @Environment(\.moneyFormatter) private var formatter

    var body: some View {
        let date = DueStatusCopy.dateText(status, today: today, calendar: calendar)
        let amount = DueStatusCopy.amountText(status, formatter: formatter)
        AdaptiveRowLayout {
            HStack(spacing: 12) {
                SymbolBadge(systemName: systemImage, tint: status.isOverdue ? .red : .accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                    HStack(spacing: 4) {
                        if status.isOverdue {
                            Image(systemName: "exclamationmark.circle.fill")
                        }
                        Text(date)
                    }
                    .font(.subheadline)
                    .foregroundStyle(status.isOverdue ? .red : .secondary)
                }
            }
        } trailing: {
            Text(amount)
                .font(.body.weight(status.isPaid ? .regular : .semibold))
                .foregroundStyle(status.isPaid || status.left == nil ? .secondary : .primary)
                .monospacedDigit()
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(name), \(date), \(amount)")
    }
}
