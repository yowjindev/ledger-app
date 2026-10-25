import Foundation
import XCTest
@testable import Ledger

/// The wording of a due: how much is left and when it's due.
final class DueStatusCopyTests: XCTestCase {
    private let formatter = fixedFormatter()
    private let english = Locale(identifier: "en_US")

    private func status(left: Decimal?, due: CalendarDay, overdue: Bool = false, closed: Bool = true) -> DueStatus {
        DueStatus(
            owner: .bill(UUID()),
            cycle: CalendarMonth(containing: due),
            dueDate: due,
            originalDueDate: due,
            left: left.map { Money($0) },
            isOverdue: overdue,
            isStatementClosed: closed
        )
    }

    private func day(_ month: Int, _ day: Int) -> CalendarDay {
        CalendarDay(year: 2026, month: month, day: day)
    }

    func testAmountText() {
        let due = day(4, 5)
        XCTAssertEqual(DueStatusCopy.amountText(status(left: 1_050, due: due), formatter: formatter), "\(formatter.string(Money(1_050))) left")
        XCTAssertEqual(DueStatusCopy.amountText(status(left: 0, due: due), formatter: formatter), "Paid")
        XCTAssertEqual(DueStatusCopy.amountText(status(left: nil, due: due), formatter: formatter), "Amount not set")
        XCTAssertEqual(
            DueStatusCopy.amountText(status(left: 3_980, due: due, closed: false), formatter: formatter),
            "\(formatter.string(Money(3_980))) so far"
        )
    }

    func testDateText() throws {
        let calendar = try fixedCalendar("Asia/Manila")
        let today = day(3, 15)
        func text(_ status: DueStatus) -> String {
            DueStatusCopy.dateText(status, today: today, calendar: calendar, locale: english)
        }

        XCTAssertEqual(text(status(left: 1, due: day(3, 15))), "Due today")
        XCTAssertEqual(text(status(left: 1, due: day(3, 16))), "Due tomorrow")
        XCTAssertEqual(text(status(left: 1, due: day(4, 5))), "Due Apr 5")
        XCTAssertEqual(text(status(left: 1, due: day(3, 14), overdue: true)), "1 day overdue")
        XCTAssertEqual(text(status(left: 1, due: day(3, 12), overdue: true)), "3 days overdue")
        XCTAssertEqual(text(status(left: 1, due: day(2, 25), overdue: true)), "18 days overdue")
    }
}
