import Foundation
import SwiftData
import os

/// What bringing an account to its real balance changes.
enum BalanceCorrection: Equatable, Sendable {
    /// Ledger's balance already equals the real balance.
    case alreadyMatches
    /// The account had no opening balance; it is set to this amount.
    case setOpeningBalance(Money)
    /// A balance adjustment of this signed amount: positive raises the balance.
    case adjustment(Money)
}

extension LedgerService {
    /// Describes what `updateBalance(of:to:origin:)` would record, without changing anything.
    ///
    /// The real balance may be zero but not negative, and follows the opening balance limits.
    func balanceCorrection(toReach actual: Decimal, for account: Account) throws -> BalanceCorrection {
        guard account.modelContext != nil, !account.isDeleted else { throw LedgerError.accountNotFound }
        guard !actual.isNaN, actual >= .zero else { throw LedgerError.balanceNegative }
        _ = try AmountRules.openingBalanceMinorUnits(actual, currency: account.currency)
        guard !account.isArchived else { throw LedgerError.accountArchived(name: account.name) }

        let balance = try balance(of: account)
        guard let current = balance?.currentBalance else {
            let openingMinor = try openingBalanceMinorUnits(forCurrentBalance: actual, of: account, activity: balance?.netActivity)
            return .setOpeningBalance(Money(minorUnits: openingMinor, currency: account.currency))
        }
        let difference = actual - current.amount
        return difference.isZero ? .alreadyMatches : .adjustment(Money(difference, currency: account.currency))
    }

    /// Brings an account to its real balance in one save: sets the opening balance when it isn't
    /// known yet, otherwise records one adjustment for the difference. Interest already due is
    /// posted first, so the difference is measured against an up-to-date balance. Returns what it did.
    @discardableResult
    func updateBalance(of account: Account, to actual: Decimal, origin: EntryOrigin = .app) throws -> BalanceCorrection {
        try postDueInterest()
        let correction = try balanceCorrection(toReach: actual, for: account)
        switch correction {
        case .alreadyMatches:
            return correction
        case .setOpeningBalance(let opening):
            account.openingBalanceMinor = opening.minorUnits
            try commit()
            Log.ledger.info("Set an opening balance from a real balance")
        case .adjustment(let difference):
            let amountMinor = try AmountRules.transactionMinorUnits(difference.magnitude.amount, currency: account.currency)
            let adjustment = LedgerTransaction(
                kind: .adjustment,
                amountMinor: amountMinor,
                currency: account.currency,
                occurredAt: now,
                createdAt: now,
                note: nil,
                account: account,
                destinationAccount: nil,
                category: nil,
                origin: origin,
                reference: nil,
                requestID: nil
            )
            adjustment.directionRaw = (difference.isPositive ? AdjustmentDirection.increase : .decrease).rawValue
            context.insert(adjustment)
            try commit()
            Log.ledger.info("Recorded a balance adjustment")
        }
        return correction
    }
}
