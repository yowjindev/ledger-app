import Foundation
import SwiftData
import os

extension LedgerService {
    // MARK: Queries

    func account(id: UUID) throws -> Account? {
        var descriptor = FetchDescriptor<Account>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    /// Accounts in display order. Archived accounts are excluded unless requested.
    func accounts(includeArchived: Bool = false) throws -> [Account] {
        let sort = [SortDescriptor(\Account.sortOrder), SortDescriptor(\Account.createdAt)]
        if includeArchived {
            return try context.fetch(FetchDescriptor<Account>(sortBy: sort))
        }
        return try context.fetch(FetchDescriptor<Account>(predicate: #Predicate { !$0.isArchived }, sortBy: sort))
    }

    /// Number of transactions that reference the account in any role.
    func transactionCount(for account: Account) throws -> Int {
        let id = account.id
        return try context.fetch(FetchDescriptor<LedgerTransaction>()).count {
            $0.account?.id == id || $0.destinationAccount?.id == id
        }
    }

    // MARK: Mutations

    /// Creates an account. A `nil` opening balance means "not entered yet", never zero.
    @discardableResult
    func createAccount(
        name: String,
        kind: AccountKind,
        openingBalance: Decimal?,
        currency: CurrencyCode = .php
    ) throws -> Account {
        let existing = try accounts(includeArchived: true)
        let cleanName = try validatedName(name, existingNames: existing.map(\.name))
        let openingMinor = try openingBalance.map { try AmountRules.openingBalanceMinorUnits($0, currency: currency) }
        let account = Account(
            name: cleanName,
            kind: kind,
            currency: currency,
            openingBalanceMinor: openingMinor,
            createdAt: now,
            sortOrder: (existing.map(\.sortOrder).max() ?? -1) + 1
        )
        context.insert(account)
        try commit()
        Log.ledger.info("Created an account")
        return account
    }

    /// Renames an account, changes its kind, or corrects its opening balance. Transactions keep
    /// referencing the same account, so history shows the new name.
    func updateAccount(_ account: Account, name: String, kind: AccountKind, openingBalance: Decimal?) throws {
        let others = try accounts(includeArchived: true).filter { $0.id != account.id }
        let cleanName = try validatedName(name, existingNames: others.map(\.name))
        let openingMinor = try openingBalance.map {
            try AmountRules.openingBalanceMinorUnits($0, currency: account.currency)
        }
        account.name = cleanName
        account.kindRaw = kind.rawValue
        account.openingBalanceMinor = openingMinor
        try commit()
        Log.ledger.info("Updated an account")
    }

    /// Sets or clears (`nil`) an account's opening balance.
    func setOpeningBalance(_ openingBalance: Decimal?, for account: Account) throws {
        account.openingBalanceMinor = try openingBalance.map {
            try AmountRules.openingBalanceMinorUnits($0, currency: account.currency)
        }
        try commit()
    }

    /// Hides an account from pickers and the liquid total. Its transactions stay in history and
    /// keep affecting the other accounts they involve.
    func archiveAccount(_ account: Account) throws {
        guard !account.isArchived else { return }
        account.isArchived = true
        account.archivedAt = now
        try commit()
        Log.ledger.info("Archived an account")
    }

    /// Restores an archived account to its previous position, or after the other accounts if
    /// another account has taken that position since.
    func unarchiveAccount(_ account: Account) throws {
        guard account.isArchived else { return }
        let otherOrders = try accounts(includeArchived: true).filter { $0.id != account.id }.map(\.sortOrder)
        account.isArchived = false
        account.archivedAt = nil
        if otherOrders.contains(account.sortOrder) {
            account.sortOrder = (otherOrders.max() ?? -1) + 1
        }
        try commit()
        Log.ledger.info("Unarchived an account")
    }

    /// Deletes an account that no transaction references. Accounts with history can only be archived.
    func deleteAccount(_ account: Account) throws {
        guard try transactionCount(for: account) == 0 else {
            throw LedgerError.accountHasTransactions(name: account.name)
        }
        context.delete(account)
        try commit()
        Log.ledger.info("Deleted an account")
    }

    // MARK: First-run setup

    /// Applies first-run setup in a single save, so either every change is recorded or none is.
    ///
    /// For each account the user enters what it holds now. Activity already recorded for it (for
    /// example entries logged through Shortcuts before setup) is subtracted, so the stored opening
    /// balance makes the current balance equal what was entered. Accounts the user doesn't use are
    /// deleted when no transaction references them and archived otherwise.
    func applySetup(_ choices: [AccountSetupChoice]) throws {
        let sheet = try balanceSheet()
        let referenced = Set(try context.fetch(FetchDescriptor<LedgerTransaction>()).flatMap {
            [$0.account?.id, $0.destinationAccount?.id].compactMap { $0 }
        })

        // Validate every choice before changing anything.
        var plan: [(account: Account, change: AccountSetupChange)] = []
        for choice in choices {
            guard let account = try account(id: choice.accountID) else { throw LedgerError.accountNotFound }
            if choice.isUsed {
                let openingMinor = try choice.currentBalance.map {
                    try openingBalanceMinorUnits(forCurrentBalance: $0, of: account, activity: sheet.balance(for: account.id)?.netActivity)
                }
                if openingMinor != account.openingBalanceMinor {
                    plan.append((account, .openingBalance(openingMinor)))
                }
            } else {
                plan.append((account, referenced.contains(account.id) ? .archive : .delete))
            }
        }
        guard !plan.isEmpty else { return }

        for (account, change) in plan {
            switch change {
            case .openingBalance(let minorUnits):
                account.openingBalanceMinor = minorUnits
            case .archive:
                account.isArchived = true
                account.archivedAt = now
            case .delete:
                context.delete(account)
            }
        }
        try commit()
        Log.ledger.info("Applied first-run account setup")
    }

    /// The opening balance, in minor units, that makes `currentBalance` the account's current
    /// balance given the activity already recorded for it.
    private func openingBalanceMinorUnits(forCurrentBalance currentBalance: Decimal, of account: Account, activity: Money?) throws -> Int64 {
        _ = try AmountRules.openingBalanceMinorUnits(currentBalance, currency: account.currency)
        let opening = currentBalance - (activity?.amount ?? .zero)
        guard opening >= .zero else { throw LedgerError.balanceBelowRecordedActivity(name: account.name) }
        return try AmountRules.openingBalanceMinorUnits(opening, currency: account.currency)
    }

    /// Persists a new display order (also used by App Intents pickers).
    func reorderAccounts(_ ordered: [Account]) throws {
        for (index, account) in ordered.enumerated() where account.sortOrder != index {
            account.sortOrder = index
        }
        try commit()
    }
}

/// One account's choices from first-run setup.
struct AccountSetupChoice: Equatable, Sendable {
    let accountID: UUID
    /// `false` removes the account: deleted when no transaction uses it, otherwise archived.
    var isUsed: Bool
    /// What the account holds right now, or `nil` to leave its opening balance unset.
    var currentBalance: Decimal?
}

private enum AccountSetupChange {
    case openingBalance(Int64?)
    case archive
    case delete
}
