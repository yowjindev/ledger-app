import Foundation

extension Account {
    var kind: AccountKind { AccountKind(storedValue: kindRaw) }
    var currency: CurrencyCode { CurrencyCode(rawValue: currencyCode) }

    /// The opening balance, or `nil` if the user hasn't entered it.
    var openingBalance: Money? {
        openingBalanceMinor.map { Money(minorUnits: $0, currency: currency) }
    }

    var hasOpeningBalance: Bool { openingBalanceMinor != nil }
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

    /// Whether the transaction editor may change this entry. Adjustments are corrected with
    /// another Update Balance instead.
    var isEditable: Bool { kind != .adjustment }
}
