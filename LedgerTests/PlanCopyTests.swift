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
}
