import Foundation

/// When a statement closes and when its payment is due, as days of the month. Each billing
/// cycle is named by the month its due date falls in. Loans and regular bills have no statement.
///
/// Days past a month's end mean its last day, so a due day of 31 falls on April 30.
struct DueSchedule: Hashable, Sendable {
    /// Day of the month the statement closes, or `nil` when dues aren't tied to a statement.
    let statementDay: Int?
    let dueDay: Int

    /// The due date of `cycle`.
    func dueDate(in cycle: CalendarMonth) -> CalendarDay {
        cycle.day(dueDay)
    }

    /// The statement close whose balance is due in `cycle`: the latest statement day strictly
    /// before the due date. `nil` without a statement day.
    func statementClose(for cycle: CalendarMonth) -> CalendarDay? {
        guard let statementDay else { return nil }
        let due = dueDate(in: cycle)
        let sameMonth = cycle.day(statementDay)
        return sameMonth < due ? sameMonth : cycle.adding(months: -1).day(statementDay)
    }

    /// The cycle whose due date is the first on or after `day`.
    func cycle(dueOnOrAfter day: CalendarDay) -> CalendarMonth {
        let month = CalendarMonth(containing: day)
        return dueDate(in: month) >= day ? month : month.adding(months: 1)
    }

    /// The cycle a purchase on `day` is billed in: the one whose statement is the first to close
    /// on or after `day`, so a purchase on the statement day belongs to the closing statement.
    /// Without a statement day, the cycle due next.
    func billingCycle(for day: CalendarDay) -> CalendarMonth {
        guard statementDay != nil else { return cycle(dueOnOrAfter: day) }
        var cycle = CalendarMonth(containing: day).adding(months: -1)
        while let close = statementClose(for: cycle), close < day {
            cycle = cycle.adding(months: 1)
        }
        return cycle
    }
}
