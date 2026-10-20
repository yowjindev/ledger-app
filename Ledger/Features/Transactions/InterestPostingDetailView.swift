import Foundation
import SwiftData
import SwiftUI

/// One moment's automatic interest: for each account, the balance it was calculated on, the rate,
/// the gross interest, the withholding tax, and what was added. Read-only; a difference from the
/// bank is fixed with Update Balance.
struct InterestPostingDetailView: View {
    let postedAt: Date
    /// Shows only this account's interest, or every account's when `nil`.
    let accountID: UUID?

    @Environment(\.moneyFormatter) private var formatter
    @Query private var entries: [LedgerTransaction]

    init(postedAt: Date, accountID: UUID?) {
        self.postedAt = postedAt
        self.accountID = accountID
        let origin = EntryOrigin.interest.rawValue
        _entries = Query(filter: #Predicate<LedgerTransaction> { $0.occurredAt == postedAt && $0.originRaw == origin })
    }

    var body: some View {
        let posting = InterestPosting(postedAt: postedAt, entries: entries)
        let accounts = posting.breakdown(for: accountID)
        Group {
            if accounts.isEmpty {
                ContentUnavailableView(
                    "Interest Not Found",
                    systemImage: TransactionSummary.interestSymbolName,
                    description: Text("It may have been removed.")
                )
            } else {
                content(accounts)
            }
        }
        .navigationTitle(TransactionSummary.interestTitle)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func content(_ accounts: [AccountInterest]) -> some View {
        let currency = accounts.first?.gross.currency ?? .php
        let net = accounts.reduce(Money.zero(currency)) { $0 + $1.net }
        return List {
            Section {
                VStack(spacing: 8) {
                    SymbolBadge(systemName: TransactionSummary.interestSymbolName, tint: LedgerTheme.income, size: 52)
                    LargeAmountText(formatter.string(net, sign: .always, alwaysShowCentavos: true))
                    Text("Added \(postedAt.formatted(date: .abbreviated, time: .shortened))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
                .accessibilityElement(children: .combine)
                .listRowBackground(Color.clear)
            }

            ForEach(accounts) { account in
                Section(account.accountName) {
                    LabeledContent("Balance") {
                        if let balance = account.balance {
                            MoneyText(balance, alwaysShowCentavos: true)
                        } else {
                            Text("Unknown")
                        }
                    }
                    if let rate = account.annualRate {
                        LabeledContent("Rate", value: "\(AccountsCopy.percentText(rate)) a year")
                    }
                    LabeledContent("Interest") { signed(account.gross) }
                    LabeledContent(taxTitle(account)) { signed(-account.tax) }
                    LabeledContent("Added") { signed(account.net) }
                        .fontWeight(.semibold)
                }
            }

            Section {
            } footer: {
                Text(AccountsCopy.interestFooter)
            }
        }
        .listStyle(.insetGrouped)
    }

    /// "Withholding Tax (20%)", or without the rate when no tax was withheld.
    private func taxTitle(_ account: AccountInterest) -> String {
        guard let rate = account.taxRate else { return "Withholding Tax" }
        return "Withholding Tax (\(AccountsCopy.percentText(rate)))"
    }

    /// A sign for every non-zero amount, so direction never depends on color.
    private func signed(_ money: Money) -> some View {
        Text(formatter.string(money, sign: money.isZero ? .never : .always, alwaysShowCentavos: true))
            .monospacedDigit()
    }
}
