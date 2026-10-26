import Foundation

/// One monthly payment of a plan, due in `cycle`.
struct PlanSlice: Hashable, Sendable {
    let cycle: CalendarMonth
    let amountMinor: Int64
}

/// An immutable copy of the payment plan fields the due calculations need.
struct PlanSnapshot: Hashable, Sendable {
    let id: UUID
    let accountID: UUID
    let monthlyMinor: Int64
    let lastMinor: Int64
    let months: Int
    let paidAtStart: Int
    /// Due date of the first payment still to make.
    let firstDue: CalendarDay
    /// Fees stored on the plan, for one added without entries. A split logged in Ledger keeps its
    /// fees in an entry instead, so this is zero for it.
    var feesMinor: Int64 = 0

    /// The payments still to make, one per cycle from `firstDue`'s month; the final one is
    /// `lastMinor`.
    var slices: [PlanSlice] {
        let remaining = max(months - paidAtStart, 0)
        let first = CalendarMonth(containing: firstDue)
        return (0..<remaining).map { index in
            PlanSlice(cycle: first.adding(months: index), amountMinor: index == remaining - 1 ? lastMinor : monthlyMinor)
        }
    }
}

/// An immutable copy of a change to one cycle's due.
struct DueOverrideSnapshot: Hashable, Sendable {
    let ownerID: UUID
    let cycle: CalendarMonth
    let movedTo: CalendarDay?
    let amountMinor: Int64?
}

/// An owed account's limit, what's left of it, and the unpaid fees left out of what counts
/// against it.
struct LimitStatus: Hashable, Sendable {
    let limit: Money
    /// `nil` while the balance is unknown.
    let available: Money?
    /// Unpaid split fees taken off what counts against the limit; zero when none are.
    let feesOffLimit: Money
}

/// What a due belongs to.
enum DueOwner: Hashable, Sendable {
    case account(UUID)
    case bill(UUID)
}

/// Where one owed account or bill stands on its current due.
struct DueStatus: Hashable, Sendable {
    let owner: DueOwner
    let cycle: CalendarMonth
    /// The due date, after any move.
    let dueDate: CalendarDay
    let originalDueDate: CalendarDay
    /// What's left to pay, or `nil` while the amount isn't known: an owed account without an
    /// opening balance, or a varying bill whose amount hasn't been entered.
    let left: Money?
    let isOverdue: Bool
    /// `false` while a card or pay later statement is still open, so `left` can still grow.
    let isStatementClosed: Bool

    var isPaid: Bool { left?.isZero == true }
}

extension DueStatus: Identifiable {
    var id: DueOwner { owner }
}

/// Everything about one owed account the due calculations need.
struct OwedDueInput: Sendable {
    let balance: AccountBalance
    let schedule: DueSchedule
    /// When the account was added. Dues before that day are ignored.
    let startedAt: Date
    let plans: [PlanSnapshot]
    /// Posted movements involving the account.
    let movements: [Movement]
    let overrides: [DueOverrideSnapshot]

    var accountID: UUID { balance.account.id }
}

/// Pure due calculations for credit cards, pay later accounts, and loans. Nothing is stored about
/// payments: what's left on a due follows from the balance, so any transfer into the account
/// counts toward it as soon as it's recorded.
enum DueCalculator {
    /// What's left to pay for the due in `cycle`:
    /// what's owed now − charges billed in later cycles − plan payments due in later cycles.
    /// Charges billed later are what raised the balance after the statement closed: purchases
    /// (less their cashback), money taken out, and balance adjustments.
    ///
    /// For the cycle that was waiting for payment when the account was added, the "still due"
    /// amount entered then, less payments since. `nil` while the opening balance is unknown.
    static func left(in cycle: CalendarMonth, _ input: OwedDueInput, calendar: Calendar) -> Money? {
        guard let owed = input.balance.owed else { return nil }
        let currency = owed.currency
        let startDay = CalendarDay(containing: input.startedAt, calendar: calendar)

        if let amountMinor = override(for: cycle, input)?.amountMinor,
           let close = input.schedule.statementClose(for: cycle),
           close < startDay, startDay <= input.schedule.dueDate(in: cycle) {
            let paid = sum(input.movements.filter {
                $0.kind == .transfer && $0.destinationAccountID == input.accountID && $0.occurredAt >= input.startedAt
            })
            return Money(max(.zero, Money(minorUnits: amountMinor, currency: currency).amount - paid), currency: currency)
        }

        var laterCharges = Decimal.zero
        if let close = input.schedule.statementClose(for: cycle) {
            for movement in input.movements where movement.accountID == input.accountID
                && CalendarDay(containing: movement.occurredAt, calendar: calendar) > close {
                switch movement.kind {
                case .expense where movement.planID == nil && movement.origin != .planFees:
                    laterCharges += amount(of: movement)
                case .income where movement.origin == .cashback:
                    laterCharges -= amount(of: movement)
                case .transfer:
                    // Money taken out of the account, such as a cash advance.
                    laterCharges += amount(of: movement)
                case .adjustment:
                    laterCharges += movement.direction == .decrease ? amount(of: movement) : -amount(of: movement)
                default:
                    break
                }
            }
        }
        let laterSlices = input.plans.flatMap(\.slices).filter { $0.cycle > cycle }.reduce(Int64(0)) { $0 + $1.amountMinor }
        let left = owed.amount - laterCharges - Money(minorUnits: laterSlices, currency: currency).amount
        return Money(max(.zero, left), currency: currency)
    }

    /// The due that needs attention on `today`: the previous one while it's overdue, otherwise
    /// the next one on or after today.
    static func status(_ input: OwedDueInput, today: CalendarDay, calendar: Calendar) -> DueStatus {
        let eligible = firstEligibleCycle(input, calendar: calendar)
        let upcoming = upcomingCycle(input, today: today, eligible: eligible)
        let previous = upcoming.adding(months: -1)
        if previous >= eligible, effectiveDue(previous, input) < today,
           let left = left(in: previous, input, calendar: calendar), left.isPositive {
            return makeStatus(previous, input, left: left, isOverdue: true, today: today)
        }
        return makeStatus(upcoming, input, left: left(in: upcoming, input, calendar: calendar), isOverdue: false, today: today)
    }

    /// Months of `plan` paid: those paid before it was added, plus its payments due on or before
    /// the latest due that's fully paid. A paid due means every earlier one is paid too, so one
    /// payment is never counted for two plans.
    static func monthsPaid(_ plan: PlanSnapshot, _ input: OwedDueInput, today: CalendarDay, calendar: Calendar) -> Int {
        let eligible = firstEligibleCycle(input, calendar: calendar)
        var cycle = upcomingCycle(input, today: today, eligible: eligible)
        while cycle >= eligible {
            if left(in: cycle, input, calendar: calendar)?.isZero == true {
                let covered = plan.slices.filter { $0.cycle <= cycle }.count
                return min(plan.months, plan.paidAtStart + covered)
            }
            cycle = cycle.adding(months: -1)
        }
        return plan.paidAtStart
    }

    /// The limit and what's left of it: the limit less what's owed. On a pay later account whose
    /// fees don't use the limit, its plans' unpaid fees are left out of what's owed, never taking
    /// it below zero. `nil` without a limit.
    static func limitStatus(
        limitMinor: Int64?,
        balance: AccountBalance,
        input: OwedDueInput?,
        feesUseLimit: Bool,
        today: CalendarDay,
        calendar: Calendar
    ) -> LimitStatus? {
        guard let limitMinor else { return nil }
        let currency = balance.account.currency
        let limit = Money(minorUnits: limitMinor, currency: currency)
        guard let owed = balance.owed else {
            return LimitStatus(limit: limit, available: nil, feesOffLimit: .zero(currency))
        }
        var unpaidMinor: Int64 = 0
        if balance.account.kind == .payLater, !feesUseLimit, let input {
            for plan in input.plans {
                unpaidMinor += unpaidFees(
                    feesMinor: fees(of: plan, input),
                    months: plan.months,
                    monthsPaid: monthsPaid(plan, input, today: today, calendar: calendar)
                )
            }
        }
        let feesOff = min(Money(minorUnits: unpaidMinor, currency: currency).amount, max(owed.amount, .zero))
        return LimitStatus(
            limit: limit,
            available: limit - Money(owed.amount - feesOff, currency: currency),
            feesOffLimit: Money(feesOff, currency: currency)
        )
    }

    /// A plan's fees: its fees entry, if it has one, plus the fees stored on it.
    static func fees(of plan: PlanSnapshot, _ input: OwedDueInput) -> Int64 {
        input.movements
            .filter { $0.planID == plan.id && $0.origin == .planFees }
            .reduce(plan.feesMinor) { $0 + $1.amountMinor }
    }

    /// The part of a plan's fees not yet paid after `monthsPaid` of its `months`. The paid share
    /// is rounded down, so it reaches zero only on the last payment.
    static func unpaidFees(feesMinor: Int64, months: Int, monthsPaid: Int) -> Int64 {
        guard months > 0 else { return 0 }
        let paid = Int64(min(max(monthsPaid, 0), months))
        return feesMinor - feesMinor * paid / Int64(months)
    }

    // MARK: Helpers

    /// The first cycle due on or after the day the account was added.
    private static func firstEligibleCycle(_ input: OwedDueInput, calendar: Calendar) -> CalendarMonth {
        input.schedule.cycle(dueOnOrAfter: CalendarDay(containing: input.startedAt, calendar: calendar))
    }

    /// The first eligible cycle whose due date, after any move, is on or after `today`.
    private static func upcomingCycle(_ input: OwedDueInput, today: CalendarDay, eligible: CalendarMonth) -> CalendarMonth {
        var cycle = max(eligible, input.schedule.cycle(dueOnOrAfter: today).adding(months: -1))
        while effectiveDue(cycle, input) < today {
            cycle = cycle.adding(months: 1)
        }
        return cycle
    }

    private static func effectiveDue(_ cycle: CalendarMonth, _ input: OwedDueInput) -> CalendarDay {
        override(for: cycle, input)?.movedTo ?? input.schedule.dueDate(in: cycle)
    }

    private static func override(for cycle: CalendarMonth, _ input: OwedDueInput) -> DueOverrideSnapshot? {
        input.overrides.first { $0.ownerID == input.accountID && $0.cycle == cycle }
    }

    private static func makeStatus(_ cycle: CalendarMonth, _ input: OwedDueInput, left: Money?, isOverdue: Bool, today: CalendarDay) -> DueStatus {
        let isClosed = input.schedule.statementClose(for: cycle).map { $0 < today } ?? true
        return DueStatus(
            owner: .account(input.accountID),
            cycle: cycle,
            dueDate: effectiveDue(cycle, input),
            originalDueDate: input.schedule.dueDate(in: cycle),
            left: left,
            isOverdue: isOverdue,
            isStatementClosed: isClosed
        )
    }

    private static func amount(of movement: Movement) -> Decimal {
        Decimal(movement.amountMinor) / movement.currency.minorUnitScale
    }

    private static func sum(_ movements: [Movement]) -> Decimal {
        movements.reduce(.zero) { $0 + amount(of: $1) }
    }
}

/// Everything about one regular bill the due calculations need.
struct BillDueInput: Sendable {
    let billID: UUID
    let schedule: DueSchedule
    /// The first cycle tracked; earlier cycles are never due.
    let startCycle: CalendarMonth
    /// The usual monthly amount, or `nil` when it varies.
    let amountMinor: Int64?
    /// Payments recorded for each cycle.
    let paidByCycle: [CalendarMonth: Int64]
    let overrides: [DueOverrideSnapshot]
    let currency: CurrencyCode
}

extension DueCalculator {
    /// Where a bill stands on `today`: last month's cycle while it's overdue, otherwise the next
    /// due. Unlike debts, each cycle stands alone: what's left is that month's amount less the
    /// payments recorded for it.
    static func status(_ input: BillDueInput, today: CalendarDay) -> DueStatus {
        var upcoming = max(input.startCycle, input.schedule.cycle(dueOnOrAfter: today).adding(months: -1))
        while effectiveDue(upcoming, input) < today {
            upcoming = upcoming.adding(months: 1)
        }
        let previous = upcoming.adding(months: -1)
        if previous >= input.startCycle, effectiveDue(previous, input) < today {
            let left = left(in: previous, input)
            if left.map(\.isPositive) ?? true {
                return makeStatus(previous, input, left: left, isOverdue: true)
            }
        }
        return makeStatus(upcoming, input, left: left(in: upcoming, input), isOverdue: false)
    }

    private static func left(in cycle: CalendarMonth, _ input: BillDueInput) -> Money? {
        guard let amountMinor = override(for: cycle, input)?.amountMinor ?? input.amountMinor else { return nil }
        let leftMinor = max(0, amountMinor - (input.paidByCycle[cycle] ?? 0))
        return Money(minorUnits: leftMinor, currency: input.currency)
    }

    private static func effectiveDue(_ cycle: CalendarMonth, _ input: BillDueInput) -> CalendarDay {
        override(for: cycle, input)?.movedTo ?? input.schedule.dueDate(in: cycle)
    }

    private static func override(for cycle: CalendarMonth, _ input: BillDueInput) -> DueOverrideSnapshot? {
        input.overrides.first { $0.ownerID == input.billID && $0.cycle == cycle }
    }

    private static func makeStatus(_ cycle: CalendarMonth, _ input: BillDueInput, left: Money?, isOverdue: Bool) -> DueStatus {
        DueStatus(
            owner: .bill(input.billID),
            cycle: cycle,
            dueDate: effectiveDue(cycle, input),
            originalDueDate: input.schedule.dueDate(in: cycle),
            left: left,
            isOverdue: isOverdue,
            isStatementClosed: true
        )
    }
}
