import Foundation
import SwiftData
import XCTest
@testable import Ledger

/// The Coming up list across owed accounts and bills, and the total owed.
@MainActor
final class ComingUpTests: XCTestCase {
    private struct Fixture {
        let h: LedgerHarness
        let card: Account
        let payLater: Account
        let loan: Account
        let rent: Bill
    }

    /// Made on March 15: a paid-up card and a pay later account both due April 5, a loan due
    /// April 8, and rent due March 25.
    private func fixture() throws -> Fixture {
        let h = try LedgerHarness(calendar: try fixedCalendar("Asia/Manila"))
        let card = try h.ledger.createOwedAccount(
            name: "Visa card", kind: .creditCard, terms: OwedTerms(statementDay: 20, dueDay: 5), owedNow: 0, stillDue: nil
        )
        let payLater = try h.ledger.createOwedAccount(
            name: "PayLater", kind: .payLater, terms: OwedTerms(statementDay: 31, dueDay: 5), owedNow: 500, stillDue: nil
        )
        let loan = try h.ledger.createLoan(
            name: "Phone loan",
            terms: PlanTerms(
                title: "Phone", monthly: 2_400, last: nil, months: 12, paidAtStart: 6,
                nextDue: CalendarDay(year: 2026, month: 4, day: 8)
            ),
            purchase: nil
        )
        let rentCategory = try h.expenseCategory("Rent")
        let rent = try h.ledger.createBill(BillTerms(
            name: "Rent", categoryID: rentCategory.id, dueDay: 25, amount: 8_000, arrivesDay: nil, payFromAccountID: nil
        ))
        return Fixture(h: h, card: card, payLater: payLater, loan: loan, rent: rent)
    }

    func testComingUpOrdersOverdueThenUnpaidThenPaid() throws {
        let f = try fixture()
        f.h.clock.now = try instant("2026-03-26T10:00:00+08:00")

        let dues = try f.h.ledger.comingUp()

        XCTAssertEqual(dues.map(\.owner), [.bill(f.rent.id), .account(f.payLater.id), .account(f.loan.id), .account(f.card.id)])
        XCTAssertTrue(dues[0].isOverdue)
        XCTAssertFalse(dues[1].isPaid)
        XCTAssertTrue(dues[3].isPaid)
    }

    func testQueriedComingUpMatchesTheService() throws {
        let f = try fixture()
        f.h.clock.now = try instant("2026-03-26T10:00:00+08:00")
        let context = f.h.context

        let queried = LedgerService.comingUp(
            accounts: try context.fetch(FetchDescriptor<Account>()),
            transactions: try context.fetch(FetchDescriptor<LedgerTransaction>()),
            plans: try context.fetch(FetchDescriptor<PaymentPlan>()),
            bills: try context.fetch(FetchDescriptor<Bill>()),
            overrides: try context.fetch(FetchDescriptor<DueOverride>()),
            today: f.h.ledger.today,
            calendar: f.h.ledger.calendar
        )

        XCTAssertEqual(queried, try f.h.ledger.comingUp())
    }

    func testArchivedAccountsAndBillsLeaveComingUp() throws {
        let f = try fixture()
        try f.h.ledger.archiveAccount(f.loan)
        try f.h.ledger.archiveBill(f.rent)

        let owners = try f.h.ledger.comingUp().map(\.owner)

        XCTAssertFalse(owners.contains(.account(f.loan.id)))
        XCTAssertFalse(owners.contains(.bill(f.rent.id)))
        XCTAssertEqual(try f.h.ledger.totalOwed().amount, 500)
    }

    func testTotalOwedCountsKnownOwedBalancesOnly() throws {
        let h = try LedgerHarness(calendar: try fixedCalendar("Asia/Manila"))
        let bank = try h.account("Bank", opening: 10_000)
        try h.ledger.createOwedAccount(
            name: "Visa card", kind: .creditCard, terms: OwedTerms(statementDay: 5, dueDay: 25), owedNow: 2_500, stillDue: nil
        )
        try h.ledger.createOwedAccount(
            name: "PayLater", kind: .payLater, terms: OwedTerms(statementDay: 31, dueDay: 5), owedNow: 640, stillDue: nil
        )
        let credit = try h.ledger.createOwedAccount(
            name: "Other PayLater", kind: .payLater, terms: OwedTerms(statementDay: 31, dueDay: 5), owedNow: 0, stillDue: nil
        )
        try h.ledger.record(.transfer(amount: 100, fromAccountID: bank.id, toAccountID: credit.id, occurredAt: h.clock.now))

        XCTAssertEqual(try h.ledger.totalOwed().amount, 3_040)
    }
}
