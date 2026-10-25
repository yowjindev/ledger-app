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
        try commit()
        Log.ledger.info("Updated a transaction")
    }

    /// Permanently deletes a transaction. Callers confirm with the user first.
    func delete(_ transaction: LedgerTransaction) throws {
        guard transaction.modelContext != nil, !transaction.isDeleted else {
            throw LedgerError.transactionNotFound
        }
        context.delete(transaction)
        try commit()
        Log.ledger.info("Deleted a transaction")
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
