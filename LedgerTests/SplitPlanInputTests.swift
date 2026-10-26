import Foundation
import XCTest
@testable import Ledger

/// What the split and plan editors pass on: a one-month plan has no different last payment.
@MainActor
final class SplitPlanInputTests: XCTestCase {
    func testOneMonthSplitIgnoresADifferentLastPayment() {
        let split = SplitPlanInput(isOn: true, months: 1, monthly: 1_050, hasDifferentLast: true, last: nil)
        XCTAssertTrue(split.isComplete)
        let draft = TransactionDraft.expense(
            amount: 1_000, accountID: UUID(), categoryID: UUID(), occurredAt: TestClock.referenceDate, note: nil
        )
        XCTAssertEqual(split.purchase(from: draft)?.months, 1)
        XCTAssertNil(split.purchase(from: draft)?.last)
    }

    func testOneMonthPlanIgnoresADifferentLastPayment() {
        let nextDue = CalendarDay(year: 2026, month: 4, day: 5)
        var payments = PlanPaymentsInput(title: "Earbuds", monthly: 1_050, hasDifferentLast: true, last: 900, months: 1)
        XCTAssertNil(payments.terms(nextDue: nextDue)?.last)
        payments.months = 2
        XCTAssertEqual(payments.terms(nextDue: nextDue)?.last, 900)
    }
}
