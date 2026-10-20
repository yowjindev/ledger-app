import Foundation

/// One row of transaction history: a transaction, or the automatic interest and tax entries
/// credited at one moment.
enum HistoryItem: Identifiable {
    case transaction(LedgerTransaction)
    case interest(InterestPosting)

    var id: String {
        switch self {
        case .transaction(let transaction): "transaction-\(transaction.id.uuidString)"
        case .interest(let posting): "interest-\(posting.postedAt.timeIntervalSinceReferenceDate)"
        }
    }

    /// Keeps the order of `transactions`, replacing every automatic interest or tax entry with one
    /// `InterestPosting` per moment, placed where its first entry appears.
    @MainActor
    static func items(from transactions: [LedgerTransaction]) -> [HistoryItem] {
        enum Slot {
            case transaction(LedgerTransaction)
            case posting(Date)
        }
        var slots: [Slot] = []
        var postings: [Date: [LedgerTransaction]] = [:]
        for transaction in transactions {
            guard transaction.origin == .interest else {
                slots.append(.transaction(transaction))
                continue
            }
            if postings[transaction.occurredAt] == nil {
                slots.append(.posting(transaction.occurredAt))
            }
            postings[transaction.occurredAt, default: []].append(transaction)
        }
        return slots.map { slot in
            switch slot {
            case .transaction(let transaction):
                .transaction(transaction)
            case .posting(let date):
                .interest(InterestPosting(postedAt: date, entries: postings[date] ?? []))
            }
        }
    }
}

/// The automatic interest and tax entries credited at one moment, shown as one row.
struct InterestPosting: Identifiable {
    let postedAt: Date
    /// In the order given.
    let entries: [LedgerTransaction]
    /// Interest entries minus tax entries.
    let net: Money
    /// Names of the credited accounts, alphabetical.
    let accountNames: [String]
    /// Each credited account's figures, in display order.
    let breakdown: [AccountInterest]

    var id: Date { postedAt }

    @MainActor
    init(postedAt: Date, entries: [LedgerTransaction]) {
        self.postedAt = postedAt
        self.entries = entries
        let currency = entries.first?.currency ?? .php
        let total = entries.reduce(Decimal.zero) { sum, entry in
            entry.kind == .expense ? sum - entry.amount.amount : sum + entry.amount.amount
        }
        net = Money(total, currency: currency)

        let byAccount = Dictionary(grouping: entries.filter { $0.account != nil }) { $0.account?.id }
        breakdown = byAccount.values.compactMap(AccountInterest.init).sorted {
            ($0.sortOrder, $0.accountName) < ($1.sortOrder, $1.accountName)
        }
        accountNames = breakdown.map(\.accountName).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// The breakdown of one account, or of every account when `accountID` is `nil`.
    func breakdown(for accountID: UUID?) -> [AccountInterest] {
        guard let accountID else { return breakdown }
        return breakdown.filter { $0.accountID == accountID }
    }

    /// "Savings", or "2 accounts".
    var accountLine: String {
        accountNames.count == 1 ? accountNames[0] : "\(accountNames.count) accounts"
    }

    /// "+₱2.90", with a sign so the direction reads without color.
    func signedNetText(formatter: MoneyFormatter) -> String {
        formatter.string(net, sign: .always)
    }

    /// Spoken description, for example "Interest after tax, +₱2.90, Savings, October 20, 2026 at 1:00 AM".
    func accessibilityLabel(formatter: MoneyFormatter) -> String {
        let amount = formatter.string(net, sign: .always, alwaysShowCentavos: true)
        return "\(TransactionSummary.interestTitle) after tax, \(amount), \(accountLine), \(postedAt.formatted(date: .long, time: .shortened))"
    }
}

/// One account's interest and withholding tax for one day.
struct AccountInterest: Identifiable {
    let accountID: UUID
    let accountName: String
    let sortOrder: Int
    /// The day's ending balance the interest was calculated on.
    let balance: Money?
    let annualRate: Rate?
    let gross: Money
    let taxRate: Rate?
    let tax: Money

    var id: UUID { accountID }
    var net: Money { gross - tax }

    /// The figures from one account's entries; `nil` when they have no account.
    @MainActor
    init?(_ entries: [LedgerTransaction]) {
        guard let account = entries.first?.account else { return nil }
        let currency = account.currency
        let interest = entries.first { $0.kind == .income }
        let taxEntry = entries.first { $0.kind == .expense }
        accountID = account.id
        accountName = account.name
        sortOrder = account.sortOrder
        balance = interest?.basisMinor.map { Money(minorUnits: $0, currency: currency) }
        annualRate = interest?.basisRatePPM.map(Rate.init)
        gross = interest?.amount ?? .zero(currency)
        taxRate = taxEntry?.basisRatePPM.map(Rate.init)
        tax = taxEntry?.amount ?? .zero(currency)
    }
}
