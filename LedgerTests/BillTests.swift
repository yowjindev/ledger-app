import Foundation
import SwiftData
import XCTest
@testable import Ledger

/// Regular monthly bills: when each is due, what's left of it, paying it, and moving one
/// month's due date.
@MainActor
final class BillTests: XCTestCase {
    private struct Fixture {
        let h: LedgerHarness
        let bank: Account
        let rent: LedgerCategory
    }

    private func fixture(now: String = "2026-03-15T10:00:00+08:00") throws -> Fixture {
        let h = try LedgerHarness(calendar: try fixedCalendar("Asia/Manila"))
        h.clock.now = try instant(now)
        return Fixture(h: h, bank: try h.account("Bank", opening: 20_000), rent: try h.expenseCategory("Rent"))
    }

    private func day(_ year: Int, _ month: Int, _ day: Int) -> CalendarDay {
        CalendarDay(year: year, month: month, day: day)
    }

    private let march = CalendarMonth(year: 2026, month: 3)
    private let april = CalendarMonth(year: 2026, month: 4)

    @discardableResult
    private func rentBill(_ f: Fixture, dueDay: Int = 25) throws -> Bill {
        try f.h.ledger.createBill(BillTerms(
            name: "Rent", categoryID: f.rent.id, dueDay: dueDay, amount: 8_000, arrivesDay: nil, payFromAccountID: f.bank.id
        ))
    }

    @discardableResult
    private func pay(_ amount: Decimal, _ bill: Bill, cycle: CalendarMonth, _ f: Fixture) throws -> LedgerTransaction {
        try f.h.ledger.payBill(bill, cycle: cycle, amount: amount, from: f.bank.id, occurredAt: f.h.clock.now)
    }

    func testFixedBillIsDueThenPaid() throws {
        let f = try fixture()
        let bill = try rentBill(f)
        XCTAssertEqual(bill.startCycle, 202603)
        XCTAssertEqual(bill.payFrom?.id, f.bank.id)

        let due = try f.h.ledger.dueStatus(for: bill)
        XCTAssertEqual(due.owner, .bill(bill.id))
        XCTAssertEqual(due.cycle, march)
        XCTAssertEqual(due.dueDate, day(2026, 3, 25))
        XCTAssertEqual(due.left?.amount, 8_000)
        XCTAssertFalse(due.isOverdue)
        XCTAssertTrue(due.isStatementClosed)

        let payment = try pay(8_000, bill, cycle: march, f)
        XCTAssertTrue(try f.h.ledger.dueStatus(for: bill).isPaid)
        XCTAssertEqual(payment.kind, .expense)
        XCTAssertEqual(payment.category?.id, f.rent.id)
        XCTAssertEqual(payment.billID, bill.id)
        XCTAssertEqual(payment.billCycle, 202603)
        XCTAssertEqual(try f.h.balance(f.bank), 12_000)
    }

    func testVaryingBillHasNoAmountUntilEntered() throws {
        let f = try fixture()
        let utilities = try f.h.expenseCategory("Utilities")
        let bill = try f.h.ledger.createBill(BillTerms(
            name: "Electricity", categoryID: utilities.id, dueDay: 30, amount: nil, arrivesDay: 19, payFromAccountID: nil
        ))
        XCTAssertNil(try f.h.ledger.dueStatus(for: bill).left)
        XCTAssertEqual(bill.arrivesDay, 19)

        try f.h.ledger.setAmount(2_350, for: bill, cycle: march)

        XCTAssertEqual(try f.h.ledger.dueStatus(for: bill).left?.amount, 2_350)
        let override = try XCTUnwrap(try f.h.ledger.dueOverrides(for: bill.id).first)
        XCTAssertEqual(override.cycle, 202603)
        XCTAssertEqual(override.amountMinor, 235_000)
    }

    func testPartialPaymentLeavesTheRest() throws {
        let f = try fixture()
        let bill = try rentBill(f)
        try pay(5_000, bill, cycle: march, f)

        XCTAssertEqual(try f.h.ledger.dueStatus(for: bill).left?.amount, 3_000)
    }

    func testDeletingThePaymentMakesItUnpaid() throws {
        let f = try fixture()
        let bill = try rentBill(f)
        let payment = try pay(8_000, bill, cycle: march, f)

        try f.h.ledger.delete(payment)

        XCTAssertEqual(try f.h.ledger.dueStatus(for: bill).left?.amount, 8_000)
    }

    func testUnpaidBillBecomesOverdue() throws {
        let f = try fixture()
        let bill = try rentBill(f)
        f.h.clock.now = try instant("2026-03-26T10:00:00+08:00")

        let due = try f.h.ledger.dueStatus(for: bill)
        XCTAssertEqual(due.cycle, march)
        XCTAssertTrue(due.isOverdue)
        XCTAssertEqual(due.left?.amount, 8_000)
    }

    func testMoveThisDueOnlyMovesThisMonth() throws {
        let f = try fixture()
        let bill = try rentBill(f)

        try f.h.ledger.moveDue(of: .bill(bill.id), cycle: march, to: day(2026, 3, 30))

        let moved = try f.h.ledger.dueStatus(for: bill)
        XCTAssertEqual(moved.dueDate, day(2026, 3, 30))
        XCTAssertEqual(moved.originalDueDate, day(2026, 3, 25))

        f.h.clock.now = try instant("2026-03-27T10:00:00+08:00")
        XCTAssertFalse(try f.h.ledger.dueStatus(for: bill).isOverdue)

        try pay(8_000, bill, cycle: march, f)
        f.h.clock.now = try instant("2026-03-31T10:00:00+08:00")
        let next = try f.h.ledger.dueStatus(for: bill)
        XCTAssertEqual(next.cycle, april)
        XCTAssertEqual(next.dueDate, day(2026, 4, 25))
    }

    func testMovingBackToTheUsualDateClearsTheMove() throws {
        let f = try fixture()
        let bill = try rentBill(f)
        try f.h.ledger.moveDue(of: .bill(bill.id), cycle: march, to: day(2026, 3, 30))

        try f.h.ledger.moveDue(of: .bill(bill.id), cycle: march, to: day(2026, 3, 25))

        XCTAssertEqual(try f.h.ledger.dueStatus(for: bill).dueDate, day(2026, 3, 25))
        XCTAssertTrue(try f.h.ledger.dueOverrides(for: bill.id).isEmpty)
    }

    func testMoveOutOfRangeIsRefused() throws {
        let f = try fixture()
        let bill = try rentBill(f)

        assertThrowsLedgerError(.moveDateOutOfRange) {
            try f.h.ledger.moveDue(of: .bill(bill.id), cycle: march, to: day(2026, 3, 14))
        }
        assertThrowsLedgerError(.moveDateOutOfRange) {
            try f.h.ledger.moveDue(of: .bill(bill.id), cycle: march, to: day(2026, 4, 25))
        }
        XCTAssertTrue(try f.h.ledger.dueOverrides(for: bill.id).isEmpty)
    }

    func testMoveRangeUsesClampedDueDates() throws {
        let f = try fixture(now: "2026-03-31T10:00:00+08:00")
        let bill = try rentBill(f, dueDay: 31)
        XCTAssertEqual(bill.startCycle, 202603)

        try f.h.ledger.moveDue(of: .bill(bill.id), cycle: march, to: day(2026, 4, 29))
        assertThrowsLedgerError(.moveDateOutOfRange) {
            try f.h.ledger.moveDue(of: .bill(bill.id), cycle: march, to: day(2026, 4, 30))
        }
    }

    func testMoveDueForAnOwedAccount() throws {
        let f = try fixture()
        let card = try f.h.ledger.createOwedAccount(
            name: "Visa card", kind: .creditCard, terms: OwedTerms(statementDay: 5, dueDay: 25), owedNow: 1_000, stillDue: nil
        )

        try f.h.ledger.moveDue(of: .account(card.id), cycle: march, to: day(2026, 3, 30))

        XCTAssertEqual(try f.h.ledger.dueStatus(for: card)?.dueDate, day(2026, 3, 30))
    }

    func testBillsStartAtTheFirstUpcomingDue() throws {
        let f = try fixture(now: "2026-03-26T10:00:00+08:00")
        let bill = try rentBill(f)

        XCTAssertEqual(bill.startCycle, 202604)
        XCTAssertEqual(try f.h.ledger.dueStatus(for: bill).cycle, april)
        XCTAssertFalse(try f.h.ledger.dueStatus(for: bill).isOverdue)
    }

    func testArrivalDayOnlyForVaryingBills() throws {
        let f = try fixture()
        assertThrowsLedgerError(.arrivalDayNotApplicable) {
            try f.h.ledger.createBill(BillTerms(
                name: "Rent", categoryID: f.rent.id, dueDay: 25, amount: 8_000, arrivesDay: 19, payFromAccountID: nil
            ))
        }
        assertThrowsLedgerError(.dayOutOfRange) {
            try f.h.ledger.createBill(BillTerms(
                name: "Rent", categoryID: f.rent.id, dueDay: 32, amount: 8_000, arrivesDay: nil, payFromAccountID: nil
            ))
        }
        assertThrowsLedgerError(.dayOutOfRange) {
            try f.h.ledger.createBill(BillTerms(
                name: "Water", categoryID: f.rent.id, dueDay: 30, amount: nil, arrivesDay: 32, payFromAccountID: nil
            ))
        }
        assertThrowsLedgerError(.amountNotPositive) {
            try f.h.ledger.createBill(BillTerms(
                name: "Rent", categoryID: f.rent.id, dueDay: 25, amount: 0, arrivesDay: nil, payFromAccountID: nil
            ))
        }
        XCTAssertTrue(try f.h.ledger.bills().isEmpty)
    }

    func testBillNamesAreUnique() throws {
        let f = try fixture()
        try rentBill(f)
        assertThrowsLedgerError(.duplicateName("Rent")) { try rentBill(f) }
    }

    func testBillWithPaymentsCantBeDeleted() throws {
        let f = try fixture()
        let bill = try rentBill(f)
        try pay(8_000, bill, cycle: march, f)

        assertThrowsLedgerError(.billHasPayments(name: "Rent")) { try f.h.ledger.deleteBill(bill) }

        try f.h.ledger.archiveBill(bill)
        XCTAssertTrue(bill.isArchived)
        XCTAssertTrue(try f.h.ledger.bills().isEmpty)
        XCTAssertEqual(try f.h.ledger.bills(includeArchived: true).map(\.id), [bill.id])
        try f.h.ledger.unarchiveBill(bill)
        XCTAssertFalse(bill.isArchived)
    }

    func testBillWithoutPaymentsIsDeletedWithItsOverrides() throws {
        let f = try fixture()
        let bill = try rentBill(f)
        try f.h.ledger.moveDue(of: .bill(bill.id), cycle: march, to: day(2026, 3, 30))

        try f.h.ledger.deleteBill(bill)

        XCTAssertTrue(try f.h.ledger.bills(includeArchived: true).isEmpty)
        XCTAssertEqual(try f.h.context.fetchCount(FetchDescriptor<DueOverride>()), 0)
    }

    func testFailedPaymentRecordsNothing() throws {
        let f = try fixture()
        let bill = try rentBill(f)

        assertThrowsLedgerError(.persistenceFailed) {
            try f.h.failingLedger().payBill(bill, cycle: march, amount: 8_000, from: f.bank.id, occurredAt: f.h.clock.now)
        }
        XCTAssertEqual(try f.h.transactionCount(), 0)
        XCTAssertEqual(try f.h.ledger.dueStatus(for: bill).left?.amount, 8_000)
    }
}
