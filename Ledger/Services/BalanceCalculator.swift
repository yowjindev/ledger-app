import Foundation

/// An immutable copy of the account fields the calculations need.
struct AccountSnapshot: Identifiable, Hashable, Sendable {
    let id: UUID
    let name: String
    let kind: AccountKind
    let currency: CurrencyCode
    /// `nil` until the user enters an opening balance.
    let openingBalanceMinor: Int64?
    let isArchived: Bool
    let sortOrder: Int
}

/// An immutable copy of the transaction fields the calculations need.
struct Movement: Hashable, Sendable {
    let kind: TransactionKind
    let status: TransactionStatus
    /// Always positive, in minor units.
    let amountMinor: Int64
    let currency: CurrencyCode
    let accountID: UUID?
    let destinationAccountID: UUID?
    let occurredAt: Date
}

/// An account's balance derived from its opening balance and posted transactions.
struct AccountBalance: Identifiable, Hashable, Sendable {
    let account: AccountSnapshot
    let income: Money
    let expenses: Money
    let transfersIn: Money
    let transfersOut: Money

    var id: UUID { account.id }

    /// `nil` until the user enters an opening balance.
    var openingBalance: Money? {
        account.openingBalanceMinor.map { Money(minorUnits: $0, currency: account.currency) }
    }

    /// Net change from recorded transactions: income + transfers in − expenses − transfers out.
    var netActivity: Money { income + transfersIn - expenses - transfersOut }

    /// Opening balance plus net activity. `nil` while the opening balance is unknown, because
    /// the current balance can't be known either.
    var currentBalance: Money? { openingBalance.map { $0 + netActivity } }
}

/// The total of liquid account balances.
struct LiquidTotal: Hashable, Sendable {
    /// Sum of the current balances of `includedAccountIDs`.
    let total: Money
    /// Active liquid accounts whose balances are included.
    let includedAccountIDs: [UUID]
    /// Active liquid accounts left out because their opening balance hasn't been entered.
    let accountsMissingOpeningBalance: [AccountSnapshot]

    /// Whether every active liquid account is included.
    var isComplete: Bool { accountsMissingOpeningBalance.isEmpty }
}

/// Balances for a set of accounts plus their liquid total.
struct BalanceSheet: Hashable, Sendable {
    /// One entry per account, in display order, archived accounts included.
    let balances: [AccountBalance]
    let liquidTotal: LiquidTotal

    var activeBalances: [AccountBalance] { balances.filter { !$0.account.isArchived } }
    var archivedBalances: [AccountBalance] { balances.filter { $0.account.isArchived } }

    func balance(for accountID: UUID) -> AccountBalance? {
        balances.first { $0.id == accountID }
    }
}

/// Income and expenses within a date interval. Transfers are excluded: they move money
/// between the user's own accounts and are neither income nor expense.
struct PeriodSummary: Hashable, Sendable {
    let interval: DateInterval
    let income: Money
    let expenses: Money
    let incomeCount: Int
    let expenseCount: Int

    /// Net cash flow: income − expenses.
    var net: Money { income - expenses }
}

/// Pure financial calculations over immutable snapshots. No persistence access, so the same
/// arithmetic serves the app, App Intents, and tests.
enum BalanceCalculator {
    /// Computes each account's balance:
    /// opening balance + posted income + incoming transfers − posted expenses − outgoing transfers.
    ///
    /// Each posted transaction affects each involved account exactly once. A movement is applied
    /// only to accounts that use the same currency as the movement.
    static func balances(accounts: [AccountSnapshot], movements: [Movement]) -> [AccountBalance] {
        let currencies = Dictionary(accounts.map { ($0.id, $0.currency) }, uniquingKeysWith: { first, _ in first })
        var totals: [UUID: Totals] = [:]

        func apply(_ amount: Decimal, to accountID: UUID?, currency: CurrencyCode, _ field: WritableKeyPath<Totals, Decimal>) {
            guard let accountID, currencies[accountID] == currency else { return }
            totals[accountID, default: Totals()][keyPath: field] += amount
        }

        for movement in movements where movement.status == .posted {
            let amount = Decimal(movement.amountMinor) / movement.currency.minorUnitScale
            switch movement.kind {
            case .expense:
                apply(amount, to: movement.accountID, currency: movement.currency, \.expenses)
            case .income:
                apply(amount, to: movement.accountID, currency: movement.currency, \.income)
            case .transfer:
                apply(amount, to: movement.accountID, currency: movement.currency, \.transfersOut)
                apply(amount, to: movement.destinationAccountID, currency: movement.currency, \.transfersIn)
            }
        }

        return accounts.sorted(by: displayOrder).map { account in
            let accountTotals = totals[account.id] ?? Totals()
            return AccountBalance(
                account: account,
                income: Money(accountTotals.income, currency: account.currency),
                expenses: Money(accountTotals.expenses, currency: account.currency),
                transfersIn: Money(accountTotals.transfersIn, currency: account.currency),
                transfersOut: Money(accountTotals.transfersOut, currency: account.currency)
            )
        }
    }

    /// Sums the current balances of active, liquid accounts in `currency`. Accounts without an
    /// opening balance are listed instead of being counted as zero.
    static func liquidTotal(of balances: [AccountBalance], currency: CurrencyCode) -> LiquidTotal {
        var total = Decimal.zero
        var included: [UUID] = []
        var missing: [AccountSnapshot] = []
        for balance in balances
        where !balance.account.isArchived && balance.account.kind.countsTowardLiquidTotal && balance.account.currency == currency {
            if let current = balance.currentBalance {
                total += current.amount
                included.append(balance.id)
            } else {
                missing.append(balance.account)
            }
        }
        return LiquidTotal(
            total: Money(total, currency: currency),
            includedAccountIDs: included,
            accountsMissingOpeningBalance: missing
        )
    }

    static func balanceSheet(accounts: [AccountSnapshot], movements: [Movement], displayCurrency: CurrencyCode) -> BalanceSheet {
        let balances = balances(accounts: accounts, movements: movements)
        return BalanceSheet(balances: balances, liquidTotal: liquidTotal(of: balances, currency: displayCurrency))
    }

    /// Posted income and expenses in `currency` that occurred in `[interval.start, interval.end)`.
    static func periodSummary(movements: [Movement], in interval: DateInterval, currency: CurrencyCode) -> PeriodSummary {
        var income = Decimal.zero
        var expenses = Decimal.zero
        var incomeCount = 0
        var expenseCount = 0
        for movement in movements
        where movement.status == .posted
            && movement.currency == currency
            && movement.occurredAt >= interval.start
            && movement.occurredAt < interval.end {
            let amount = Decimal(movement.amountMinor) / movement.currency.minorUnitScale
            switch movement.kind {
            case .income:
                income += amount
                incomeCount += 1
            case .expense:
                expenses += amount
                expenseCount += 1
            case .transfer:
                break
            }
        }
        return PeriodSummary(
            interval: interval,
            income: Money(income, currency: currency),
            expenses: Money(expenses, currency: currency),
            incomeCount: incomeCount,
            expenseCount: expenseCount
        )
    }

    private static func displayOrder(_ lhs: AccountSnapshot, _ rhs: AccountSnapshot) -> Bool {
        if lhs.sortOrder != rhs.sortOrder { return lhs.sortOrder < rhs.sortOrder }
        return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
    }

    private struct Totals {
        var income = Decimal.zero
        var expenses = Decimal.zero
        var transfersIn = Decimal.zero
        var transfersOut = Decimal.zero
    }
}
