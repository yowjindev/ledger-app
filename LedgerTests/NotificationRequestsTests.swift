import Foundation
import UserNotifications
import XCTest
@testable import Ledger

/// Planned reminders turned into local notification requests.
final class NotificationRequestsTests: XCTestCase {
    func testRequestsMatchThePlan() throws {
        let calendar = try fixedCalendar("Asia/Manila")
        let date = try instant("2026-03-19T09:00:00+08:00")
        let plan = ReminderPlan(
            notifications: [PlannedNotification(id: "ledger.reminder.bill-x.headsup.20260319", date: date, title: "Rent", body: "Due tomorrow")],
            activityStarts: [],
            showNow: []
        )

        let requests = NotificationRequests.requests(for: plan, calendar: calendar)

        XCTAssertEqual(requests.map(\.identifier), ["ledger.reminder.bill-x.headsup.20260319"])
        let trigger = try XCTUnwrap(requests.first?.trigger as? UNCalendarNotificationTrigger)
        XCTAssertFalse(trigger.repeats)
        XCTAssertEqual(trigger.dateComponents.year, 2026)
        XCTAssertEqual(trigger.dateComponents.month, 3)
        XCTAssertEqual(trigger.dateComponents.day, 19)
        XCTAssertEqual(trigger.dateComponents.hour, 9)
        XCTAssertEqual(trigger.dateComponents.minute, 0)
        let content = try XCTUnwrap(requests.first?.content)
        XCTAssertEqual(content.title, "Rent")
        XCTAssertEqual(content.body, "Due tomorrow")
        XCTAssertEqual(content.sound, .default)
        XCTAssertEqual(content.threadIdentifier, NotificationRequests.threadIdentifier)
    }
}
