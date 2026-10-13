import Foundation
import SwiftData
import SwiftUI

/// Every transaction involving one account, as source or destination, newest first and grouped
/// by month. Looks the account up by ID, so it copes with the account being deleted elsewhere.
struct AccountTransactionsView: View {
    let accountID: UUID

    @Query private var matches: [Account]
    @Query(sort: LedgerService.newestFirst) private var transactions: [LedgerTransaction]

    init(accountID: UUID) {
        self.accountID = accountID
        _matches = Query(filter: #Predicate<Account> { $0.id == accountID })
    }

    var body: some View {
        if let account = matches.first {
            let history = transactions.filter {
                $0.account?.id == accountID || $0.destinationAccount?.id == accountID
            }
            List {
                ForEach(AccountHistoryMonth.groups(of: history)) { group in
                    Section(group.title) {
                        ForEach(group.transactions) { transaction in
                            NavigationLink(value: LedgerRoute.transaction(transaction.id)) {
                                TransactionRow(transaction: transaction, showsDate: true)
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .overlay {
                if history.isEmpty {
                    ContentUnavailableView(
                        "No Transactions",
                        systemImage: "list.bullet.rectangle",
                        description: Text("Transactions involving this account appear here.")
                    )
                }
            }
            .navigationTitle("All Transactions")
            .navigationSubtitle(account.name)
            .navigationBarTitleDisplayMode(.inline)
        } else {
            ContentUnavailableView(
                "Account Not Found",
                systemImage: "questionmark.folder",
                description: Text("It may have been deleted.")
            )
        }
    }
}

/// Transactions that occurred in one calendar month.
@MainActor
private struct AccountHistoryMonth: Identifiable {
    /// Start of the month.
    let id: Date
    var transactions: [LedgerTransaction]

    var title: String { id.formatted(.dateTime.month(.wide).year()) }

    /// Groups transactions that are sorted newest first into months, keeping their order.
    static func groups(of transactions: [LedgerTransaction], calendar: Calendar = .current) -> [AccountHistoryMonth] {
        var groups: [AccountHistoryMonth] = []
        for transaction in transactions {
            let start = calendar.dateInterval(of: .month, for: transaction.occurredAt)?.start ?? transaction.occurredAt
            if groups.last?.id == start {
                groups[groups.count - 1].transactions.append(transaction)
            } else {
                groups.append(AccountHistoryMonth(id: start, transactions: [transaction]))
            }
        }
        return groups
    }
}

#if DEBUG
/// Shows the history of the first account in the preview container.
private struct AccountTransactionsPreviewHost: View {
    @Query(sort: \Account.sortOrder) private var accounts: [Account]

    var body: some View {
        if let account = accounts.first {
            AccountTransactionsView(accountID: account.id)
        }
    }
}

#Preview {
    NavigationStack {
        AccountTransactionsPreviewHost()
            .ledgerRouteDestinations()
    }
    .ledgerPreview()
}
#endif
