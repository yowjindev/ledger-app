import Foundation

/// Wording for a due, shared by every screen that shows one.
enum DueStatusCopy {
    static let amountNotSet = "Amount not set"
    static let paid = "Paid"

    /// "₱1,050.00 left", "Paid", "Amount not set", or "₱3,980.00 so far" while a statement is
    /// still open.
    static func amountText(_ status: DueStatus, formatter: MoneyFormatter) -> String {
        guard let left = status.left else { return amountNotSet }
        if status.isPaid { return paid }
        let amount = formatter.string(left)
        return status.isStatementClosed ? "\(amount) left" : "\(amount) so far"
    }

    /// "Due today", "Due tomorrow", "Due Nov 5", "1 day overdue", or "3 days overdue".
    static func dateText(
        _ status: DueStatus,
        today: CalendarDay,
        calendar: Calendar,
        locale: Locale = .autoupdatingCurrent
    ) -> String {
        let days = daysBetween(today, and: status.dueDate, calendar: calendar)
        if status.isOverdue {
            let late = max(1, -days)
            return late == 1 ? "1 day overdue" : "\(late) days overdue"
        }
        switch days {
        case 0: return "Due today"
        case 1: return "Due tomorrow"
        default: return "Due \(shortDate(status.dueDate, calendar: calendar, locale: locale))"
        }
    }

    /// A day as "Nov 5".
    static func shortDate(_ day: CalendarDay, calendar: Calendar, locale: Locale = .autoupdatingCurrent) -> String {
        var style = Date.FormatStyle.dateTime.month(.abbreviated).day()
        style.timeZone = calendar.timeZone
        style.locale = locale
        return day.start(in: calendar).formatted(style)
    }

    /// Whole days from `start` to `end`, negative when `end` is earlier.
    private static func daysBetween(_ start: CalendarDay, and end: CalendarDay, calendar: Calendar) -> Int {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        return gregorian.dateComponents([.day], from: start.start(in: calendar), to: end.start(in: calendar)).day ?? 0
    }
}
