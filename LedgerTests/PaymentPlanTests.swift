import Foundation
import SwiftData
import XCTest
@testable import Ledger

/// Pay later splits and loans: what a plan records, how much it adds to what's owed, and how its
/// months paid follow the account's dues.
@MainActor
final class PaymentPlanTests: XCTestCase {
    private func harness() throws -> LedgerHarness {
        try LedgerHarness(calendar: try fixedCalendar("Asia/Manila"))
    }

    private func payLater(_ h: LedgerHarness) throws -> Account {
        try h.ledger.createOwedAccount(
            name: "PayLater",
            kind: .payLater,
            terms: OwedTerms(statementDay: 31, dueDay: 5),
            owedNow: 0,
            stillDue: nil
        )
    }

    private func split(
        _ amount: Decimal,
        on account: Account,
        category: LedgerCategory,
        months: Int,
        monthly: Decimal,
        last: Decimal? = nil,
        at date: Date
    ) -> SplitPurchase {
        SplitPurchase(
            amount: amount, accountID: account.id, categoryID: category.id, occurredAt: date,
            note: nil, months: months, monthly: monthly, last: last
        )
    }

    private func day(_ year: Int, _ month: Int, _ day: Int) -> CalendarDay {
        CalendarDay(year: year, month: month, day: day)
    }

    private func partwayLoan(_ h: LedgerHarness) throws -> Account {
        try h.ledger.createLoan(
            name: "Phone loan",
            terms: PlanTerms(title: "Phone", monthly: 2_400, last: nil, months: 12, paidAtStart: 6, nextDue: day(2026, 4, 8)),
            purchase: nil
        )
    }

    private func planCount(_ h: LedgerHarness) throws -> Int {
        try h.context.fetchCount(FetchDescriptor<PaymentPlan>())
    }

    // MARK: Splits

    func testSplitRecordsPriceFeesAndPlanInOneSave() throws {
        let h = try harness()
        let account = try payLater(h)
        let shopping = try h.expenseCategory("Shopping")

        let plan = try h.ledger.recordSplitPurchase(split(3_000, on: account, category: shopping, months: 3, monthly: 1_050, at: h.clock.now))

        let entries = try h.ledger.transactions()
        XCTAssertEqual(entries.count, 2)
        let purchase = try XCTUnwrap(entries.first { $0.origin == .app })
        XCTAssertEqual(purchase.amountMinor, 300_000)
        XCTAssertEqual(purchase.category?.id, shopping.id)
        XCTAssertEqual(purchase.planID, plan.id)
        let fees = try XCTUnwrap(entries.first { $0.origin == .planFees })
        XCTAssertEqual(fees.amountMinor, 15_000)
        XCTAssertEqual(fees.kind, .expense)
        XCTAssertNil(fees.category)
        XCTAssertEqual(fees.planID, plan.id)
        XCTAssertEqual(fees.occurredAt, purchase.occurredAt)
        XCTAssertEqual(plan.purchaseID, purchase.id)
        XCTAssertEqual(plan.feesID, fees.id)
        XCTAssertEqual(plan.firstDueDay, day(2026, 4, 5))
        XCTAssertEqual(plan.total.amount, 3_150)
        XCTAssertEqual(plan.title, "Shopping")
        XCTAssertEqual(try h.ledger.balance(of: account)?.owed?.amount, 3_150)
        let month = ReportingPeriod.thisMonth.interval(containing: h.clock.now, calendar: h.ledger.calendar)
        XCTAssertEqual(try h.ledger.periodSummary(for: month).expenses.amount, 3_150)
    }

    func testUnevenLastSlice() throws {
        let h = try harness()
        let account = try payLater(h)
        let shopping = try h.expenseCategory("Shopping")

        let plan = try h.ledger.recordSplitPurchase(
            split(1_000, on: account, category: shopping, months: 3, monthly: dec("333.33"), last: dec("333.34"), at: h.clock.now)
        )

        XCTAssertEqual(try h.transactionCount(), 1, "No fees entry when the payments add up to the price")
        XCTAssertNil(plan.feesID)
        XCTAssertEqual(PlanSnapshot(plan)?.slices.map(\.amountMinor), [33_333, 33_333, 33_334])
    }

    func testPlanBelowPriceIsRefused() throws {
        let h = try harness()
        let account = try payLater(h)
        let shopping = try h.expenseCategory("Shopping")

        assertThrowsLedgerError(.planTotalBelowPrice) {
            try h.ledger.recordSplitPurchase(split(3_000, on: account, category: shopping, months: 3, monthly: 900, at: h.clock.now))
        }
        XCTAssertEqual(try h.transactionCount(), 0)
        XCTAssertEqual(try planCount(h), 0)
    }

    func testSplitOnlyOnPayLater() throws {
        let h = try harness()
        let account = try payLater(h)
        let card = try h.ledger.createOwedAccount(
            name: "Visa card", kind: .creditCard, terms: OwedTerms(statementDay: 5, dueDay: 25), owedNow: 0, stillDue: nil
        )
        let shopping = try h.expenseCategory("Shopping")

        assertThrowsLedgerError(.splitNotOffered) {
            try h.ledger.recordSplitPurchase(split(3_000, on: card, category: shopping, months: 3, monthly: 1_050, at: h.clock.now))
        }
        assertThrowsLedgerError(.planMonthsOutOfRange(range: 2...60)) {
            try h.ledger.recordSplitPurchase(split(3_000, on: account, category: shopping, months: 1, monthly: 3_000, at: h.clock.now))
        }
        XCTAssertEqual(try h.transactionCount(), 0)
    }

    func testExistingPlanCreatesNoEntries() throws {
        let h = try harness()
        let account = try payLater(h)

        let plan = try h.ledger.addExistingPlan(
            PlanTerms(title: "Headphones", monthly: 500, last: nil, months: 6, paidAtStart: 2, nextDue: day(2026, 4, 5)),
            to: account
        )

        XCTAssertEqual(try h.transactionCount(), 0)
        XCTAssertEqual(PlanSnapshot(plan)?.slices.count, 4)
        XCTAssertEqual(try h.ledger.balance(of: account)?.owed?.amount, 0)
        XCTAssertEqual(try h.ledger.plans(for: account).map(\.id), [plan.id])
    }

    func testExistingPlanDueMustBeOnSchedule() throws {
        let h = try harness()
        let account = try payLater(h)

        assertThrowsLedgerError(.dueDateNotOnSchedule) {
            try h.ledger.addExistingPlan(
                PlanTerms(title: "Headphones", monthly: 500, last: nil, months: 6, paidAtStart: 2, nextDue: day(2026, 4, 6)),
                to: account
            )
        }
        assertThrowsLedgerError(.paidMonthsOutOfRange) {
            try h.ledger.addExistingPlan(
                PlanTerms(title: "Headphones", monthly: 500, last: nil, months: 6, paidAtStart: 6, nextDue: day(2026, 4, 5)),
                to: account
            )
        }
        XCTAssertEqual(try planCount(h), 0)
    }

    // MARK: Loans

    func testLoanPartwaySetsOpeningFromRemainingSlices() throws {
        let h = try harness()
        let loan = try partwayLoan(h)

        XCTAssertEqual(loan.kind, .loan)
        XCTAssertEqual(loan.openingBalanceMinor, -1_440_000)
        XCTAssertEqual(loan.dueDay, 8)
        XCTAssertNil(loan.statementDay)
        XCTAssertEqual(try h.transactionCount(), 0)
        let plan = try XCTUnwrap(try h.ledger.plans(for: loan).first)
        XCTAssertEqual(plan.title, "Phone")
        XCTAssertEqual(try h.ledger.monthsPaid(plan), 6)
    }

    func testNewLoanRecordsItemAndFees() throws {
        let h = try harness()
        let gadgets = try h.expenseCategory("Gadgets")

        let loan = try h.ledger.createLoan(
            name: "Laptop loan",
            terms: PlanTerms(title: "Laptop", monthly: 2_400, last: nil, months: 12, paidAtStart: 0, nextDue: day(2026, 4, 8)),
            purchase: LoanPurchase(price: 25_000, categoryID: gadgets.id, occurredAt: h.clock.now)
        )

        XCTAssertEqual(loan.openingBalanceMinor, 0)
        let entries = try h.ledger.transactions()
        XCTAssertEqual(entries.first { $0.origin == .app }?.amountMinor, 2_500_000)
        XCTAssertEqual(entries.first { $0.origin == .app }?.category?.id, gadgets.id)
        XCTAssertEqual(entries.first { $0.origin == .planFees }?.amountMinor, 380_000)
        XCTAssertEqual(try h.ledger.balance(of: loan)?.owed?.amount, 28_800)

        assertThrowsLedgerError(.paidMonthsOutOfRange) {
            try h.ledger.createLoan(
                name: "Tablet loan",
                terms: PlanTerms(title: "Tablet", monthly: 1_000, last: nil, months: 12, paidAtStart: 1, nextDue: day(2026, 4, 8)),
                purchase: LoanPurchase(price: 10_000, categoryID: gadgets.id, occurredAt: h.clock.now)
            )
        }
        XCTAssertNil(try h.ledger.accounts().first { $0.name == "Tablet loan" })
    }

    func testMonthsPaidAfterAPayment() throws {
        let h = try harness()
        let bank = try h.account("Bank", opening: 10_000)
        let loan = try partwayLoan(h)
        let plan = try XCTUnwrap(try h.ledger.plans(for: loan).first)

        try h.ledger.record(.transfer(amount: 2_400, fromAccountID: bank.id, toAccountID: loan.id, occurredAt: h.clock.now))

        XCTAssertEqual(try h.ledger.monthsPaid(plan), 7)
        XCTAssertEqual(try h.ledger.dueStatus(for: loan)?.isPaid, true)
    }

    // MARK: Deleting and editing

    func testDeletingAPlanEntryDeletesThePlan() throws {
        let h = try harness()
        let account = try payLater(h)
        let shopping = try h.expenseCategory("Shopping")
        try h.ledger.recordSplitPurchase(split(3_000, on: account, category: shopping, months: 3, monthly: 1_050, at: h.clock.now))
        let purchase = try XCTUnwrap(try h.ledger.transactions().first { $0.origin == .app })

        try h.ledger.delete(purchase)

        XCTAssertEqual(try planCount(h), 0)
        XCTAssertEqual(try h.transactionCount(), 0)
        XCTAssertEqual(try h.ledger.balance(of: account)?.owed?.amount, 0)
    }

    func testDeletingThePlanDeletesItsEntries() throws {
        let h = try harness()
        let account = try payLater(h)
        let shopping = try h.expenseCategory("Shopping")
        let plan = try h.ledger.recordSplitPurchase(split(3_000, on: account, category: shopping, months: 3, monthly: 1_050, at: h.clock.now))

        try h.ledger.deletePlan(plan)

        XCTAssertEqual(try planCount(h), 0)
        XCTAssertEqual(try h.transactionCount(), 0)
    }

    func testPlanEntriesAreNotEditable() throws {
        let h = try harness()
        let account = try payLater(h)
        let shopping = try h.expenseCategory("Shopping")
        try h.ledger.recordSplitPurchase(split(3_000, on: account, category: shopping, months: 3, monthly: 1_050, at: h.clock.now))
        let entries = try h.ledger.transactions()
        let purchase = try XCTUnwrap(entries.first { $0.origin == .app })

        XCTAssertFalse(purchase.isEditable)
        XCTAssertFalse(try XCTUnwrap(entries.first { $0.origin == .planFees }).isEditable)
        assertThrowsLedgerError(.entryNotEditable) {
            try h.ledger.update(purchase, with: .expense(amount: 100, accountID: account.id, categoryID: shopping.id, occurredAt: h.clock.now))
        }
    }

    func testDeletingAnAccountRemovesItsPlansAndOverrides() throws {
        let h = try harness()
        let loan = try partwayLoan(h)
        h.context.insert(DueOverride(ownerID: loan.id, cycle: 202604, movedTo: 20260410))
        try h.context.save()

        try h.ledger.deleteAccount(loan)

        XCTAssertEqual(try planCount(h), 0)
        XCTAssertEqual(try h.context.fetchCount(FetchDescriptor<DueOverride>()), 0)
        XCTAssertTrue(try h.ledger.accounts(includeArchived: true).isEmpty)
    }

    func testFailedSplitSavesNothing() throws {
        let h = try harness()
        let account = try payLater(h)
        let shopping = try h.expenseCategory("Shopping")

        assertThrowsLedgerError(.persistenceFailed) {
            try h.failingLedger().recordSplitPurchase(split(3_000, on: account, category: shopping, months: 3, monthly: 1_050, at: h.clock.now))
        }
        XCTAssertEqual(try h.transactionCount(), 0)
        XCTAssertEqual(try planCount(h), 0)
    }
}
