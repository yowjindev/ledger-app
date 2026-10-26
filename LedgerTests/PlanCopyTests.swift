import Foundation
import XCTest
@testable import Ledger

/// The wording of a payment plan's progress.
final class PlanCopyTests: XCTestCase {
    func testProgress() {
        XCTAssertEqual(PlanCopy.progress(paid: 3, months: 6), "3 of 6 paid")
        XCTAssertEqual(PlanCopy.progress(paid: 0, months: 12), "0 of 12 paid")
        XCTAssertEqual(PlanCopy.progress(paid: 6, months: 6), "Paid off")
    }

    func testFinish() {
        let english = Locale(identifier: "en_US")
        XCTAssertEqual(PlanCopy.finish(CalendarMonth(year: 2026, month: 8), locale: english), "Last payment Aug 2026")
        XCTAssertEqual(PlanCopy.finish(CalendarMonth(year: 2027, month: 1), locale: english), "Last payment Jan 2027")
    }

    func testPlanMonths() {
        XCTAssertEqual(PlanCopy.planMonths(1), "1× (next month)")
        XCTAssertEqual(PlanCopy.planMonths(3), "3×")
        XCTAssertEqual(PlanCopy.planMonths(12), "12×")
    }

    func testSplitSummary() {
        let formatter = fixedFormatter()
        func summary(_ price: Decimal, _ months: Int, _ monthly: Decimal, _ last: Decimal) -> String {
            plainSpaces(PlanCopy.splitSummary(price: price, months: months, monthly: monthly, last: last, formatter: formatter))
        }
        XCTAssertEqual(
            summary(1_000, 2, 550, 550),
            "You'll pay ₱1,100.00 in all: ₱100.00 more than the price, recorded as fees and interest. That's ₱50.00 a month, 5% of the price."
        )
        XCTAssertEqual(
            summary(1_000, 3, dec("383.33"), dec("383.34")),
            "You'll pay ₱1,150.00 in all: ₱150.00 more than the price, recorded as fees and interest. That's ₱50.00 a month, 5% of the price."
        )
        XCTAssertEqual(
            summary(300, 1, dec("314.70"), dec("314.70")),
            "You'll pay ₱314.70 in all: ₱14.70 more than the price, recorded as fees and interest. That's 4.9% of the price."
        )
        XCTAssertEqual(summary(1_000, 2, 500, 500), "The payments add up to the price, so there are no fees.")
        XCTAssertEqual(summary(1_000, 2, 450, 450), "The payments add up to less than the price. Check the amount of each payment.")
    }
}
