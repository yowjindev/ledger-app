import SwiftData
import SwiftUI

/// What a Live Activity button opened: paying a due, or moving it, prefilled from its current due.
struct ReminderRouteSheet: View {
    let route: ReminderRoute

    @Environment(\.modelContext) private var modelContext

    var body: some View {
        let ledger = LedgerService(context: modelContext)
        switch route {
        case .pay(.account(let id)):
            let status = (try? ledger.account(id: id)).flatMap { $0 }.flatMap { try? ledger.dueStatus(for: $0) }
            PayDueView(accountID: id, suggestedAmount: status?.left?.amount)
        case .pay(.bill(let id)):
            if let bill = try? ledger.bill(id: id), let status = try? ledger.dueStatus(for: bill) {
                PayBillView(bill: bill, cycle: status.cycle, suggestedAmount: status.left?.amount)
            } else {
                notFound
            }
        case .move(let owner):
            if let (status, schedule) = due(of: owner, ledger: ledger) {
                MoveDueView(owner: owner, cycle: status.cycle, schedule: schedule, currentDue: status.dueDate)
            } else {
                notFound
            }
        }
    }

    private var notFound: some View {
        ContentUnavailableView("Nothing Due", systemImage: "checkmark.circle", description: Text("It may have been paid or removed."))
    }

    private func due(of owner: DueOwner, ledger: LedgerService) -> (DueStatus, DueSchedule)? {
        switch owner {
        case .account(let id):
            guard
                let account = try? ledger.account(id: id),
                let schedule = account.dueSchedule,
                let status = try? ledger.dueStatus(for: account)
            else { return nil }
            return (status, schedule)
        case .bill(let id):
            guard let bill = try? ledger.bill(id: id), let status = try? ledger.dueStatus(for: bill) else { return nil }
            return (status, bill.schedule)
        }
    }
}
