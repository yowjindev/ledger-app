import Foundation
import XCTest
@testable import Ledger

/// What the Live Activity's buttons do: snooze what it shows, or open the app to pay or move a due.
@MainActor
final class ReminderActionsTests: XCTestCase {
    private func line(_ key: String) -> ReminderLine {
        ReminderLine(ownerKey: key, name: "Rent", symbolName: "doc.text", dateText: "Due today", isOverdue: false)
    }

    func testSnoozeStoresEveryShownLine() throws {
        try withScratchDefaults { defaults in
            let now = TestClock.referenceDate
            ReminderActions.snooze(lines: [line("bill-a"), line("account-b")], minutes: 60, now: now, defaults: defaults)

            let snoozes = ReminderPreferences.snoozes(in: defaults, now: now)
            XCTAssertEqual(snoozes["bill-a"], now.addingTimeInterval(3_600))
            XCTAssertEqual(snoozes["account-b"], now.addingTimeInterval(3_600))
        }
    }

    func testRoutesFromKeys() {
        let id = UUID()
        let routing = ReminderRouting()

        ReminderActions.openPayment(ownerKey: DueOwner.bill(id).key, routing: routing)
        XCTAssertEqual(routing.pending, .pay(.bill(id)))

        ReminderActions.openMove(ownerKey: DueOwner.account(id).key, routing: routing)
        XCTAssertEqual(routing.pending, .move(.account(id)))

        routing.pending = nil
        ReminderActions.openPayment(ownerKey: "junk", routing: routing)
        XCTAssertNil(routing.pending)
    }
}
