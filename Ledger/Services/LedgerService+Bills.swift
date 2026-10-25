import Foundation
import SwiftData
import os

/// The details of a regular monthly bill.
struct BillTerms: Equatable, Sendable {
    var name: String
    /// The expense category its payments are recorded in.
    var categoryID: UUID
    var dueDay: Int
    /// The monthly amount, or `nil` when it varies and is entered each month.
    var amount: Decimal?
    /// Day of the month a varying bill usually arrives.
    var arrivesDay: Int?
    var payFromAccountID: UUID?
}

extension LedgerService {
    // MARK: Queries

    /// Bills in display order. Archived bills are excluded unless requested.
    func bills(includeArchived: Bool = false) throws -> [Bill] {
        let sort = [SortDescriptor(\Bill.sortOrder), SortDescriptor(\Bill.createdAt)]
        if includeArchived {
            return try context.fetch(FetchDescriptor<Bill>(sortBy: sort))
        }
        return try context.fetch(FetchDescriptor<Bill>(predicate: #Predicate { !$0.isArchived }, sortBy: sort))
    }

    func bill(id: UUID) throws -> Bill? {
        var descriptor = FetchDescriptor<Bill>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    /// Payments recorded for a bill, newest first.
    func payments(for bill: Bill) throws -> [LedgerTransaction] {
        let key: UUID? = bill.id
        return try context.fetch(FetchDescriptor<LedgerTransaction>(
            predicate: #Predicate { $0.billID == key },
            sortBy: Self.newestFirst
        ))
    }

    /// Where a bill stands on its current due.
    func dueStatus(for bill: Bill) throws -> DueStatus {
        DueCalculator.status(try billDueInput(for: bill), today: today)
    }

    func billDueInput(for bill: Bill) throws -> BillDueInput {
        try Self.billDueInput(for: bill, payments: payments(for: bill), overrides: dueOverrides(for: bill.id))
    }

    static func billDueInput(for bill: Bill, payments: [LedgerTransaction], overrides: [DueOverride]) -> BillDueInput {
        var paid: [CalendarMonth: Int64] = [:]
        for payment in payments where payment.billID == bill.id && payment.status == .posted {
            guard let cycle = payment.billCycle.flatMap(CalendarMonth.init(storedValue:)) else { continue }
            paid[cycle, default: 0] += payment.amountMinor
        }
        return BillDueInput(
            billID: bill.id,
            schedule: bill.schedule,
            startCycle: CalendarMonth(storedValue: bill.startCycle) ?? CalendarMonth(year: 1, month: 1),
            amountMinor: bill.amountMinor,
            paidByCycle: paid,
            overrides: overrides.filter { $0.ownerID == bill.id }.compactMap(DueOverrideSnapshot.init),
            currency: bill.currency
        )
    }

    // MARK: Mutations

    /// Creates a bill, tracked from its first due date on or after today.
    @discardableResult
    func createBill(_ terms: BillTerms) throws -> Bill {
        let existing = try bills(includeArchived: true)
        let validated = try validatedBill(terms, existingNames: existing.map(\.name), currentCategoryID: nil)
        let schedule = DueSchedule(statementDay: nil, dueDay: terms.dueDay)
        let bill = Bill(
            name: validated.name,
            category: validated.category,
            dueDay: terms.dueDay,
            amountMinor: validated.amountMinor,
            arrivesDay: terms.arrivesDay,
            payFrom: validated.payFrom,
            createdAt: now,
            startCycle: schedule.cycle(dueOnOrAfter: today).storedValue,
            sortOrder: (existing.map(\.sortOrder).max() ?? -1) + 1
        )
        context.insert(bill)
        try commit()
        Log.ledger.info("Created a bill")
        return bill
    }

    func updateBill(_ bill: Bill, with terms: BillTerms) throws {
        guard bill.modelContext != nil, !bill.isDeleted else { throw LedgerError.billNotFound }
        let others = try bills(includeArchived: true).filter { $0.id != bill.id }
        let validated = try validatedBill(terms, existingNames: others.map(\.name), currentCategoryID: bill.category?.id)
        if let oldAmountMinor = bill.amountMinor, validated.amountMinor != oldAmountMinor {
            try keepAmount(oldAmountMinor, forPastCyclesOf: bill)
        }
        bill.name = validated.name
        bill.category = validated.category
        bill.dueDay = terms.dueDay
        bill.amountMinor = validated.amountMinor
        bill.arrivesDay = terms.arrivesDay
        bill.payFrom = validated.payFrom
        try commit()
        Log.ledger.info("Updated a bill")
    }

    /// Stops tracking a bill. Its payments stay in history.
    func archiveBill(_ bill: Bill) throws {
        guard !bill.isArchived else { return }
        bill.isArchived = true
        bill.archivedAt = now
        try commit()
        Log.ledger.info("Archived a bill")
    }

    func unarchiveBill(_ bill: Bill) throws {
        guard bill.isArchived else { return }
        bill.isArchived = false
        bill.archivedAt = nil
        try commit()
        Log.ledger.info("Unarchived a bill")
    }

    /// Deletes a bill that has no payments. Bills with payments can only be archived.
    func deleteBill(_ bill: Bill) throws {
        guard try payments(for: bill).isEmpty else { throw LedgerError.billHasPayments(name: bill.name) }
        for override in try dueOverrides(for: bill.id) {
            context.delete(override)
        }
        context.delete(bill)
        try commit()
        Log.ledger.info("Deleted a bill")
    }

    /// Sets one cycle's amount, such as this month's electricity bill once it arrives.
    func setAmount(_ amount: Decimal, for bill: Bill, cycle: CalendarMonth) throws {
        guard bill.modelContext != nil, !bill.isDeleted else { throw LedgerError.billNotFound }
        let amountMinor = try AmountRules.transactionMinorUnits(amount, currency: bill.currency)
        try dueOverride(for: bill.id, cycle: cycle).amountMinor = amountMinor
        try commit()
        Log.ledger.info("Set a bill's amount for one month")
    }

    /// Records a payment toward one cycle of a bill: an expense in the bill's category, tagged
    /// with the bill and cycle, in one save. For a bill whose amount varies and hasn't been
    /// entered for that cycle, the payment's amount becomes the cycle's amount.
    @discardableResult
    func payBill(
        _ bill: Bill,
        cycle: CalendarMonth,
        amount: Decimal,
        from accountID: UUID,
        occurredAt: Date,
        origin: EntryOrigin = .app
    ) throws -> LedgerTransaction {
        guard bill.modelContext != nil, !bill.isDeleted else { throw LedgerError.billNotFound }
        guard let categoryID = bill.category?.id else { throw LedgerError.missingCategory }
        let draft = TransactionDraft.expense(amount: amount, accountID: accountID, categoryID: categoryID, occurredAt: occurredAt)
        let resolved = try resolve(draft, editing: nil)
        let payment = insert(resolved, origin: origin)
        payment.billID = bill.id
        payment.billCycle = cycle.storedValue
        if bill.amountMinor == nil {
            let override = try dueOverride(for: bill.id, cycle: cycle)
            if override.amountMinor == nil {
                override.amountMinor = resolved.amountMinor
            }
        }
        try commit()
        Log.ledger.info("Recorded a bill payment")
        return payment
    }

    /// Records `amountMinor` on last month's cycle and every earlier cycle with payments, where no
    /// amount is set yet, so a new amount applies from the current due on and never rewrites the past.
    private func keepAmount(_ amountMinor: Int64, forPastCyclesOf bill: Bill) throws {
        let current = bill.schedule.cycle(dueOnOrAfter: today)
        let start = CalendarMonth(storedValue: bill.startCycle) ?? current
        var cycles = Set(try payments(for: bill).compactMap { $0.billCycle.flatMap(CalendarMonth.init(storedValue:)) })
        cycles.insert(current.adding(months: -1))
        for cycle in cycles where cycle >= start && cycle < current {
            let override = try dueOverride(for: bill.id, cycle: cycle)
            if override.amountMinor == nil {
                override.amountMinor = amountMinor
            }
        }
    }

    // MARK: Validation

    private struct ValidatedBill {
        let name: String
        let category: LedgerCategory
        let amountMinor: Int64?
        let payFrom: Account?
    }

    private func validatedBill(_ terms: BillTerms, existingNames: [String], currentCategoryID: UUID?) throws -> ValidatedBill {
        let name = try validatedName(terms.name, existingNames: existingNames)
        guard Self.dayRange.contains(terms.dueDay) else { throw LedgerError.dayOutOfRange }
        let amountMinor = try terms.amount.map { try AmountRules.transactionMinorUnits($0, currency: .php) }
        if let arrivesDay = terms.arrivesDay {
            guard amountMinor == nil else { throw LedgerError.arrivalDayNotApplicable }
            guard Self.dayRange.contains(arrivesDay) else { throw LedgerError.dayOutOfRange }
        }
        let category: LedgerCategory
        if terms.categoryID == currentCategoryID, let current = try self.category(id: terms.categoryID) {
            category = current
        } else {
            category = try expenseCategory(id: terms.categoryID)
        }
        let payFrom = try terms.payFromAccountID.map { id -> Account in
            guard let account = try account(id: id) else { throw LedgerError.accountNotFound }
            return account
        }
        return ValidatedBill(name: name, category: category, amountMinor: amountMinor, payFrom: payFrom)
    }
}

extension LedgerService {
    /// Moves one cycle's due date of an owed account or bill, leaving every other month as it
    /// is. The new date runs from today up to the day before the next cycle's due date; moving
    /// back to the usual date clears the move.
    func moveDue(of owner: DueOwner, cycle: CalendarMonth, to day: CalendarDay) throws {
        let ownerID: UUID
        let schedule: DueSchedule
        switch owner {
        case .account(let id):
            guard let account = try account(id: id), let accountSchedule = account.dueSchedule else {
                throw LedgerError.accountNotFound
            }
            ownerID = id
            schedule = accountSchedule
        case .bill(let id):
            guard let bill = try bill(id: id) else { throw LedgerError.billNotFound }
            ownerID = id
            schedule = bill.schedule
        }
        guard day >= today, day < schedule.dueDate(in: cycle.adding(months: 1)) else {
            throw LedgerError.moveDateOutOfRange
        }

        let override = try dueOverride(for: ownerID, cycle: cycle)
        if day == schedule.dueDate(in: cycle) {
            override.movedTo = nil
            if override.amountMinor == nil {
                context.delete(override)
            }
        } else {
            override.movedTo = day.storedValue
        }
        try commit()
        Log.ledger.info("Moved one due date")
    }

    /// The override for one cycle, inserted when there isn't one yet. Not saved.
    func dueOverride(for ownerID: UUID, cycle: CalendarMonth) throws -> DueOverride {
        if let existing = try dueOverrides(for: ownerID).first(where: { $0.cycle == cycle.storedValue }) {
            return existing
        }
        let override = DueOverride(ownerID: ownerID, cycle: cycle.storedValue)
        context.insert(override)
        return override
    }
}
