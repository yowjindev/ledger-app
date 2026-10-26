import Foundation
import SwiftData
import os

/// A pay later purchase split into monthly payments.
struct SplitPurchase: Equatable, Sendable {
    /// The price, recorded as the purchase.
    var amount: Decimal
    var accountID: UUID
    var categoryID: UUID
    var occurredAt: Date
    var note: String?
    var months: Int
    /// Each monthly payment, as the pay later app shows it.
    var monthly: Decimal
    /// The last payment when it differs from the others; `nil` means the same as `monthly`.
    var last: Decimal?
}

/// The payments of a split or loan that's already under way, or of a new loan.
struct PlanTerms: Equatable, Sendable {
    var title: String
    var monthly: Decimal
    var last: Decimal?
    var months: Int
    /// Payments already made.
    var paidAtStart: Int
    /// Due date of the next payment to make.
    var nextDue: CalendarDay
    /// The item's price, for a split already under way. The payments' total less this is the
    /// plan's fees.
    var price: Decimal?
}

/// The item a new loan paid for.
struct LoanPurchase: Equatable, Sendable {
    var price: Decimal
    var categoryID: UUID
    var occurredAt: Date
}

extension LedgerService {
    /// Months a pay later purchase can be split into.
    static let splitMonths = 1...60
    /// Months a loan can run for.
    static let loanMonths = 1...60

    // MARK: Recording

    /// Records a split pay later purchase in one save: the price as an expense in its category,
    /// the extra the payments cost over it as a fees entry, and the plan. The first payment is
    /// due on the due date of the statement the purchase is billed in.
    @discardableResult
    func recordSplitPurchase(_ split: SplitPurchase, origin: EntryOrigin = .app) throws -> PaymentPlan {
        guard let account = try account(id: split.accountID) else { throw LedgerError.accountNotFound }
        guard account.kind == .payLater, let schedule = account.dueSchedule else { throw LedgerError.splitNotOffered }
        guard Self.splitMonths.contains(split.months) else {
            throw LedgerError.planMonthsOutOfRange(range: Self.splitMonths)
        }
        let draft = TransactionDraft.expense(
            amount: split.amount,
            accountID: split.accountID,
            categoryID: split.categoryID,
            occurredAt: split.occurredAt,
            note: split.note
        )
        let resolved = try resolve(draft, editing: nil)
        let amounts = try planAmounts(monthly: split.monthly, last: split.last, months: split.months, currency: resolved.currency)
        let feesMinor = amounts.totalMinor - resolved.amountMinor
        guard feesMinor >= 0 else { throw LedgerError.planTotalBelowPrice }

        let purchaseDay = CalendarDay(containing: split.occurredAt, calendar: calendar)
        let plan = PaymentPlan(
            title: resolved.note ?? resolved.category?.name ?? "",
            account: account,
            monthlyMinor: amounts.monthlyMinor,
            lastMinor: amounts.lastMinor,
            months: split.months,
            paidAtStart: 0,
            firstDue: schedule.dueDate(in: schedule.billingCycle(for: purchaseDay)).storedValue,
            createdAt: now
        )
        context.insert(plan)
        insertPlanEntries(
            for: plan,
            account: account,
            priceMinor: resolved.amountMinor,
            feesMinor: feesMinor,
            category: resolved.category,
            occurredAt: split.occurredAt,
            note: resolved.note,
            origin: origin
        )
        try commit()
        Log.ledger.info("Recorded a split purchase")
        return plan
    }

    /// Adds payments that are already under way: a split on a pay later account, or a loan's
    /// payments in place of a plan that was deleted. The purchase happened before Ledger, and what
    /// the account owes already includes it, so no entries are recorded. With the item's price,
    /// the plan stores its fees.
    @discardableResult
    func addExistingPlan(_ terms: PlanTerms, to account: Account) throws -> PaymentPlan {
        guard account.modelContext != nil, !account.isDeleted else { throw LedgerError.accountNotFound }
        guard account.kind == .payLater || account.kind == .loan, let schedule = account.dueSchedule else {
            throw LedgerError.splitNotOffered
        }
        guard !account.isArchived else { throw LedgerError.accountArchived(name: account.name) }
        let months = account.kind == .loan ? Self.loanMonths : Self.splitMonths
        let validated = try validatedPlan(terms, months: months, currency: account.currency)
        guard schedule.dueDate(in: CalendarMonth(containing: terms.nextDue)) == terms.nextDue else {
            throw LedgerError.dueDateNotOnSchedule
        }
        var feesMinor: Int64?
        if let price = terms.price {
            let priceMinor = try AmountRules.transactionMinorUnits(price, currency: account.currency)
            let fees = validated.amounts.totalMinor - priceMinor
            guard fees >= 0 else { throw LedgerError.planTotalBelowPrice }
            feesMinor = fees
        }
        let plan = makePlan(validated, terms: terms, account: account)
        plan.feesMinor = feesMinor
        context.insert(plan)
        try commit()
        Log.ledger.info("Added a payment plan")
        return plan
    }

    /// Creates a loan account and its plan in one save, due each month on `terms.nextDue`'s day.
    ///
    /// Without a purchase, the loan is already under way: it starts out owing its remaining
    /// payments. With one, it's new: it starts at zero and records the item as an expense in its
    /// category plus the extra the payments cost as fees, which requires no payments made yet.
    @discardableResult
    func createLoan(name: String, terms: PlanTerms, purchase: LoanPurchase?, currency: CurrencyCode = .php) throws -> Account {
        let existing = try accounts(includeArchived: true)
        let cleanName = try validatedName(name, existingNames: existing.map(\.name))
        let validated = try validatedPlan(terms, months: Self.loanMonths, currency: currency)
        if purchase != nil, terms.paidAtStart != 0 { throw LedgerError.paidMonthsOutOfRange }

        var item: (priceMinor: Int64, category: LedgerCategory, feesMinor: Int64)?
        if let purchase {
            let priceMinor = try AmountRules.transactionMinorUnits(purchase.price, currency: currency)
            let category = try expenseCategory(id: purchase.categoryID)
            let feesMinor = validated.amounts.totalMinor - priceMinor
            guard feesMinor >= 0 else { throw LedgerError.planTotalBelowPrice }
            item = (priceMinor, category, feesMinor)
        }

        let account = Account(
            name: cleanName,
            kind: .loan,
            currency: currency,
            openingBalanceMinor: item == nil ? -validated.remainingMinor : 0,
            createdAt: now,
            sortOrder: (existing.map(\.sortOrder).max() ?? -1) + 1
        )
        account.dueDay = terms.nextDue.day
        context.insert(account)
        let plan = makePlan(validated, terms: terms, account: account)
        context.insert(plan)
        if let item, let purchase {
            insertPlanEntries(
                for: plan,
                account: account,
                priceMinor: item.priceMinor,
                feesMinor: item.feesMinor,
                category: item.category,
                occurredAt: purchase.occurredAt,
                note: nil,
                origin: .app
            )
        }
        try commit()
        Log.ledger.info("Created a loan")
        return account
    }

    // MARK: Reading

    /// An account's payment plans, oldest first.
    func plans(for account: Account) throws -> [PaymentPlan] {
        (account.plans ?? []).sorted { $0.createdAt < $1.createdAt }
    }

    func plan(id: UUID) throws -> PaymentPlan? {
        var descriptor = FetchDescriptor<PaymentPlan>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    /// Payments of `plan` made so far, following the account's dues.
    func monthsPaid(_ plan: PaymentPlan) throws -> Int {
        guard
            let account = plan.account,
            let snapshot = PlanSnapshot(plan),
            let input = try owedDueInput(for: account)
        else { return plan.paidAtStart }
        return DueCalculator.monthsPaid(snapshot, input, today: today, calendar: calendar)
    }

    // MARK: Deleting

    /// Deletes a plan with the purchase and fees entries recorded with it, in one save.
    func deletePlan(_ plan: PaymentPlan) throws {
        guard plan.modelContext != nil, !plan.isDeleted else { throw LedgerError.transactionNotFound }
        for entry in try planEntries(planID: plan.id) {
            context.delete(entry)
        }
        context.delete(plan)
        try commit()
        Log.ledger.info("Deleted a payment plan")
    }

    /// Entries recorded with a plan: its purchase and its fees.
    func planEntries(planID: UUID) throws -> [LedgerTransaction] {
        let key: UUID? = planID
        return try context.fetch(FetchDescriptor<LedgerTransaction>(predicate: #Predicate { $0.planID == key }))
    }

    // MARK: Helpers

    private struct PlanAmounts {
        let monthlyMinor: Int64
        let lastMinor: Int64
        let months: Int

        /// Every payment: monthly × (months − 1) + last.
        var totalMinor: Int64 { monthlyMinor * Int64(months - 1) + lastMinor }
    }

    private struct ValidatedPlan {
        let title: String
        let amounts: PlanAmounts
        let paidAtStart: Int

        /// The payments still to make.
        var remainingMinor: Int64 {
            let remaining = amounts.months - paidAtStart
            return amounts.monthlyMinor * Int64(remaining - 1) + amounts.lastMinor
        }
    }

    private func planAmounts(monthly: Decimal, last: Decimal?, months: Int, currency: CurrencyCode) throws -> PlanAmounts {
        let monthlyMinor = try AmountRules.transactionMinorUnits(monthly, currency: currency)
        let lastMinor = try last.map { try AmountRules.transactionMinorUnits($0, currency: currency) } ?? monthlyMinor
        return PlanAmounts(monthlyMinor: monthlyMinor, lastMinor: lastMinor, months: months)
    }

    private func validatedPlan(_ terms: PlanTerms, months range: ClosedRange<Int>, currency: CurrencyCode) throws -> ValidatedPlan {
        let title = terms.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw LedgerError.emptyName }
        guard title.count <= Self.nameLengthLimit else { throw LedgerError.nameTooLong(limit: Self.nameLengthLimit) }
        guard range.contains(terms.months) else { throw LedgerError.planMonthsOutOfRange(range: range) }
        guard (0..<terms.months).contains(terms.paidAtStart) else { throw LedgerError.paidMonthsOutOfRange }
        let amounts = try planAmounts(monthly: terms.monthly, last: terms.last, months: terms.months, currency: currency)
        return ValidatedPlan(title: title, amounts: amounts, paidAtStart: terms.paidAtStart)
    }

    private func makePlan(_ validated: ValidatedPlan, terms: PlanTerms, account: Account) -> PaymentPlan {
        PaymentPlan(
            title: validated.title,
            account: account,
            monthlyMinor: validated.amounts.monthlyMinor,
            lastMinor: validated.amounts.lastMinor,
            months: terms.months,
            paidAtStart: terms.paidAtStart,
            firstDue: terms.nextDue.storedValue,
            createdAt: now
        )
    }

    /// An active expense category, for entries created outside the transaction editor.
    func expenseCategory(id: UUID) throws -> LedgerCategory {
        guard let category = try category(id: id) else { throw LedgerError.categoryNotFound }
        guard category.kind == .expense else { throw LedgerError.categoryKindMismatch(expected: .expense) }
        guard !category.isArchived else { throw LedgerError.categoryArchived(name: category.name) }
        return category
    }

    /// Inserts a plan's purchase and, when the payments cost more than the price, its fees.
    private func insertPlanEntries(
        for plan: PaymentPlan,
        account: Account,
        priceMinor: Int64,
        feesMinor: Int64,
        category: LedgerCategory?,
        occurredAt: Date,
        note: String?,
        origin: EntryOrigin
    ) {
        let purchase = LedgerTransaction(
            kind: .expense,
            amountMinor: priceMinor,
            currency: account.currency,
            occurredAt: occurredAt,
            createdAt: now,
            note: note,
            account: account,
            destinationAccount: nil,
            category: category,
            origin: origin,
            reference: nil,
            requestID: nil
        )
        purchase.planID = plan.id
        context.insert(purchase)
        plan.purchaseID = purchase.id
        guard feesMinor > 0 else { return }
        let fees = LedgerTransaction(
            kind: .expense,
            amountMinor: feesMinor,
            currency: account.currency,
            occurredAt: occurredAt,
            createdAt: now,
            note: nil,
            account: account,
            destinationAccount: nil,
            category: nil,
            origin: .planFees,
            reference: nil,
            requestID: nil
        )
        fees.planID = plan.id
        context.insert(fees)
        plan.feesID = fees.id
    }
}
