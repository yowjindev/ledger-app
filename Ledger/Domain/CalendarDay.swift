import Foundation

/// A Gregorian date, such as March 15, 2026, independent of time zone. Stored as yyyymmdd
/// (20260315) so a day already handled stays handled when the device changes time zone.
///
/// Days are always Gregorian, whatever calendar system the device uses (Buddhist, Japanese,
/// Persian, and so on). Only the time zone of a passed calendar is used.
struct CalendarDay: Hashable, Comparable, Sendable, CustomStringConvertible {
    let year: Int
    let month: Int
    let day: Int

    init(year: Int, month: Int, day: Int) {
        self.year = year
        self.month = month
        self.day = day
    }

    /// The day `date` falls on in `calendar`'s time zone.
    init(containing date: Date, calendar: Calendar) {
        let components = Self.gregorian(in: calendar).dateComponents([.year, .month, .day], from: date)
        self.init(year: components.year ?? 0, month: components.month ?? 0, day: components.day ?? 0)
    }

    /// Reads a stored yyyymmdd value; `nil` when it isn't a real Gregorian date.
    init?(storedValue: Int) {
        let year = storedValue / 10_000
        let month = storedValue / 100 % 100
        let day = storedValue % 100
        let gregorian = Calendar(identifier: .gregorian)
        guard DateComponents(calendar: gregorian, year: year, month: month, day: day).isValidDate else { return nil }
        self.init(year: year, month: month, day: day)
    }

    var storedValue: Int { year * 10_000 + month * 100 + day }

    /// The first moment of this day in `calendar`'s time zone.
    func start(in calendar: Calendar) -> Date {
        let gregorian = Self.gregorian(in: calendar)
        return gregorian.startOfDay(for: noon(in: gregorian))
    }

    /// The day `days` later (or earlier, when negative).
    func adding(days: Int, calendar: Calendar) -> CalendarDay {
        let gregorian = Self.gregorian(in: calendar)
        // Stepping from noon keeps the arithmetic clear of daylight-saving transitions at midnight.
        let noon = noon(in: gregorian)
        let moved = gregorian.date(byAdding: .day, value: days, to: noon) ?? noon
        return CalendarDay(containing: moved, calendar: gregorian)
    }

    private func noon(in gregorian: Calendar) -> Date {
        gregorian.date(from: DateComponents(year: year, month: month, day: day, hour: 12)) ?? .distantPast
    }

    /// A Gregorian calendar in `calendar`'s time zone.
    private static func gregorian(in calendar: Calendar) -> Calendar {
        guard calendar.identifier != .gregorian else { return calendar }
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        return gregorian
    }

    static func < (lhs: CalendarDay, rhs: CalendarDay) -> Bool {
        lhs.storedValue < rhs.storedValue
    }

    var description: String { String(format: "%04d-%02d-%02d", year, month, day) }
}
