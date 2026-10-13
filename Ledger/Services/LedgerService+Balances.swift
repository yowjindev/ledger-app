import Foundation
import SwiftData

extension LedgerService {
    /// Balances of all accounts (archived included) and the liquid total.
    func balanceSheet(displayCurrency: CurrencyCode = .php) throws -> BalanceSheet {
        let accounts = try accounts(includeArchived: true)
        let transactions = try context.fetch(FetchDescriptor<LedgerTransaction>())
        return Self.balanceSheet(accounts: accounts, transactions: transactions, displayCurrency: displayCurrency)
    }

    /// Computes a balance sheet from models a view already fetched (for example with `@Query`),
    /// using the same calculation as `balanceSheet()`.
    static func balanceSheet(
        accounts: [Account],
        transactions: [LedgerTransaction],
        displayCurrency: CurrencyCode = .php
    ) -> BalanceSheet {
        BalanceCalculator.balanceSheet(
            accounts: accounts.map(AccountSnapshot.init),
            movements: transactions.compactMap(Movement.init),
            displayCurrency: displayCurrency
        )
    }

    func balance(of account: Account) throws -> AccountBalance? {
        try balanceSheet().balance(for: account.id)
    }

    /// Income, expenses, and net cash flow for transactions that occurred in `[start, end)`.
    func periodSummary(for interval: DateInterval, currency: CurrencyCode = .php) throws -> PeriodSummary {
        let start = interval.start
        let end = interval.end
        let descriptor = FetchDescriptor<LedgerTransaction>(
            predicate: #Predicate { $0.occurredAt >= start && $0.occurredAt < end }
        )
        return Self.periodSummary(transactions: try context.fetch(descriptor), in: interval, currency: currency)
    }

    /// Period summary over models a view already fetched, using the same calculation.
    static func periodSummary(
        transactions: [LedgerTransaction],
        in interval: DateInterval,
        currency: CurrencyCode = .php
    ) -> PeriodSummary {
        BalanceCalculator.periodSummary(
            movements: transactions.compactMap(Movement.init),
            in: interval,
            currency: currency
        )
    }
}

extension AccountSnapshot {
    @MainActor
    init(_ account: Account) {
        self.init(
            id: account.id,
            name: account.name,
            kind: account.kind,
            currency: account.currency,
            openingBalanceMinor: account.openingBalanceMinor,
            isArchived: account.isArchived,
            sortOrder: account.sortOrder
        )
    }
}

extension Movement {
    /// `nil` for records whose kind or status this app version doesn't know; they are left out
    /// of calculations rather than guessed at.
    @MainActor
    init?(_ transaction: LedgerTransaction) {
        guard let kind = transaction.kind, let status = transaction.status else { return nil }
        self.init(
            kind: kind,
            status: status,
            amountMinor: transaction.amountMinor,
            currency: transaction.currency,
            accountID: transaction.account?.id,
            destinationAccountID: transaction.destinationAccount?.id,
            occurredAt: transaction.occurredAt
        )
    }
}
