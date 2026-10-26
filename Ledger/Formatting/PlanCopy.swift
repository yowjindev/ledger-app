import Foundation

/// Wording for a payment plan's progress, shared by every screen that shows one.
enum PlanCopy {
    /// "3 of 6 paid", or "Paid off" once every payment is made.
    static func progress(paid: Int, months: Int) -> String {
        paid >= months ? "Paid off" : "\(paid) of \(months) paid"
    }

    /// What a split's payments cost over the price, such as "You'll pay ₱1,100.00 in all: ₱100.00
    /// more than the price, recorded as fees and interest. That's ₱50.00 a month, 5% of the price."
    /// The share is the fee for one month as a percentage of the price, to one decimal place.
    static func splitSummary(price: Decimal, months: Int, monthly: Decimal, last: Decimal, formatter: MoneyFormatter) -> String {
        let total = monthly * Decimal(months - 1) + last
        let extra = total - price
        if extra.isZero {
            return "The payments add up to the price, so there are no fees."
        }
        if extra < .zero {
            return "The payments add up to less than the price. Check the amount of each payment."
        }
        let summary = "You'll pay \(formatter.string(Money(total))) in all: \(formatter.string(Money(extra))) more than the price, recorded as fees and interest."
        guard price > .zero, months > 0 else { return summary }
        let perMonth = extra / Decimal(months)
        var share = perMonth / price * 100
        var rounded = Decimal()
        NSDecimalRound(&rounded, &share, 1, .plain)
        let percent = rounded.formatted(.number.precision(.fractionLength(0...1)).locale(formatter.locale))
        if months == 1 {
            return "\(summary) That's \(percent)% of the price."
        }
        return "\(summary) That's \(formatter.string(Money(perMonth))) a month, \(percent)% of the price."
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
