import SwiftData
import SwiftUI

/// Sheet for paying one month of a bill: an expense in the bill's category from the chosen
/// account, prefilled with what's left. For a bill whose amount varies and isn't set yet, the
/// amount paid becomes this month's amount.
struct PayBillView: View {
    let bill: Bill
    let cycle: CalendarMonth
    let suggestedAmount: Decimal?

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: [SortDescriptor(\Account.sortOrder), SortDescriptor(\Account.createdAt)])
    private var accounts: [Account]
    @State private var fromAccountID: UUID?
    @State private var amount: Decimal?
    @State private var date = Date.now
    @State private var isSaving = false
    @State private var alert: LedgerAlert?

    init(bill: Bill, cycle: CalendarMonth, suggestedAmount: Decimal?) {
        self.bill = bill
        self.cycle = cycle
        self.suggestedAmount = suggestedAmount
        _amount = State(initialValue: suggestedAmount.flatMap { $0 > .zero ? $0 : nil })
        _fromAccountID = State(initialValue: bill.payFrom.flatMap { $0.isArchived ? nil : $0.id })
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    AmountField(suggestedAmount == nil ? "This Month's Amount" : "Amount", amount: $amount, accessibilityLabel: "Amount paid")
                    Picker("Paid From", selection: $fromAccountID) {
                        Text("Choose").tag(UUID?.none)
                        ForEach(accounts.filter { !$0.isArchived }) { account in
                            Label(account.name, systemImage: account.kind.systemImage).tag(UUID?.some(account.id))
                        }
                    }
                    DatePicker("Date", selection: $date, in: ...Date.now)
                } footer: {
                    Text(bill.category.map { "Recorded as spending in \($0.name)." } ?? "Recorded as spending.")
                }
            }
            .navigationTitle("Pay \(bill.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(isSaving || amount == nil || fromAccountID == nil)
                }
            }
            .ledgerAlert($alert)
        }
    }

    private func save() {
        guard !isSaving, let amount, let fromAccountID else { return }
        isSaving = true
        do {
            try LedgerService(context: modelContext).payBill(bill, cycle: cycle, amount: amount, from: fromAccountID, occurredAt: date)
            dismiss()
        } catch {
            isSaving = false
            alert = LedgerAlert(error)
        }
    }
}

/// Sheet for entering one month's amount of a bill, such as this month's electricity bill once it
/// arrives.
struct SetBillAmountView: View {
    let bill: Bill
    let cycle: CalendarMonth

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var amount: Decimal?
    @State private var isSaving = false
    @State private var alert: LedgerAlert?
    @FocusState private var isFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    AmountField("Amount", amount: $amount, accessibilityLabel: "This month's amount")
                        .focused($isFocused)
                } footer: {
                    Text("The amount on this month's bill. Other months stay as they are.")
                }
            }
            .navigationTitle("This Month's Amount")
            .navigationSubtitle(bill.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(isSaving || amount == nil)
                }
            }
            .onAppear { isFocused = true }
            .ledgerAlert($alert)
        }
    }

    private func save() {
        guard !isSaving, let amount else { return }
        isSaving = true
        do {
            try LedgerService(context: modelContext).setAmount(amount, for: bill, cycle: cycle)
            dismiss()
        } catch {
            isSaving = false
            alert = LedgerAlert(error)
        }
    }
}
