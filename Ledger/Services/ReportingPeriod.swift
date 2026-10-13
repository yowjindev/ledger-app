import Foundation

/// Periods available for income and expense summaries. Intervals follow the user's calendar,
/// time zone, and first weekday.
enum ReportingPeriod: String, CaseIterable, Identifiable, Sendable {
    case thisWeek
    case thisMonth
    case lastMonth
    case thisYear

    var id: String { rawValue }

    var title: String {
        switch self {
        case .thisWeek: "This Week"
        case .thisMonth: "This Month"
        case .lastMonth: "Last Month"
        case .thisYear: "This Year"
        }
    }

    /// The half-open interval `[start, end)` of this period relative to `date`.
    func interval(containing date: Date, calendar: Calendar = .current) -> DateInterval {
        let component: Calendar.Component
        var anchor = date
        switch self {
        case .thisWeek:
            component = .weekOfYear
        case .thisMonth:
            component = .month
        case .lastMonth:
            component = .month
            if let monthStart = calendar.dateInterval(of: .month, for: date)?.start,
               let previousMonth = calendar.date(byAdding: .month, value: -1, to: monthStart) {
                anchor = previousMonth
            }
        case .thisYear:
            component = .year
        }
        return calendar.dateInterval(of: component, for: anchor) ?? DateInterval(start: anchor, duration: 0)
    }
}
