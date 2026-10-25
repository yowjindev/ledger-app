import Foundation

/// A Gregorian month, such as March 2026, stored as yyyymm (202603). Billing cycles are named by
/// the month their due date falls in.
struct CalendarMonth: Hashable, Comparable, Sendable, CustomStringConvertible {
    let year: Int
    let month: Int

    init(year: Int, month: Int) {
        self.year = year
        self.month = month
    }

    /// The month `day` falls in.
    init(containing day: CalendarDay) {
        self.init(year: day.year, month: day.month)
    }

    /// Reads a stored yyyymm value; `nil` when the month isn't 1 to 12.
    init?(storedValue: Int) {
        let month = storedValue % 100
        guard storedValue > 0, (1...12).contains(month) else { return nil }
        self.init(year: storedValue / 100, month: month)
    }

    var storedValue: Int { year * 100 + month }

    /// The number of days in the month, following the Gregorian leap-year rule.
    var dayCount: Int {
        switch month {
        case 2: isLeapYear ? 29 : 28
        case 4, 6, 9, 11: 30
        default: 31
        }
    }

    /// The month `months` later (or earlier, when negative).
    func adding(months: Int) -> CalendarMonth {
        let index = year * 12 + (month - 1) + months
        return CalendarMonth(year: index / 12, month: index % 12 + 1)
    }

    /// The given day of this month, clamped to its length: day 31 in a 30-day month is the 30th.
    func day(_ day: Int) -> CalendarDay {
        CalendarDay(year: year, month: month, day: min(max(day, 1), dayCount))
    }

    private var isLeapYear: Bool {
        (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
    }

    static func < (lhs: CalendarMonth, rhs: CalendarMonth) -> Bool {
        lhs.storedValue < rhs.storedValue
    }

    var description: String { String(format: "%04d-%02d", year, month) }
}
