import Foundation
import XCTest
@testable import Ledger

/// Reporting periods follow the local calendar: local midnights across daylight-saving changes,
/// the configured first weekday, and year boundaries that differ from UTC. In 2026, New York
/// springs forward on Sunday 8 March and falls back on Sunday 1 November.
@MainActor
final class ReportingPeriodTimeZoneTests: XCTestCase {
    private let hour: TimeInterval = 3_600
    private let day: TimeInterval = 86_400

    func testMonthIntervalsRunFromLocalMidnightAcrossDaylightSavingChanges() throws {
        let newYork = try fixedCalendar("America/New_York")

        let march = ReportingPeriod.thisMonth.interval(containing: try instant("2026-03-20T12:00:00Z"), calendar: newYork)
        XCTAssertEqual(march.start, try instant("2026-03-01T05:00:00Z"))
        XCTAssertEqual(march.end, try instant("2026-04-01T04:00:00Z"))
        XCTAssertEqual(march.duration, 31 * day - hour, "Springing forward makes March an hour short")

        let november = ReportingPeriod.thisMonth.interval(containing: try instant("2026-11-15T12:00:00Z"), calendar: newYork)
        XCTAssertEqual(november.start, try instant("2026-11-01T04:00:00Z"))
        XCTAssertEqual(november.end, try instant("2026-12-01T05:00:00Z"))
        XCTAssertEqual(november.duration, 30 * day + hour, "Falling back makes November an hour long")
    }

    func testWeekIntervalsHonorTheFirstWeekdayInTheSpringForwardWeek() throws {
        let springForwardSunday = try instant("2026-03-08T12:00:00Z")

        let sundayFirst = ReportingPeriod.thisWeek.interval(
            containing: springForwardSunday, calendar: try fixedCalendar("America/New_York", firstWeekday: 1)
        )
        XCTAssertEqual(sundayFirst.start, try instant("2026-03-08T05:00:00Z"))
        XCTAssertEqual(sundayFirst.end, try instant("2026-03-15T04:00:00Z"))
        XCTAssertEqual(sundayFirst.duration, 7 * day - hour)

        let mondayFirst = ReportingPeriod.thisWeek.interval(
            containing: springForwardSunday, calendar: try fixedCalendar("America/New_York", firstWeekday: 2)
        )
        XCTAssertEqual(mondayFirst.start, try instant("2026-03-02T05:00:00Z"), "With Monday first, Sunday ends the week")
        XCTAssertEqual(mondayFirst.end, try instant("2026-03-09T04:00:00Z"))

        let saturdayFirst = ReportingPeriod.thisWeek.interval(
            containing: springForwardSunday, calendar: try fixedCalendar("America/New_York", firstWeekday: 7)
        )
        XCTAssertEqual(saturdayFirst.start, try instant("2026-03-07T05:00:00Z"))
        XCTAssertEqual(saturdayFirst.end, try instant("2026-03-14T04:00:00Z"))
    }

    func testWeekAfterTheChangeIsAFullSevenDays() throws {
        let mondayFirst = try fixedCalendar("America/New_York", firstWeekday: 2)
        let week = ReportingPeriod.thisWeek.interval(containing: try instant("2026-03-09T12:00:00Z"), calendar: mondayFirst)

        XCTAssertEqual(week.start, try instant("2026-03-09T04:00:00Z"))
        XCTAssertEqual(week.duration, 7 * day)
    }

    func testYearAndLastMonthFollowLocalBoundariesRatherThanUTC() throws {
        let newYork = try fixedCalendar("America/New_York")
        let midJanuary = try instant("2026-01-15T12:00:00Z")

        let december = ReportingPeriod.lastMonth.interval(containing: midJanuary, calendar: newYork)
        XCTAssertEqual(december.start, try instant("2025-12-01T05:00:00Z"))
        XCTAssertEqual(december.end, try instant("2026-01-01T05:00:00Z"))

        let year = ReportingPeriod.thisYear.interval(containing: midJanuary, calendar: newYork)
        XCTAssertEqual(year.start, try instant("2026-01-01T05:00:00Z"))
        XCTAssertEqual(year.end, try instant("2027-01-01T05:00:00Z"))

        let newYearsEveEvening = try instant("2027-01-01T03:00:00Z")
        XCTAssertEqual(
            ReportingPeriod.thisYear.interval(containing: newYearsEveEvening, calendar: newYork), year,
            "22:00 on 31 December in New York is still this year, although it is 2027 in UTC"
        )

        let firstInstantOfMarch = try instant("2026-03-01T05:00:00Z")
        let february = ReportingPeriod.lastMonth.interval(containing: firstInstantOfMarch, calendar: newYork)
        XCTAssertEqual(february.start, try instant("2026-02-01T05:00:00Z"))
        XCTAssertEqual(february.end, firstInstantOfMarch)
    }

    func testTheSameEntryFallsInTheMonthOfTheCalendarUsed() throws {
        let h = try LedgerHarness()
        let pnb = try h.account("PNB", opening: nil)
        let food = try h.expenseCategory("Food")
        let newYork = try fixedCalendar("America/New_York")
        let manila = try fixedCalendar("Asia/Manila")
        // 23:30 on 31 March in New York is 11:30 on 1 April in Manila.
        let lateMarchInNewYork = try instant("2026-04-01T03:30:00Z")
        try h.ledger.recordExpense(amount: 100, accountID: pnb.id, categoryID: food.id, occurredAt: lateMarchInNewYork)

        let midMarch = try instant("2026-03-20T12:00:00Z")
        let marchInNewYork = ReportingPeriod.thisMonth.interval(containing: midMarch, calendar: newYork)
        let marchInManila = ReportingPeriod.thisMonth.interval(containing: midMarch, calendar: manila)
        let aprilInManila = ReportingPeriod.thisMonth.interval(containing: lateMarchInNewYork, calendar: manila)

        XCTAssertEqual(try h.ledger.periodSummary(for: marchInNewYork).expenses.amount, 100)
        XCTAssertEqual(try h.ledger.periodSummary(for: marchInManila).expenses.amount, 0)
        XCTAssertEqual(try h.ledger.periodSummary(for: aprilInManila).expenses.amount, 100)
    }

    func testWeekSummaryCountsEntriesOnBothSidesOfTheChangeAndExcludesItsEnd() throws {
        let h = try LedgerHarness()
        let gcash = try h.account("GCash", opening: nil, kind: .eWallet)
        let food = try h.expenseCategory("Food")
        let week = ReportingPeriod.thisWeek.interval(
            containing: try instant("2026-03-10T12:00:00Z"), calendar: try fixedCalendar("America/New_York", firstWeekday: 1)
        )
        func spend(_ amount: Decimal, at date: Date) throws {
            try h.ledger.recordExpense(amount: amount, accountID: gcash.id, categoryID: food.id, occurredAt: date)
        }

        try spend(10, at: try instant("2026-03-08T06:30:00Z"))  // 01:30 EST, before the change
        try spend(20, at: try instant("2026-03-08T07:30:00Z"))  // 03:30 EDT, one real hour later
        try spend(40, at: week.start)
        try spend(80, at: week.end)
        try spend(160, at: week.start.addingTimeInterval(-1))

        let summary = try h.ledger.periodSummary(for: week)
        XCTAssertEqual(summary.expenses.amount, 70)
        XCTAssertEqual(summary.expenseCount, 3)
        XCTAssertEqual(
            LedgerService.periodSummary(transactions: try h.ledger.transactions(), in: week),
            summary,
            "Summaries over fetched models match the fetched summary"
        )
    }

    func testRepeatedFallBackHourBelongsToTheSameLocalDay() throws {
        let h = try LedgerHarness()
        let gcash = try h.account("GCash", opening: nil, kind: .eWallet)
        let salary = try h.incomeSource("Salary")
        let newYork = try fixedCalendar("America/New_York", firstWeekday: 1)
        // 01:30 happens twice on 1 November 2026: first in EDT, then in EST.
        let firstPass = try instant("2026-11-01T05:30:00Z")
        let secondPass = try instant("2026-11-01T06:30:00Z")
        try h.ledger.recordIncome(amount: 1, accountID: gcash.id, sourceID: salary.id, occurredAt: firstPass)
        try h.ledger.recordIncome(amount: 2, accountID: gcash.id, sourceID: salary.id, occurredAt: secondPass)

        let november = ReportingPeriod.thisMonth.interval(containing: firstPass, calendar: newYork)
        let week = ReportingPeriod.thisWeek.interval(containing: secondPass, calendar: newYork)
        XCTAssertEqual(week.start, try instant("2026-11-01T04:00:00Z"))
        XCTAssertEqual(week.duration, 7 * day + hour)
        XCTAssertEqual(try h.ledger.periodSummary(for: november).income.amount, 3)
        XCTAssertEqual(try h.ledger.periodSummary(for: week).incomeCount, 2)
    }
}
