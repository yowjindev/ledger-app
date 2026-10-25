import Foundation
import SwiftData

extension LedgerService {
    /// Everything the due calculations need about an owed account, or `nil` for accounts
    /// without a due schedule.
    func owedDueInput(for account: Account) throws -> OwedDueInput? {
        guard account.kind.isOwed, let schedule = account.dueSchedule else { return nil }
        let movements = try transactions(involving: account).compactMap(Movement.init).filter { $0.status == .posted }
        let balance = BalanceCalculator.balances(accounts: [AccountSnapshot(account)], movements: movements)[0]
        return OwedDueInput(
            balance: balance,
            schedule: schedule,
            startedAt: account.createdAt,
            plans: (account.plans ?? []).compactMap(PlanSnapshot.init),
            movements: movements,
            overrides: try dueOverrides(for: account.id).compactMap(DueOverrideSnapshot.init)
        )
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
            firstDue: firstDue
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
