import Foundation
import SwiftData

extension LedgerService {
    /// Everything the due calculations need about an owed account, or `nil` for accounts
    /// without a due schedule.
    func owedDueInput(for account: Account) throws -> OwedDueInput? {
        let movements = try transactions(involving: account).compactMap(Movement.init)
        let balance = BalanceCalculator.balances(accounts: [AccountSnapshot(account)], movements: movements)[0]
        return Self.owedDueInput(
            for: account,
            balance: balance,
            movements: movements,
            plans: account.plans ?? [],
            overrides: try dueOverrides(for: account.id)
        )
    }

    /// Builds the due input from models a caller already has, such as a view's queries.
    /// `movements` may include other accounts' entries; only this account's are kept.
    static func owedDueInput(
        for account: Account,
        balance: AccountBalance,
        movements: [Movement],
        plans: [PaymentPlan],
        overrides: [DueOverride]
    ) -> OwedDueInput? {
        guard account.kind.isOwed, let schedule = account.dueSchedule else { return nil }
        let id = account.id
        return OwedDueInput(
            balance: balance,
            schedule: schedule,
            startedAt: account.createdAt,
            plans: plans.filter { $0.account?.id == id }.compactMap(PlanSnapshot.init),
            movements: movements.filter { $0.status == .posted && ($0.accountID == id || $0.destinationAccountID == id) },
            overrides: overrides.filter { $0.ownerID == id }.compactMap(DueOverrideSnapshot.init)
        )
    }

    // MARK: Coming up

    /// The current due of every active owed account with a due day and every active bill:
    /// overdue first, then unpaid, then paid, each by due date and then name.
    func comingUp() throws -> [DueStatus] {
        Self.comingUp(
            accounts: try accounts(),
            transactions: try context.fetch(FetchDescriptor<LedgerTransaction>()),
            plans: try context.fetch(FetchDescriptor<PaymentPlan>()),
            bills: try bills(),
            overrides: try context.fetch(FetchDescriptor<DueOverride>()),
            today: today,
            calendar: calendar
        )
    }

    /// Coming up over models a view already fetched, using the same calculation.
    static func comingUp(
        accounts: [Account],
        transactions: [LedgerTransaction],
        plans: [PaymentPlan],
        bills: [Bill],
        overrides: [DueOverride],
        today: CalendarDay,
        calendar: Calendar
    ) -> [DueStatus] {
        let movements = transactions.compactMap(Movement.init)
        let owed = accounts.filter { $0.kind.isOwed && !$0.isArchived }
        let balances = BalanceCalculator.balances(accounts: owed.map(AccountSnapshot.init), movements: movements)
        let balanceByID = Dictionary(balances.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var dues: [(status: DueStatus, name: String)] = []
        for account in owed {
            guard
                let balance = balanceByID[account.id],
                let input = owedDueInput(for: account, balance: balance, movements: movements, plans: plans, overrides: overrides)
            else { continue }
            dues.append((DueCalculator.status(input, today: today, calendar: calendar), account.name))
        }
        for bill in bills where !bill.isArchived {
            let input = billDueInput(for: bill, payments: transactions, overrides: overrides)
            dues.append((DueCalculator.status(input, today: today), bill.name))
        }
        return dues.sorted { lhs, rhs in
            let left = (rank(lhs.status), lhs.status.dueDate.storedValue)
            let right = (rank(rhs.status), rhs.status.dueDate.storedValue)
            if left != right { return left < right }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }.map(\.status)
    }

    /// What active owed accounts owe in total.
    func totalOwed() throws -> Money {
        try balanceSheet().totalOwed
    }

    private static func rank(_ status: DueStatus) -> Int {
        if status.isOverdue { return 0 }
        return status.isPaid ? 2 : 1
    }

    /// Where an owed account stands on its current due, or `nil` without a due schedule.
    func dueStatus(for account: Account) throws -> DueStatus? {
        guard let input = try owedDueInput(for: account) else { return nil }
        return DueCalculator.status(input, today: today, calendar: calendar)
    }

    /// Changes made to single cycles of an owed account or bill.
    func dueOverrides(for ownerID: UUID) throws -> [DueOverride] {
        try context.fetch(FetchDescriptor<DueOverride>(predicate: #Predicate { $0.ownerID == ownerID }))
    }

    /// The calendar day it is now, in the ledger's time zone.
    var today: CalendarDay {
        CalendarDay(containing: now, calendar: calendar)
    }
}

extension PlanSnapshot {
    /// `nil` for a plan without an account or a readable first due date.
    @MainActor
    init?(_ plan: PaymentPlan) {
        guard let accountID = plan.account?.id, let firstDue = plan.firstDueDay else { return nil }
        self.init(
            id: plan.id,
            accountID: accountID,
            monthlyMinor: plan.monthlyMinor,
            lastMinor: plan.lastMinor,
            months: plan.months,
            paidAtStart: plan.paidAtStart,
            firstDue: firstDue,
            feesMinor: plan.feesMinor ?? 0
        )
    }
}

extension DueOverrideSnapshot {
    /// `nil` when the stored cycle isn't a readable month.
    @MainActor
    init?(_ override: DueOverride) {
        guard let cycle = override.cycleMonth else { return nil }
        self.init(ownerID: override.ownerID, cycle: cycle, movedTo: override.movedToDay, amountMinor: override.amountMinor)
    }
}
