import SwiftData
import SwiftUI

/// Sheet for adding a split that's already under way to a pay later account, such as 3 of 6
/// payments made. Records no entries: what the account owes already includes it.
struct ExistingPlanView: View {
    let account: Account

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.calendar) private var calendar
    @State private var input = PlanPaymentsInput(months: 3)
    @State private var nextDue: CalendarDay?
    @State private var isSaving = false
    @State private var alert: LedgerAlert?

    var body: some View {
        let dueDates = upcomingDueDates
        NavigationStack {
            Form {
                Section {
                    TextField("What It's For", text: $input.title)
                        .textInputAutocapitalization(.sentences)
                }
                Section {
                    PlanPaymentRows(input: $input, months: LedgerService.splitMonths)
                    Picker("Next Payment", selection: $nextDue) {
                        ForEach(dueDates, id: \.self) { day in
                            Text(DueStatusCopy.shortDate(day, calendar: calendar)).tag(CalendarDay?.some(day))
                        }
                    }
                } footer: {
                    Text("What \(account.name) owes already includes this split, so nothing is added to it. Ledger uses the plan to work out each due.")
                }
            }
            .navigationTitle("Add a Split")
            .navigationSubtitle(account.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(isSaving || !input.isComplete || nextDue == nil)
                }
            }
            .onAppear {
                if nextDue == nil { nextDue = dueDates.first }
            }
            .ledgerAlert($alert)
        }
    }

    /// The account's next twelve due dates.
    private var upcomingDueDates: [CalendarDay] {
        guard let schedule = account.dueSchedule else { return [] }
        let first = schedule.cycle(dueOnOrAfter: CalendarDay(containing: .now, calendar: calendar))
        return (0..<12).map { schedule.dueDate(in: first.adding(months: $0)) }
    }

    private func save() {
        guard !isSaving, let nextDue, let terms = input.terms(nextDue: nextDue) else { return }
        isSaving = true
        do {
            try LedgerService(context: modelContext).addExistingPlan(terms, to: account)
            dismiss()
        } catch {
            isSaving = false
            alert = LedgerAlert(error)
        }
    }
}
