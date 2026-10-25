import Foundation

/// Wording for a payment plan's progress, shared by every screen that shows one.
enum PlanCopy {
    /// "3 of 6 paid", or "Paid off" once every payment is made.
    static func progress(paid: Int, months: Int) -> String {
        paid >= months ? "Paid off" : "\(paid) of \(months) paid"
    }

    /// "Last payment Aug 2026".
    static func finish(_ month: CalendarMonth, locale: Locale = .autoupdatingCurrent) -> String {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let date = gregorian.date(from: DateComponents(year: month.year, month: month.month, day: 15)) ?? .distantPast
        var style = Date.FormatStyle.dateTime.month(.abbreviated).year()
        style.timeZone = gregorian.timeZone
        style.locale = locale
        return "Last payment \(date.formatted(style))"
    }
}
