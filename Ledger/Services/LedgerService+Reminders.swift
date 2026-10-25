import Foundation
import SwiftData
import os

extension LedgerService {
    /// Unpaid dues as reminder items, in Coming Up order.
    func reminderItems() throws -> [ReminderItem] {
        let accounts = Dictionary(try accounts().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let bills = Dictionary(try bills().map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        return try comingUp().compactMap { status -> ReminderItem? in
            guard !status.isPaid else { return nil }
            switch status.owner {
            case .account(let id):
                guard let account = accounts[id] else { return nil }
                return ReminderItem(
                    status: status, name: account.name, symbolName: account.kind.systemImage,
                    isStrict: account.strictReminder, arrivesDay: nil
                )
            case .bill(let id):
                guard let bill = bills[id] else { return nil }
                return ReminderItem(
                    status: status,
                    name: bill.name,
                    symbolName: bill.category?.symbolName ?? "doc.text",
                    isStrict: bill.strictReminder,
                    arrivesDay: status.left == nil ? arrivalDay(of: bill, for: status) : nil
                )
            }
        }
    }

    /// Turns strict reminders on or off for one owed account or bill.
    func setStrictReminder(_ isOn: Bool, for owner: DueOwner) throws {
        switch owner {
        case .account(let id):
            guard let account = try account(id: id) else { throw LedgerError.accountNotFound }
            account.strictReminder = isOn
        case .bill(let id):
            guard let bill = try bill(id: id) else { throw LedgerError.billNotFound }
            bill.strictReminder = isOn
        }
        try commit()
        Log.ledger.info("Changed a strict reminder setting")
    }

    /// The day a varying bill usually arrives before its due date in `status`'s cycle.
    private func arrivalDay(of bill: Bill, for status: DueStatus) -> CalendarDay? {
        guard let arrivesDay = bill.arrivesDay else { return nil }
        let sameMonth = status.cycle.day(arrivesDay)
        return sameMonth < status.originalDueDate ? sameMonth : status.cycle.adding(months: -1).day(arrivesDay)
    }
}
