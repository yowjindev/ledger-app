import Foundation
import XCTest
@testable import Ledger

/// The daily interest formula: end-of-day balance × annual rate ÷ 360, rounded up to the centavo,
/// with withholding tax rounded to the nearest centavo and credited at 1:00 the next day.
@MainActor
final class InterestCalculatorTests: XCTestCase {
    private let annual = Rate(partsPerMillion: 32_500)
    private let tax = InterestTerms.defaultTaxRate

    private func manila() throws -> Calendar {
        try fixedCalendar("Asia/Manila")
    }

    // MARK: Formula

    func testGrossIsRoundedUpAndTaxToNearest() {
        XCTAssertEqual(InterestCalculator.grossMinor(balanceMinor: 4_000_000, annualRate: annual), 362, "361.11 rounds up")
        XCTAssertEqual(InterestCalculator.taxMinor(grossMinor: 362, taxRate: tax), 72, "72.4 rounds down")
        XCTAssertEqual(InterestCalculator.grossMinor(balanceMinor: 2_500_000, annualRate: annual), 226, "225.69 rounds up")
        XCTAssertEqual(InterestCalculator.taxMinor(grossMinor: 226, taxRate: tax), 45, "45.2 rounds down")
        XCTAssertEqual(InterestCalculator.taxMinor(grossMinor: 373, taxRate: tax), 75, "74.6 rounds up")
    }

    func testExactCentavosAreNotRoundedUp() {
        XCTAssertEqual(InterestCalculator.grossMinor(balanceMinor: 3_600_000, annualRate: Rate(partsPerMillion: 36_000)), 360)
    }

    func testTinyBalancesEarnACentavoAndNoTax() {
        XCTAssertEqual(InterestCalculator.grossMinor(balanceMinor: 100, annualRate: annual), 1)
        XCTAssertEqual(InterestCalculator.taxMinor(grossMinor: 1, taxRate: tax), 0)
    }

    func testMaximumBalanceDoesNotOverflow() throws {
        let maximumMinor = try XCTUnwrap(Money(AmountRules.maximum).minorUnits)
        XCTAssertEqual(maximumMinor, 99_999_999_999_999)
        XCTAssertEqual(InterestCalculator.grossMinor(balanceMinor: maximumMinor, annualRate: Rate(partsPerMillion: 1_000_000)), 277_777_777_778)
    }

    func testTaxTiesRoundAwayFromZero() {
        XCTAssertEqual(InterestCalculator.taxMinor(grossMinor: 4, taxRate: Rate(partsPerMillion: 125_000)), 1)
    }

    // MARK: Days and posting times

    func testPostingTimeIsOneAMNextDay() throws {
        let day = CalendarDay(year: 2026, month: 3, day: 15)
        XCTAssertEqual(InterestCalculator.postingTime(for: day, calendar: try manila()), try instant("2026-03-15T17:00:00Z"))
    }

    func testLastPostableDayFlipsAtOneAM() throws {
        let calendar = try manila()
        XCTAssertEqual(
            InterestCalculator.lastPostableDay(asOf: try instant("2026-03-15T16:59:59Z"), calendar: calendar),
            CalendarDay(year: 2026, month: 3, day: 14)
        )
        XCTAssertEqual(
            InterestCalculator.lastPostableDay(asOf: try instant("2026-03-15T17:00:00Z"), calendar: calendar),
            CalendarDay(year: 2026, month: 3, day: 15)
        )
    }

    func testNextPostingTimeIsTheComing1AM() throws {
        let calendar = try manila()
        XCTAssertEqual(
            InterestCalculator.nextPostingTime(after: try instant("2026-03-15T16:30:00Z"), calendar: calendar),
            try instant("2026-03-15T17:00:00Z")
        )
        XCTAssertEqual(
            InterestCalculator.nextPostingTime(after: try instant("2026-03-15T17:00:00Z"), calendar: calendar),
            try instant("2026-03-16T17:00:00Z")
        )
        XCTAssertEqual(
            InterestCalculator.nextPostingTime(after: try instant("2026-03-15T02:00:00Z"), calendar: calendar),
            try instant("2026-03-15T17:00:00Z")
        )
    }

    func testCalendarDayStoresAndSteps() throws {
        let calendar = try manila()
        let day = CalendarDay(year: 2026, month: 3, day: 15)
        XCTAssertEqual(day.storedValue, 20_260_315)
        XCTAssertEqual(CalendarDay(storedValue: 20_260_315), day)
        XCTAssertNil(CalendarDay(storedValue: 20_261_340))
        XCTAssertNil(CalendarDay(storedValue: 20_260_230), "February 30th")
        XCTAssertEqual(CalendarDay(year: 2026, month: 2, day: 28).adding(days: 1, calendar: calendar), CalendarDay(year: 2026, month: 3, day: 1))
        XCTAssertEqual(day.adding(days: -15, calendar: calendar), CalendarDay(year: 2026, month: 2, day: 28))
        XCTAssertEqual(CalendarDay(containing: try instant("2026-03-15T16:30:00Z"), calendar: calendar), CalendarDay(year: 2026, month: 3, day: 16))
        XCTAssertEqual(day.start(in: calendar), try instant("2026-03-14T16:00:00Z"))
        XCTAssertLessThan(day, CalendarDay(year: 2026, month: 3, day: 16))
    }

    func testCalendarDaysAreGregorianWhateverTheDeviceCalendar() throws {
        let identifiers: [Calendar.Identifier] = [.buddhist, .japanese, .persian, .islamicUmmAlQura, .hebrew]
        for identifier in identifiers {
            var calendar = Calendar(identifier: identifier)
            calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Manila"))
            let label = "\(identifier)"
            XCTAssertEqual(CalendarDay(containing: try instant("2026-03-15T16:30:00Z"), calendar: calendar), CalendarDay(year: 2026, month: 3, day: 16), label)
            XCTAssertEqual(CalendarDay(year: 2026, month: 3, day: 16).start(in: calendar), try instant("2026-03-15T16:00:00Z"), label)
            XCTAssertEqual(CalendarDay(year: 2026, month: 2, day: 28).adding(days: 1, calendar: calendar), CalendarDay(year: 2026, month: 3, day: 1), label)
            XCTAssertEqual(
                InterestCalculator.lastPostableDay(asOf: try instant("2026-03-15T17:00:00Z"), calendar: calendar),
                CalendarDay(year: 2026, month: 3, day: 15),
                label
            )
        }
    }

    // MARK: Rates

    func testRateParsingAcceptsLocaleAndPercentSign() {
        let us = Locale(identifier: "en_US")
        XCTAssertEqual(Rate.parse("3.25", locale: us), dec("3.25"))
        XCTAssertEqual(Rate.parse("3,25", locale: Locale(identifier: "de_DE")), dec("3.25"))
        XCTAssertEqual(Rate.parse("3.25%", locale: us), dec("3.25"))
        XCTAssertEqual(Rate.parse(" 4 % ", locale: us), 4)
        XCTAssertNil(Rate.parse("abc", locale: us))
        XCTAssertNil(Rate.parse("", locale: us))
        XCTAssertNil(Rate.parse("%", locale: us))
    }

    func testRatesRoundTripThroughEditableText() throws {
        let us = Locale(identifier: "en_US"), fr = Locale(identifier: "fr_FR")
        XCTAssertEqual(Rate(partsPerMillion: 31_250).editableText(locale: us), "3.125")
        XCTAssertEqual(Rate(partsPerMillion: 625).editableText(locale: us), "0.0625")
        XCTAssertEqual(Rate(partsPerMillion: 31_250).editableText(locale: fr), "3,125")
        XCTAssertEqual(Rate(partsPerMillion: 200_000).editableText(locale: us), "20")
        for ppm: Int64 in [31_250, 625, 32_500, 1, 1_000_000] {
            for locale in [us, fr] {
                let text = Rate(partsPerMillion: ppm).editableText(locale: locale)
                let sanitized = AmountParser.sanitize(text, locale: locale, maximumFractionDigits: RateRules.maximumFractionDigits, maximumIntegerDigits: 3)
                XCTAssertEqual(sanitized, text, "The editor keeps the text it was given")
                let percent = try XCTUnwrap(Rate.parse(sanitized, locale: locale))
                XCTAssertEqual(try RateRules.annualRate(percent: percent).partsPerMillion, ppm)
            }
        }
    }

    func testRateRules() throws {
        assertThrowsLedgerError(.interestRateOutOfRange) { try RateRules.annualRate(percent: 0) }
        assertThrowsLedgerError(.interestRateOutOfRange) { try RateRules.annualRate(percent: dec("100.0001")) }
        assertThrowsLedgerError(.rateTooPrecise) { try RateRules.annualRate(percent: dec("3.12345")) }
        XCTAssertEqual(try RateRules.annualRate(percent: dec("3.25")), Rate(partsPerMillion: 32_500))
        XCTAssertEqual(try RateRules.annualRate(percent: 100), Rate(partsPerMillion: 1_000_000))
        XCTAssertEqual(try RateRules.taxRate(percent: 0), Rate(partsPerMillion: 0))
        XCTAssertEqual(try RateRules.taxRate(percent: 20), Rate(partsPerMillion: 200_000))
        assertThrowsLedgerError(.taxRateOutOfRange) { try RateRules.taxRate(percent: -1) }
        assertThrowsLedgerError(.taxRateOutOfRange) { try RateRules.taxRate(percent: 101) }
        XCTAssertEqual(Rate(partsPerMillion: 32_500).percent, dec("3.25"))
    }

    // MARK: Daily interest

    private func savings(opening: Int64?) -> AccountSnapshot {
        AccountSnapshot(id: UUID(), name: "Savings", kind: .bank, currency: .php, openingBalanceMinor: opening, isArchived: false, sortOrder: 0)
    }

    private func expense(_ amountMinor: Int64, from account: AccountSnapshot, at text: String) throws -> Movement {
        Movement(
            kind: .expense, status: .posted, amountMinor: amountMinor, currency: .php,
            accountID: account.id, destinationAccountID: nil, occurredAt: try instant(text)
        )
    }

    func testDailyInterestUsesEndOfDayBalanceAndCompounds() throws {
        let calendar = try manila()
        let account = savings(opening: 4_000_000)
        let movements = [
            try expense(1_000_000, from: account, at: "2026-03-15T08:00:00Z"),
            try expense(100_000, from: account, at: "2026-03-15T16:30:00Z"),
        ]

        let days = InterestCalculator.dailyInterest(
            account: account,
            terms: InterestTerms(annualRate: annual, taxRate: tax),
            after: CalendarDay(year: 2026, month: 3, day: 14),
            through: CalendarDay(year: 2026, month: 3, day: 17),
            movements: movements,
            calendar: calendar
        )

        XCTAssertEqual(days.map(\.day), [15, 16, 17].map { CalendarDay(year: 2026, month: 3, day: $0) })
        XCTAssertEqual(days.map(\.balanceMinor), [3_000_000, 2_900_217, 2_900_427])
        XCTAssertEqual(days.map(\.grossMinor), [271, 262, 262])
        XCTAssertEqual(days.map(\.taxMinor), [54, 52, 52])
        XCTAssertEqual(days.map(\.postedAt), [
            try instant("2026-03-15T17:00:00Z"), try instant("2026-03-16T17:00:00Z"), try instant("2026-03-17T17:00:00Z"),
        ])
        XCTAssertEqual(Set(days.map(\.accountID)), [account.id])
        XCTAssertEqual(days.first?.annualRate, annual)
        XCTAssertEqual(days.first?.taxRate, tax)
    }

    func testDaysWithoutAPositiveKnownBalanceEarnNothing() throws {
        let calendar = try manila()
        let terms = InterestTerms(annualRate: annual, taxRate: tax)
        let after = CalendarDay(year: 2026, month: 3, day: 14)
        let through = CalendarDay(year: 2026, month: 3, day: 15)
        func interest(_ account: AccountSnapshot, _ movements: [Movement] = []) -> [DailyInterest] {
            InterestCalculator.dailyInterest(account: account, terms: terms, after: after, through: through, movements: movements, calendar: calendar)
        }

        XCTAssertEqual(interest(savings(opening: nil)), [])
        XCTAssertEqual(interest(savings(opening: 0)), [])
        let overdrawn = savings(opening: 10_000)
        XCTAssertEqual(interest(overdrawn, [try expense(15_000, from: overdrawn, at: "2026-03-15T03:00:00Z")]), [])
        XCTAssertEqual(
            InterestCalculator.dailyInterest(account: savings(opening: 4_000_000), terms: terms, after: through, through: through, movements: [], calendar: calendar),
            [],
            "Nothing is due when every day is paid"
        )
    }
}
