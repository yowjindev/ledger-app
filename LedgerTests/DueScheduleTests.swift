import Foundation
import XCTest
@testable import Ledger

/// Billing-cycle dates: when a statement closes, when its payment is due, and which cycle a
/// purchase is billed in.
final class DueScheduleTests: XCTestCase {
    private func month(_ year: Int, _ month: Int) -> CalendarMonth {
        CalendarMonth(year: year, month: month)
    }

    private func day(_ year: Int, _ month: Int, _ day: Int) -> CalendarDay {
        CalendarDay(year: year, month: month, day: day)
    }

    func testMonthArithmeticCrossesYears() {
        XCTAssertEqual(month(2026, 12).adding(months: 1), month(2027, 1))
        XCTAssertEqual(month(2027, 1).adding(months: -1), month(2026, 12))
        XCTAssertEqual(month(2026, 3).adding(months: 14), month(2027, 5))
        XCTAssertEqual(month(2026, 11).storedValue, 202611)
        XCTAssertEqual(CalendarMonth(storedValue: 202611), month(2026, 11))
        XCTAssertNil(CalendarMonth(storedValue: 202613))
        XCTAssertNil(CalendarMonth(storedValue: 202600))
        XCTAssertEqual(CalendarMonth(containing: day(2026, 3, 15)), month(2026, 3))
        XCTAssertLessThan(month(2026, 12), month(2027, 1))
    }

    func testDay31ClampsToMonthEnd() {
        XCTAssertEqual(month(2026, 2).day(31), day(2026, 2, 28))
        XCTAssertEqual(month(2028, 2).day(29), day(2028, 2, 29))
        XCTAssertEqual(month(2026, 4).day(31), day(2026, 4, 30))
        XCTAssertEqual(month(2026, 1).day(31), day(2026, 1, 31))
        XCTAssertEqual(month(2100, 2).dayCount, 28)
        XCTAssertEqual(month(2000, 2).dayCount, 29)
    }

    func testDueAfterStatementFallsInNextMonth() {
        let schedule = DueSchedule(statementDay: 20, dueDay: 10)
        XCTAssertEqual(schedule.dueDate(in: month(2026, 11)), day(2026, 11, 10))
        XCTAssertEqual(schedule.statementClose(for: month(2026, 11)), day(2026, 10, 20))
    }

    func testDueLaterInSameMonth() {
        let schedule = DueSchedule(statementDay: 5, dueDay: 25)
        XCTAssertEqual(schedule.statementClose(for: month(2026, 11)), day(2026, 11, 5))
    }

    func testSameStatementAndDueDay() {
        let schedule = DueSchedule(statementDay: 15, dueDay: 15)
        XCTAssertEqual(schedule.statementClose(for: month(2026, 11)), day(2026, 10, 15))
    }

    func testEndOfMonthStatement() {
        let schedule = DueSchedule(statementDay: 31, dueDay: 5)
        XCTAssertEqual(schedule.statementClose(for: month(2026, 3)), day(2026, 2, 28))
        XCTAssertEqual(schedule.statementClose(for: month(2026, 5)), day(2026, 4, 30))
    }

    func testPurchaseOnStatementDayBelongsToClosingCycle() {
        let schedule = DueSchedule(statementDay: 20, dueDay: 10)
        XCTAssertEqual(schedule.billingCycle(for: day(2026, 10, 20)), month(2026, 11))
        XCTAssertEqual(schedule.billingCycle(for: day(2026, 10, 21)), month(2026, 12))
        XCTAssertEqual(schedule.billingCycle(for: day(2026, 10, 1)), month(2026, 11))

        let sameMonth = DueSchedule(statementDay: 5, dueDay: 25)
        XCTAssertEqual(sameMonth.billingCycle(for: day(2026, 3, 5)), month(2026, 3))
        XCTAssertEqual(sameMonth.billingCycle(for: day(2026, 3, 6)), month(2026, 4))

        let endOfMonth = DueSchedule(statementDay: 31, dueDay: 5)
        XCTAssertEqual(endOfMonth.billingCycle(for: day(2026, 2, 28)), month(2026, 3))
        XCTAssertEqual(endOfMonth.billingCycle(for: day(2026, 3, 10)), month(2026, 4))
    }

    func testCycleDueOnOrAfter() {
        let schedule = DueSchedule(statementDay: 20, dueDay: 10)
        XCTAssertEqual(schedule.cycle(dueOnOrAfter: day(2026, 11, 10)), month(2026, 11))
        XCTAssertEqual(schedule.cycle(dueOnOrAfter: day(2026, 11, 11)), month(2026, 12))
        XCTAssertEqual(schedule.cycle(dueOnOrAfter: day(2026, 12, 31)), month(2027, 1))

        let monthEnd = DueSchedule(statementDay: nil, dueDay: 31)
        XCTAssertEqual(monthEnd.cycle(dueOnOrAfter: day(2026, 2, 28)), month(2026, 2))
        XCTAssertEqual(monthEnd.cycle(dueOnOrAfter: day(2026, 3, 1)), month(2026, 3))
    }

    func testLoanScheduleHasNoStatement() {
        let schedule = DueSchedule(statementDay: nil, dueDay: 8)
        XCTAssertNil(schedule.statementClose(for: month(2026, 4)))
        XCTAssertEqual(schedule.billingCycle(for: day(2026, 3, 15)), month(2026, 4))
        XCTAssertEqual(schedule.billingCycle(for: day(2026, 3, 8)), month(2026, 3))
    }
}
