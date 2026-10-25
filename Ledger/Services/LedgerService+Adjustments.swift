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
    /// Accounts that owe money use `owedCorrection(toOwe:for:)` instead.
    func balanceCorrection(toReach actual: Decimal, for account: Account) throws -> BalanceCorrection {
        guard account.modelContext != nil, !account.isDeleted else { throw LedgerError.accountNotFound }
        guard !account.kind.isOwed else { throw LedgerError.wrongAccountGroup }
        guard !actual.isNaN, actual >= .zero else { throw LedgerError.balanceNegative }
        _ = try AmountRules.openingBalanceMinorUnits(actual, currency: account.currency)
        guard !account.isArchived else { throw LedgerError.accountArchived(name: account.name) }

        return try correction(reaching: actual, for: account) { activity in
            try openingBalanceMinorUnits(forCurrentBalance: actual, of: account, activity: activity)
        }
    }

    /// Brings an account to its real balance in one save: sets the opening balance when it isn't
    /// known yet, otherwise records one adjustment for the difference. Interest already due is
    /// posted first, so the difference is measured against an up-to-date balance. Returns what it did.
    @discardableResult
    func updateBalance(of account: Account, to actual: Decimal, origin: EntryOrigin = .app) throws -> BalanceCorrection {
        try postDueInterest()
        let correction = try balanceCorrection(toReach: actual, for: account)
        try apply(correction, to: account, origin: origin)
        return correction
    }

    /// Describes what `updateOwed(of:to:origin:)` would record for a credit card, pay later
    /// account, or loan, without changing anything. `owed` may be zero but not negative.
    func owedCorrection(toOwe owed: Decimal, for account: Account) throws -> BalanceCorrection {
        guard account.modelContext != nil, !account.isDeleted else { throw LedgerError.accountNotFound }
        guard account.kind.isOwed else { throw LedgerError.wrongAccountGroup }
        let owedMinor = try AmountRules.owedMinorUnits(owed, currency: account.currency)
        guard !account.isArchived else { throw LedgerError.accountArchived(name: account.name) }

        let target = -Money(minorUnits: owedMinor, currency: account.currency).amount
        return try correction(reaching: target, for: account) { activity in
            try AmountRules.signedBalanceMinorUnits(target - (activity?.amount ?? .zero), currency: account.currency)
        }
    }

    /// Brings what an owed account owes to `owed` in one save, the same way `updateBalance`
    /// brings a balance to the real one. Returns what it did.
    @discardableResult
    func updateOwed(of account: Account, to owed: Decimal, origin: EntryOrigin = .app) throws -> BalanceCorrection {
        let correction = try owedCorrection(toOwe: owed, for: account)
        try apply(correction, to: account, origin: origin)
        return correction
    }

    // MARK: Shared

    /// What reaching the signed balance `target` changes. Without an opening balance,
    /// `openingMinor` turns the account's recorded activity into the opening balance to set.
    private func correction(
        reaching target: Decimal,
        for account: Account,
        openingMinor: (Money?) throws -> Int64
    ) throws -> BalanceCorrection {
        let balance = try balance(of: account)
        guard let current = balance?.currentBalance else {
            let opening = try openingMinor(balance?.netActivity)
            return .setOpeningBalance(Money(minorUnits: opening, currency: account.currency))
        }
        let difference = target - current.amount
        return difference.isZero ? .alreadyMatches : .adjustment(Money(difference, currency: account.currency))
    }

    private func apply(_ correction: BalanceCorrection, to account: Account, origin: EntryOrigin) throws {
        switch correction {
        case .alreadyMatches:
            return
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
    }
}
