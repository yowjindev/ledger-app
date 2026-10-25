import Foundation

/// One day's interest on one account.
struct DailyInterest: Hashable, Sendable {
    let accountID: UUID
    /// The day the interest was earned.
    let day: CalendarDay
    /// 1:00 on the following day, when the bank credits it.
    let postedAt: Date
    /// The account's balance at the end of `day`, in minor units.
    let balanceMinor: Int64
    let annualRate: Rate
    let taxRate: Rate
    let grossMinor: Int64
    let taxMinor: Int64
}

/// Daily interest arithmetic over immutable snapshots. No persistence access.
///
/// Each day earns the day's ending balance × annual rate ÷ 360, rounded up to the centavo, and
/// withholding tax is that interest × the tax rate, rounded to the nearest centavo. The bank
/// credits both at 1:00 the next day, so each day's interest counts toward the next day's balance.
enum InterestCalculator {
    /// Days in the year the annual rate is divided by.
    static let dayCountBasis = 360

    /// Gross interest for one day on `balanceMinor`, rounded up to the minor unit.
    static func grossMinor(balanceMinor: Int64, annualRate: Rate) -> Int64 {
        let divisor = Decimal(1_000_000) * Decimal(dayCountBasis)
        return rounded(Decimal(balanceMinor) * Decimal(annualRate.partsPerMillion) / divisor, .up)
    }

    /// Withholding tax on `grossMinor`, rounded to the nearest minor unit (halves away from zero).
    static func taxMinor(grossMinor: Int64, taxRate: Rate) -> Int64 {
        rounded(Decimal(grossMinor) * Decimal(taxRate.partsPerMillion) / 1_000_000, .plain)
    }

    /// When interest earned on `day` is credited: 1:00 on the following day.
    static func postingTime(for day: CalendarDay, calendar: Calendar) -> Date {
        let nextDay = day.adding(days: 1, calendar: calendar).start(in: calendar)
        return calendar.date(byAdding: .hour, value: 1, to: nextDay) ?? nextDay
    }

    /// The latest day whose interest is credited at or before `now`.
    static func lastPostableDay(asOf now: Date, calendar: Calendar) -> CalendarDay {
        let yesterday = CalendarDay(containing: now, calendar: calendar).adding(days: -1, calendar: calendar)
        return now >= postingTime(for: yesterday, calendar: calendar) ? yesterday : yesterday.adding(days: -1, calendar: calendar)
    }

    /// The first time after `now` that interest is credited.
    static func nextPostingTime(after now: Date, calendar: Calendar) -> Date {
        let today = CalendarDay(containing: now, calendar: calendar)
        let thisMorning = postingTime(for: today.adding(days: -1, calendar: calendar), calendar: calendar)
        return thisMorning > now ? thisMorning : postingTime(for: today, calendar: calendar)
    }

    /// Interest for each day after `paidThrough` through `lastDay`, in order.
    ///
    /// Each day uses the account's balance at the end of that day: the opening balance plus every
    /// movement before the next day starts, plus the interest and tax computed for earlier days in
    /// this call. Days whose balance is unknown, zero, or negative earn nothing.
    static func dailyInterest(
        account: AccountSnapshot,
        terms: InterestTerms,
        after paidThrough: CalendarDay,
        through lastDay: CalendarDay,
        movements: [Movement],
        calendar: Calendar
    ) -> [DailyInterest] {
        guard account.openingBalanceMinor != nil else { return [] }
        var relevant = movements.filter { $0.accountID == account.id || $0.destinationAccountID == account.id }
        var results: [DailyInterest] = []
        var day = paidThrough.adding(days: 1, calendar: calendar)
        while day <= lastDay {
            let nextDay = day.adding(days: 1, calendar: calendar)
            let end = nextDay.start(in: calendar)
            let balance = BalanceCalculator.balances(accounts: [account], movements: relevant.filter { $0.occurredAt < end })
                .first?.currentBalance
            if let balance, balance.isPositive, let balanceMinor = balance.minorUnits {
                let gross = grossMinor(balanceMinor: balanceMinor, annualRate: terms.annualRate)
                let tax = taxMinor(grossMinor: gross, taxRate: terms.taxRate)
                let postedAt = postingTime(for: day, calendar: calendar)
                results.append(DailyInterest(
                    accountID: account.id,
                    day: day,
                    postedAt: postedAt,
                    balanceMinor: balanceMinor,
                    annualRate: terms.annualRate,
                    taxRate: terms.taxRate,
                    grossMinor: gross,
                    taxMinor: tax
                ))
                relevant.append(movement(.income, gross, account: account, at: postedAt))
                if tax > 0 {
                    relevant.append(movement(.expense, tax, account: account, at: postedAt))
                }
            }
            day = nextDay
        }
        return results
    }

    private static func movement(_ kind: TransactionKind, _ amountMinor: Int64, account: AccountSnapshot, at date: Date) -> Movement {
        Movement(
            kind: kind,
            status: .posted,
            amountMinor: amountMinor,
            currency: account.currency,
            accountID: account.id,
            destinationAccountID: nil,
            occurredAt: date
        )
    }

    private static func rounded(_ value: Decimal, _ mode: NSDecimalNumber.RoundingMode) -> Int64 {
        var value = value
        var result = Decimal()
        NSDecimalRound(&result, &value, 0, mode)
        return NSDecimalNumber(decimal: result).int64Value
    }
}
