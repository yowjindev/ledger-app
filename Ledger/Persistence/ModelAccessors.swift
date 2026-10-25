import Foundation

extension Account {
    var kind: AccountKind { AccountKind(storedValue: kindRaw) }
    var currency: CurrencyCode { CurrencyCode(rawValue: currencyCode) }

    /// The opening balance, or `nil` if the user hasn't entered it.
    var openingBalance: Money? {
        openingBalanceMinor.map { Money(minorUnits: $0, currency: currency) }
    }

    var hasOpeningBalance: Bool { openingBalanceMinor != nil }

    /// How the account earns interest, or `nil` when it doesn't.
    var interestTerms: InterestTerms? {
        interestRatePPM.map {
            InterestTerms(annualRate: Rate(partsPerMillion: $0), taxRate: Rate(partsPerMillion: interestTaxRatePPM))
        }
    }

    /// When statements close and payments are due, or `nil` for accounts without a due day.
    var dueSchedule: DueSchedule? {
        dueDay.map { DueSchedule(statementDay: statementDay, dueDay: $0) }
    }

    var creditLimit: Money? {
        creditLimitMinor.map { Money(minorUnits: $0, currency: currency) }
    }

    /// Cashback earned on purchases, or `nil` when the account has none.
    var cashbackRate: Rate? {
        cashbackRatePPM.map(Rate.init(partsPerMillion:))
    }
}

extension PaymentPlan {
    var currency: CurrencyCode { account?.currency ?? .php }
    var monthly: Money { Money(minorUnits: monthlyMinor, currency: currency) }
    var last: Money { Money(minorUnits: lastMinor, currency: currency) }
    /// Every payment of the plan, including those made before it was added:
    /// monthly × (months − 1) + last.
    var total: Money { Money(minorUnits: monthlyMinor * Int64(max(months - 1, 0)) + lastMinor, currency: currency) }
    var firstDueDay: CalendarDay? { CalendarDay(storedValue: firstDue) }
}

extension Bill {
    /// Bills are kept in pesos, the currency every account uses.
    var currency: CurrencyCode { .php }
    /// The monthly amount, or `nil` when it varies.
    var amount: Money? { amountMinor.map { Money(minorUnits: $0, currency: currency) } }
    var schedule: DueSchedule { DueSchedule(statementDay: nil, dueDay: dueDay) }
}

extension DueOverride {
    var cycleMonth: CalendarMonth? { CalendarMonth(storedValue: cycle) }
    var movedToDay: CalendarDay? { movedTo.flatMap(CalendarDay.init(storedValue:)) }
}

extension LedgerCategory {
    /// Categories written by a newer app version with an unknown kind read as expense categories.
    var kind: CategoryKind { CategoryKind(rawValue: kindRaw) ?? .expense }
}

extension LedgerTransaction {
    /// `nil` only for records written by a newer app version with a kind this version doesn't know.
    var kind: TransactionKind? { TransactionKind(rawValue: kindRaw) }
    var status: TransactionStatus? { TransactionStatus(rawValue: statusRaw) }
    var origin: EntryOrigin { EntryOrigin(rawValue: originRaw) ?? .app }
    var currency: CurrencyCode { CurrencyCode(rawValue: currencyCode) }
    var amount: Money { Money(minorUnits: amountMinor, currency: currency) }
    /// Whether an adjustment raised or lowered the balance; `nil` for other kinds.
    var adjustmentDirection: AdjustmentDirection? { directionRaw.flatMap(AdjustmentDirection.init) }

    /// Whether the transaction editor may change this entry. Adjustments and automatic entries
    /// (interest, cashback, plan fees) are kept as Ledger recorded them, and a plan's purchase
    /// changes only with its plan.
    var isEditable: Bool {
        kind != .adjustment && ![.interest, .cashback, .planFees].contains(origin) && planID == nil
    }
}
