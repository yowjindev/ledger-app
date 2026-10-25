import Foundation
import SwiftUI

/// One day's automatic interest in a list, net of withholding tax, or the part of it a filter shows.
struct InterestPostingRow: View {
    let posting: InterestPosting
    /// Show the date as well as the time (for lists that aren't grouped by day).
    var showsDate = false

    @Environment(\.moneyFormatter) private var formatter

    var body: some View {
        HistoryRowLayout(
            symbolName: TransactionSummary.interestSymbolName,
            tint: LedgerTheme.badgeTint(for: posting.includesInterest ? .income : .expense),
            title: posting.title,
            accountLine: posting.accountLine,
            occurredAt: posting.postedAt,
            amountText: posting.signedNetText(formatter: formatter),
            amountColor: posting.net.isNegative ? .primary : LedgerTheme.income,
            caption: posting.caption,
            accessibilityLabel: posting.accessibilityLabel(formatter: formatter),
            showsDate: showsDate
        )
    }
}

/// A history row that opens its details: the transaction, or the interest credited at that moment.
struct HistoryItemLink: View {
    let item: HistoryItem
    /// Show the date as well as the time (for lists that aren't grouped by day).
    var showsDate = false
    /// Narrows an interest row's details to this account.
    var accountID: UUID?

    var body: some View {
        switch item {
        case .transaction(let transaction):
            NavigationLink(value: LedgerRoute.transaction(transaction.id)) {
                TransactionRow(transaction: transaction, showsDate: showsDate)
            }
        case .interest(let posting):
            NavigationLink(value: LedgerRoute.interest(postedAt: posting.postedAt, accountID: accountID)) {
                InterestPostingRow(posting: posting, showsDate: showsDate)
            }
        }
    }
}
