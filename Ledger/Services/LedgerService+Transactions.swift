import Foundation
import SwiftData
import os

/// Input for recording or editing a transaction.
struct TransactionDraft: Equatable, Sendable {
    var kind: TransactionKind
    /// Positive amount in major units (pesos).
    var amount: Decimal
    var occurredAt: Date
    /// Expense: account paid from. Income: account received into. Transfer: source account.
    var accountID: UUID?
    /// Transfer destination. Ignored for expenses and income.
    var destinationAccountID: UUID?
    /// Expense category or income source. Ignored for transfers.
    var categoryID: UUID?
    var note: String?
    var reference: String?

    init(
        kind: TransactionKind,
        amount: Decimal,
        occurredAt: Date,
        accountID: UUID? = nil,
        destinationAccountID: UUID? = nil,
        categoryID: UUID? = nil,
        note: String? = nil,
        reference: String? = nil
    ) {
        self.kind = kind
        self.amount = amount
        self.occurredAt = occurredAt
        self.accountID = accountID
        self.destinationAccountID = destinationAccountID
        self.categoryID = categoryID
        self.note = note
        self.reference = reference
    }

    static func expense(amount: Decimal, accountID: UUID, categoryID: UUID, occurredAt: Date, note: String? = nil) -> TransactionDraft {
        TransactionDraft(kind: .expense, amount: amount, occurredAt: occurredAt, accountID: accountID, categoryID: categoryID, note: note)
    }

    static func income(amount: Decimal, accountID: UUID, sourceID: UUID, occurredAt: Date, note: String? = nil) -> TransactionDraft {
        TransactionDraft(kind: .income, amount: amount, occurredAt: occurredAt, accountID: accountID, categoryID: sourceID, note: note)
    }

    static func transfer(amount: Decimal, fromAccountID: UUID, toAccountID: UUID, occurredAt: Date, note: String? = nil) -> TransactionDraft {
        TransactionDraft(kind: .transfer, amount: amount, occurredAt: occurredAt, accountID: fromAccountID, destinationAccountID: toAccountID, note: note)
    }
}

extension TransactionDraft {
    /// A draft prefilled from an existing transaction, for editing. `nil` if the transaction's
    /// kind is unknown to this app version or the entry isn't editable.
    @MainActor
    init?(_ transaction: LedgerTransaction) {
        guard let kind = transaction.kind, transaction.isEditable else { return nil }
        self.init(
            kind: kind,
            amount: transaction.amount.amount,
            occurredAt: transaction.occurredAt,
            accountID: transaction.account?.id,
            destinationAccountID: transaction.destinationAccount?.id,
            categoryID: transaction.category?.id,
            note: transaction.note,
            reference: transaction.reference
        )
    }
}

extension LedgerService {
    /// Seconds within which an identical entry is treated as a possible accidental repeat.
    static let possibleDuplicateWindow: TimeInterval = 120

    /// A draft that passed validation, with its references resolved to models.
    struct ResolvedDraft {
        let kind: TransactionKind
        let amountMinor: Int64
        let currency: CurrencyCode
        let occurredAt: Date
        let account: Account
        let destination: Account?
        let category: LedgerCategory?
        let note: String?
        let reference: String?
    }

    // MARK: Recording

    /// Validates and saves a new transaction.
    ///
    /// When `requestID` matches a transaction that was already saved, that transaction is returned
    /// and nothing new is inserted, so a repeated submission of one intended operation records it
    /// once. Separate submissions use different request IDs and are always recorded, even when
    /// their details are identical.
    @discardableResult
    func record(_ draft: TransactionDraft, origin: EntryOrigin = .app, requestID: UUID? = nil) throws -> LedgerTransaction {
        if let requestID, let existing = try transaction(requestID: requestID) {
            guard isSameOperation(existing, as: draft) else { throw LedgerError.conflictingRequest }
            Log.ledger.info("Ignored a repeated submission")
            return existing
        }
        let resolved = try resolve(draft, editing: nil)
        let transaction = insert(resolved, origin: origin, requestID: requestID)
        try commit()
        Log.ledger.info("Recorded a \(resolved.kind.rawValue, privacy: .public) transaction")
        return transaction
    }

    @discardableResult
    func recordExpense(
        amount: Decimal,
        accountID: UUID,
        categoryID: UUID,
        occurredAt: Date? = nil,
        note: String? = nil,
        origin: EntryOrigin = .app,
        requestID: UUID? = nil
    ) throws -> LedgerTransaction {
        try record(
            .expense(amount: amount, accountID: accountID, categoryID: categoryID, occurredAt: occurredAt ?? now, note: note),
            origin: origin,
            requestID: requestID
        )
    }

    @discardableResult
    func recordIncome(
        amount: Decimal,
        accountID: UUID,
        sourceID: UUID,
        occurredAt: Date? = nil,
        note: String? = nil,
        origin: EntryOrigin = .app,
        requestID: UUID? = nil
    ) throws -> LedgerTransaction {
        try record(
            .income(amount: amount, accountID: accountID, sourceID: sourceID, occurredAt: occurredAt ?? now, note: note),
            origin: origin,
            requestID: requestID
        )
    }

    /// Records a transfer as one record, so both account movements are saved atomically.
    @discardableResult
    func recordTransfer(
        amount: Decimal,
        fromAccountID: UUID,
        toAccountID: UUID,
        occurredAt: Date? = nil,
        note: String? = nil,
        origin: EntryOrigin = .app,
        requestID: UUID? = nil
    ) throws -> LedgerTransaction {
        try record(
            .transfer(amount: amount, fromAccountID: fromAccountID, toAccountID: toAccountID, occurredAt: occurredAt ?? now, note: note),
            origin: origin,
            requestID: requestID
        )
    }

    // MARK: Editing

    /// Replaces a transaction's details after validating them like a new entry. References the
    /// transaction already had stay valid even if their account or category was archived since.
    func update(_ transaction: LedgerTransaction, with draft: TransactionDraft) throws {
        guard transaction.modelContext != nil, !transaction.isDeleted else {
            throw LedgerError.transactionNotFound
        }
        guard transaction.isEditable else { throw LedgerError.entryNotEditable }
        let resolved = try resolve(draft, editing: transaction)
        let previousAccountID = transaction.account?.id
        let cashback = try cashback(for: transaction)
        transaction.kindRaw = resolved.kind.rawValue
        transaction.amountMinor = resolved.amountMinor
        transaction.currencyCode = resolved.currency.rawValue
        transaction.occurredAt = resolved.occurredAt
        transaction.account = resolved.account
        transaction.destinationAccount = resolved.destination
        transaction.category = resolved.category
        transaction.note = resolved.note
        transaction.reference = resolved.reference
        transaction.updatedAt = now
        updateCashback(cashback, for: transaction, previousAccountID: previousAccountID)
        try commit()
        Log.ledger.info("Updated a transaction")
    }

    /// Permanently deletes a transaction. Callers confirm with the user first.
    ///
    /// Deleting a plan's purchase or fees deletes the whole plan with both entries, so a plan
    /// never outlives what it paid for.
    func delete(_ transaction: LedgerTransaction) throws {
        guard transaction.modelContext != nil, !transaction.isDeleted else {
            throw LedgerError.transactionNotFound
        }
        if let planID = transaction.planID {
            if let plan = try plan(id: planID) {
                try deletePlan(plan)
                return
            }
            for entry in try planEntries(planID: planID) {
                context.delete(entry)
            }
            try commit()
            Log.ledger.info("Deleted a transaction")
            return
        }
        if let cashback = try cashback(for: transaction) {
            context.delete(cashback)
        }
        context.delete(transaction)
        try commit()
        Log.ledger.info("Deleted a transaction")
    }

    /// Inserts a validated transaction, with its cashback when it earns some, without saving.
    func insert(_ resolved: ResolvedDraft, origin: EntryOrigin, requestID: UUID? = nil) -> LedgerTransaction {
        let transaction = LedgerTransaction(
            kind: resolved.kind,
            amountMinor: resolved.amountMinor,
            currency: resolved.currency,
            occurredAt: resolved.occurredAt,
            createdAt: now,
            note: resolved.note,
            account: resolved.account,
            destinationAccount: resolved.destination,
            category: resolved.category,
            origin: origin,
            reference: resolved.reference,
            requestID: requestID
        )
        context.insert(transaction)
        if let rate = cashbackRate(for: transaction) {
            insertCashback(for: transaction, rate: rate)
        }
        return transaction
    }

    // MARK: Cashback

    /// The cashback entry recorded with a credit card purchase, if any.
    func cashback(for purchase: LedgerTransaction) throws -> LedgerTransaction? {
        let key: UUID? = purchase.id
        var descriptor = FetchDescriptor<LedgerTransaction>(predicate: #Predicate { $0.sourceTransactionID == key })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    /// The rate a purchase earns cashback at now: an expense entered by the user, outside a
    /// payment plan, on a credit card that has cashback. `nil` otherwise.
    private func cashbackRate(for transaction: LedgerTransaction) -> Rate? {
        guard
            transaction.kind == .expense,
            transaction.origin == .app || transaction.origin == .appIntent,
            transaction.planID == nil,
            let account = transaction.account,
            account.kind == .creditCard
        else { return nil }
        return account.cashbackRate
    }

    /// Adds cashback for a purchase at `rate`; nothing when it rounds down to zero.
    private func insertCashback(for purchase: LedgerTransaction, rate: Rate) {
        guard let account = purchase.account else { return }
        let amountMinor = CashbackCalculator.cashbackMinor(forPurchaseMinor: purchase.amountMinor, rate: rate)
        guard amountMinor > 0 else { return }
        let cashback = LedgerTransaction(
            kind: .income,
            amountMinor: amountMinor,
            currency: purchase.currency,
            occurredAt: purchase.occurredAt,
            createdAt: now,
            note: nil,
            account: account,
            destinationAccount: nil,
            category: nil,
            origin: .cashback,
            reference: nil,
            requestID: nil
        )
        cashback.basisMinor = purchase.amountMinor
        cashback.basisRatePPM = rate.partsPerMillion
        cashback.sourceTransactionID = purchase.id
        context.insert(cashback)
    }

    /// Keeps a purchase's cashback in step after an edit. On the same card it's recalculated at
    /// the rate it was earned at; moved off the card or no longer an expense, it's removed; moved
    /// onto a card with cashback, it's added at that card's rate.
    private func updateCashback(_ cashback: LedgerTransaction?, for purchase: LedgerTransaction, previousAccountID: UUID?) {
        guard let currentRate = cashbackRate(for: purchase) else {
            if let cashback { context.delete(cashback) }
            return
        }
        let sameAccount = purchase.account?.id == previousAccountID
        if let cashback {
            guard sameAccount, let earnedPPM = cashback.basisRatePPM else {
                context.delete(cashback)
                insertCashback(for: purchase, rate: currentRate)
                return
            }
            let amountMinor = CashbackCalculator.cashbackMinor(forPurchaseMinor: purchase.amountMinor, rate: Rate(partsPerMillion: earnedPPM))
            guard amountMinor > 0 else {
                context.delete(cashback)
                return
            }
            cashback.amountMinor = amountMinor
            cashback.basisMinor = purchase.amountMinor
            cashback.occurredAt = purchase.occurredAt
            cashback.updatedAt = now
        } else if !sameAccount {
            insertCashback(for: purchase, rate: currentRate)
        }
    }

    // MARK: Duplicate detection

    /// Returns a transaction identical to `draft` (same kind, amount, accounts, and category)
    /// that was created within `window`, if any. Callers ask the user to confirm before recording
    /// again; identical entries are never discarded automatically.
    func recentDuplicate(of draft: TransactionDraft, within window: TimeInterval = possibleDuplicateWindow) throws -> LedgerTransaction? {
        guard
            let accountID = draft.accountID,
            let account = try account(id: accountID),
            let minorUnits = account.currency.exactMinorUnits(for: draft.amount)
        else { return nil }
        let cutoff = now.addingTimeInterval(-window)
        let kindRaw = draft.kind.rawValue
        let descriptor = FetchDescriptor<LedgerTransaction>(
            predicate: #Predicate { $0.createdAt >= cutoff && $0.kindRaw == kindRaw && $0.amountMinor == minorUnits },
            sortBy: [SortDescriptor(\.createdAt, order: .reverse)]
        )
        return try context.fetch(descriptor).first { isSameOperation($0, as: draft) }
    }

    // MARK: Validation

    /// Validates a draft against the ledger rules and resolves its references.
    /// - Parameter existing: The transaction being edited, if any.
    func resolve(_ draft: TransactionDraft, editing existing: LedgerTransaction?) throws -> ResolvedDraft {
        let previouslyReferencedAccounts = Set([existing?.account?.id, existing?.destinationAccount?.id].compactMap { $0 })

        guard let accountID = draft.accountID else { throw LedgerError.missingAccount }
        let account = try usableAccount(id: accountID, allowingArchived: previouslyReferencedAccounts)
        let currency = account.currency
        let amountMinor = try AmountRules.transactionMinorUnits(draft.amount, currency: currency)
        let note = try normalizedText(draft.note, limit: Self.noteLengthLimit)
        let reference = try normalizedText(draft.reference, limit: Self.referenceLengthLimit)

        switch draft.kind {
        case .expense, .income:
            guard let categoryID = draft.categoryID else { throw LedgerError.missingCategory }
            guard let category = try category(id: categoryID) else { throw LedgerError.categoryNotFound }
            let expectedKind: CategoryKind = draft.kind == .expense ? .expense : .income
            guard category.kind == expectedKind else {
                throw LedgerError.categoryKindMismatch(expected: expectedKind)
            }
            if category.isArchived && existing?.category?.id != category.id {
                throw LedgerError.categoryArchived(name: category.name)
            }
            return ResolvedDraft(
                kind: draft.kind,
                amountMinor: amountMinor,
                currency: currency,
                occurredAt: draft.occurredAt,
                account: account,
                destination: nil,
                category: category,
                note: note,
                reference: reference
            )
        case .transfer:
            guard let destinationID = draft.destinationAccountID else {
                throw LedgerError.missingDestinationAccount
            }
            guard destinationID != accountID else { throw LedgerError.sameSourceAndDestination }
            let destination = try usableAccount(id: destinationID, allowingArchived: previouslyReferencedAccounts)
            guard destination.currency == currency else { throw LedgerError.currencyMismatch }
            return ResolvedDraft(
                kind: .transfer,
                amountMinor: amountMinor,
                currency: currency,
                occurredAt: draft.occurredAt,
                account: account,
                destination: destination,
                category: nil,
                note: note,
                reference: reference
            )
        case .adjustment:
            throw LedgerError.entryNotEditable
        }
    }

    private func usableAccount(id: UUID, allowingArchived allowed: Set<UUID>) throws -> Account {
        guard let account = try account(id: id) else { throw LedgerError.accountNotFound }
        if account.isArchived && !allowed.contains(account.id) {
            throw LedgerError.accountArchived(name: account.name)
        }
        return account
    }

    /// Whether a saved transaction represents the same intended operation as a draft.
    private func isSameOperation(_ transaction: LedgerTransaction, as draft: TransactionDraft) -> Bool {
        guard
            transaction.kind == draft.kind,
            transaction.account?.id == draft.accountID,
            transaction.currency.exactMinorUnits(for: draft.amount) == transaction.amountMinor
        else { return false }
        switch draft.kind {
        case .expense, .income:
            return transaction.category?.id == draft.categoryID
        case .transfer:
            return transaction.destinationAccount?.id == draft.destinationAccountID
        case .adjustment:
            return false
        }
    }

    // MARK: Queries

    func transaction(id: UUID) throws -> LedgerTransaction? {
        var descriptor = FetchDescriptor<LedgerTransaction>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    /// Transactions carrying a reference, such as a bank reference number.
    func transactions(withReference reference: String) throws -> [LedgerTransaction] {
        let key: String? = reference
        return try context.fetch(FetchDescriptor<LedgerTransaction>(predicate: #Predicate { $0.reference == key }))
    }

    func transaction(requestID: UUID) throws -> LedgerTransaction? {
        let key: UUID? = requestID
        var descriptor = FetchDescriptor<LedgerTransaction>(predicate: #Predicate { $0.requestID == key })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    /// Transaction history, newest first. A `limit` of zero or less returns no transactions;
    /// SwiftData would treat a fetch limit of zero as no limit at all.
    func transactions(limit: Int? = nil) throws -> [LedgerTransaction] {
        if let limit, limit <= 0 { return [] }
        var descriptor = FetchDescriptor<LedgerTransaction>(sortBy: Self.newestFirst)
        descriptor.fetchLimit = limit
        return try context.fetch(descriptor)
    }

    func recentTransactions(limit: Int = 10) throws -> [LedgerTransaction] {
        try transactions(limit: limit)
    }

    /// Transactions that move money in or out of an account, newest first.
    func transactions(involving account: Account) throws -> [LedgerTransaction] {
        let id = account.id
        return try transactions().filter { $0.account?.id == id || $0.destinationAccount?.id == id }
    }

    /// Sort order for history: most recent first, ties broken by entry time.
    static var newestFirst: [SortDescriptor<LedgerTransaction>] {
        [SortDescriptor(\.occurredAt, order: .reverse), SortDescriptor(\.createdAt, order: .reverse)]
    }
}
