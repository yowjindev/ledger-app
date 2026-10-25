import SwiftData
import SwiftUI

/// Sheet for moving one month's due date of a bill or owed account, such as paying rent on the
/// 30th instead of the 25th this month. Every other month keeps its usual date.
struct MoveDueView: View {
    let owner: DueOwner
    let cycle: CalendarMonth
    let schedule: DueSchedule
    let currentDue: CalendarDay

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.calendar) private var calendar
    @State private var date: Date?
    @State private var isSaving = false
    @State private var alert: LedgerAlert?

    var body: some View {
        let usual = schedule.dueDate(in: cycle)
        let range = allowedRange
        NavigationStack {
            Form {
                Section {
                    DatePicker(
                        "New Due Date",
                        selection: Binding(get: { date ?? currentDue.start(in: calendar) }, set: { date = $0 }),
                        in: range,
                        displayedComponents: .date
                    )
                    .datePickerStyle(.graphical)
                } footer: {
                    Text("Only this due moves. Next month is due on \(DueStatusCopy.shortDate(schedule.dueDate(in: cycle.adding(months: 1)), calendar: calendar)) as usual.")
                }
                if currentDue != usual {
                    Section {
                        Button("Use the Usual Date, \(DueStatusCopy.shortDate(usual, calendar: calendar))") {
                            move(to: usual)
                        }
                        .disabled(usual < today)
                    }
                }
            }
            .navigationTitle("Move This Due")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Move") {
                        if let date { move(to: CalendarDay(containing: date, calendar: calendar)) }
                    }
                    .disabled(isSaving || date == nil)
                }
            }
            .ledgerAlert($alert)
        }
    }

    private var today: CalendarDay { CalendarDay(containing: .now, calendar: calendar) }

    /// From today up to the day before the next month's due date.
    private var allowedRange: ClosedRange<Date> {
        let start = today.start(in: calendar)
        let lastDay = schedule.dueDate(in: cycle.adding(months: 1)).adding(days: -1, calendar: calendar)
        return start...max(start, lastDay.start(in: calendar))
    }

    private func move(to day: CalendarDay) {
        guard !isSaving else { return }
        isSaving = true
        do {
            try LedgerService(context: modelContext).moveDue(of: owner, cycle: cycle, to: day)
            dismiss()
        } catch {
            isSaving = false
            alert = LedgerAlert(error)
        }
    }
}
