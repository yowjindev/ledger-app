import Foundation
import XCTest
@testable import Ledger

/// When each unpaid due is reminded, and how: notifications, or Live Activity starts in strict mode.
@MainActor
final class ReminderPlannerTests: XCTestCase {
    private let now = TestClock.referenceDate
    private let calendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "Asia/Manila") ?? .gmt
        calendar.locale = Locale(identifier: "en_US_POSIX")
        return calendar
    }()

    // MARK: Fixtures

    private func day(_ month: Int, _ day: Int) -> CalendarDay {
        CalendarDay(year: 2026, month: month, day: day)
    }

    private func at(_ month: Int, _ day: Int, _ time: String = "09:00") throws -> Date {
        try instant(String(format: "2026-%02d-%02dT%@:00+08:00", month, day, time))
    }

    private func item(
        _ name: String,
        due: CalendarDay,
        left: Decimal? = 1_000,
        strict: Bool = true,
        arrives: CalendarDay? = nil,
        owner: DueOwner? = nil
    ) -> ReminderItem {
        let status = DueStatus(
            owner: owner ?? .bill(UUID()),
            cycle: CalendarMonth(containing: due),
            dueDate: due,
            originalDueDate: due,
            left: left.map { Money($0) },
            isOverdue: false,
            isStatementClosed: true
        )
        return ReminderItem(status: status, name: name, symbolName: "doc.text", isStrict: strict, arrivesDay: arrives)
    }

    private func plan(
        _ items: [ReminderItem],
        settings: ReminderSettings = ReminderSettings(),
        snoozes: [String: Date] = [:],
        now: Date? = nil
    ) -> ReminderPlan {
        ReminderPlanner.plan(items: items, settings: settings, snoozedUntil: snoozes, now: now ?? self.now, calendar: calendar)
    }

    // MARK: Notifications

    func testHeadsUpTheDayBeforeAtReminderTime() throws {
        let rent = item("Rent", due: day(3, 20), strict: false)
        let result = plan([rent])
        let key = rent.status.owner.key

        let byID = Dictionary(result.notifications.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        XCTAssertEqual(byID["ledger.reminder.\(key).headsup.20260319"]?.date, try at(3, 19))
        XCTAssertEqual(byID["ledger.reminder.\(key).headsup.20260319"]?.body, "Due tomorrow")
        XCTAssertEqual(byID["ledger.reminder.\(key).due.20260320"]?.date, try at(3, 20))
        XCTAssertEqual(byID["ledger.reminder.\(key).due.20260320"]?.body, "Due today")
        XCTAssertEqual(byID["ledger.reminder.\(key).due.20260321"]?.body, "1 day overdue")
        XCTAssertEqual(byID["ledger.reminder.\(key).due.20260320"]?.title, "Rent")
        XCTAssertTrue(result.activityStarts.isEmpty)
        XCTAssertTrue(result.showNow.isEmpty)
        XCTAssertEqual(result.notifications.map(\.date), result.notifications.map(\.date).sorted())
    }

    func testStrictItemGetsTwoActivityStartsPerDay() throws {
        let rent = item("Rent", due: day(3, 20))
        let result = plan([rent])

        XCTAssertEqual(result.activityStarts.map(\.date), [try at(3, 20), try at(3, 20, "17:00"), try at(3, 21)])
        XCTAssertEqual(result.activityStarts[0].lines.map(\.dateText), ["Due today"])
        XCTAssertEqual(result.activityStarts[2].lines.map(\.dateText), ["1 day overdue"])
        XCTAssertFalse(result.notifications.contains { $0.id.contains(".due.") })
        XCTAssertTrue(result.notifications.contains { $0.id.hasSuffix(".headsup.20260319") })
    }

    func testStrictNeedsBothSwitches() {
        let rent = item("Rent", due: day(3, 20), strict: true)
        let result = plan([rent], settings: ReminderSettings(isStrictEnabled: false))

        XCTAssertTrue(result.activityStarts.isEmpty)
        XCTAssertTrue(result.notifications.contains { $0.id.hasSuffix(".due.20260320") })
        XCTAssertTrue(plan([item("Rent", due: day(3, 20), strict: false)]).activityStarts.isEmpty)
    }

    func testPayingRemovesEveryFutureReminder() {
        let result = plan([item("Rent", due: day(3, 20), left: 0)])

        XCTAssertTrue(result.notifications.isEmpty)
        XCTAssertTrue(result.activityStarts.isEmpty)
        XCTAssertTrue(result.showNow.isEmpty)
    }

    // MARK: Live Activity

    func testOverdueShowsNow() {
        let result = plan([item("Rent", due: day(3, 13))])

        XCTAssertEqual(result.showNow.map(ReminderCopy.line), ["Rent · 2 days overdue"])
        XCTAssertTrue(result.showNow[0].isOverdue)
    }

    func testDueTodayShowsNowBeforeTheReminderTime() throws {
        let result = plan([item("Rent", due: day(3, 15))], now: try at(3, 15, "07:00"))

        XCTAssertEqual(result.showNow.map(ReminderCopy.line), ["Rent · due today"])
    }

    func testSnoozeHidesUntilItEnds() throws {
        let rent = item("Rent", due: day(3, 15))
        let result = plan([rent], snoozes: [rent.status.owner.key: try at(3, 15, "11:00")])

        XCTAssertTrue(result.showNow.isEmpty)
        XCTAssertEqual(result.activityStarts.first?.date, try at(3, 15, "11:00"))
        XCTAssertEqual(result.activityStarts.first?.lines.map(\.dateText), ["Due today"])
    }

    func testSnoozePastMidnightUsesTheNewDaysWording() throws {
        let rent = item("Rent", due: day(3, 15))
        let result = plan([rent], snoozes: [rent.status.owner.key: try at(3, 16, "00:30")])

        let comeback = try XCTUnwrap(result.activityStarts.first)
        XCTAssertEqual(comeback.date, try at(3, 16, "00:30"))
        XCTAssertEqual(comeback.lines.map(\.dateText), ["1 day overdue"])
    }

    func testOneActivityHoldsEverythingDueThatDay() throws {
        let result = plan([item("Rent", due: day(3, 16)), item("PayLater", due: day(3, 14))])

        let slot = try XCTUnwrap(result.activityStarts.first { $0.date == (try? at(3, 16)) })
        XCTAssertEqual(slot.lines.map(\.name), ["PayLater", "Rent"])
        XCTAssertTrue(slot.lines[0].isOverdue)
        XCTAssertFalse(slot.lines[1].isOverdue)
    }

    func testLateReminderTimeSecondStartNextDay() throws {
        let result = plan([item("Rent", due: day(3, 20))], settings: ReminderSettings(minutesAfterMidnight: 1_410))

        XCTAssertEqual(Array(result.activityStarts.map(\.date).prefix(2)), [try at(3, 20, "23:30"), try at(3, 21, "07:30")])
        let dates = result.activityStarts.map(\.date)
        XCTAssertEqual(dates.count, Set(dates).count, "Each start is planned once")
    }

    // MARK: Varying bills

    func testVaryingBillAsksUntilTheAmountIsSet() throws {
        let electricity = item("Electricity", due: day(3, 30), left: nil, strict: false, arrives: day(3, 19))
        let arrivals = plan([electricity]).notifications.filter { $0.id.contains(".arrives.") }

        XCTAssertEqual(arrivals.first?.date, try at(3, 19))
        XCTAssertEqual(arrivals.last?.date, try at(3, 29))
        XCTAssertEqual(arrivals.count, 11)
        XCTAssertTrue(arrivals.allSatisfy { $0.body == "Check if your Electricity bill came in" })

        let entered = item("Electricity", due: day(3, 30), left: 2_350, strict: false, arrives: nil)
        XCTAssertFalse(plan([entered]).notifications.contains { $0.id.contains(".arrives.") })
    }

    // MARK: Limits

    func testNothingInThePastAndNoAmounts() {
        let result = plan([
            item("Rent", due: day(3, 13), strict: false),
            item("Visa card", due: day(3, 15)),
            item("Electricity", due: day(3, 30), left: nil, strict: false, arrives: day(3, 10)),
        ])

        XCTAssertTrue(result.notifications.allSatisfy { $0.date > now })
        XCTAssertTrue(result.activityStarts.allSatisfy { $0.date > now })
        let texts = result.notifications.flatMap { [$0.title, $0.body] }
            + result.activityStarts.flatMap { $0.lines.map(ReminderCopy.line) }
            + result.showNow.map(ReminderCopy.line)
        XCTAssertFalse(texts.contains { $0.contains("₱") || $0.contains("1,000") || $0.contains("1000") })
    }

    func testCaps() {
        let items = (0..<10).map { item("Bill \($0)", due: day(3, 15)) }
            + (0..<10).map { item("Other \($0)", due: day(3, 20), strict: false) }
        let result = plan(items)

        XCTAssertLessThanOrEqual(result.activityStarts.count, 3)
        XCTAssertLessThanOrEqual(result.notifications.count, 60)
        XCTAssertEqual(result.showNow.count, 10)
    }

    func testOwnerKeysRoundTrip() {
        let id = UUID()
        XCTAssertEqual(DueOwner(key: DueOwner.account(id).key), .account(id))
        XCTAssertEqual(DueOwner(key: DueOwner.bill(id).key), .bill(id))
        XCTAssertNil(DueOwner(key: "junk"))
        XCTAssertNil(DueOwner(key: "bill-notauuid"))
    }

    // MARK: Items from the ledger

    func testReminderItemsFollowComingUp() throws {
        let h = try LedgerHarness(calendar: try fixedCalendar("Asia/Manila"))
        let card = try h.ledger.createOwedAccount(
            name: "Visa card", kind: .creditCard, terms: OwedTerms(statementDay: 5, dueDay: 25), owedNow: 2_000, stillDue: 1_000
        )
        let utilities = try h.expenseCategory("Utilities")
        try h.ledger.createBill(BillTerms(
            name: "Electricity", categoryID: utilities.id, dueDay: 30, amount: nil, arrivesDay: 19, payFromAccountID: nil
        ))

        let items = try h.ledger.reminderItems()
        XCTAssertEqual(items.map(\.name), ["Visa card", "Electricity"])
        XCTAssertEqual(items[1].arrivesDay, day(3, 19))
        XCTAssertNil(items[0].arrivesDay)
        XCTAssertTrue(items[0].isStrict)

        try h.ledger.setStrictReminder(false, for: .account(card.id))
        XCTAssertFalse(try XCTUnwrap(try h.ledger.reminderItems().first).isStrict)
    }
}
