import SwiftData
import SwiftUI

/// Sheet for paying a credit card, pay later account, or loan: a transfer from one of the
/// user's money accounts, prefilled with what's left on the current due.
struct PayDueView: View {
    let accountID: UUID
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

    init(accountID: UUID, suggestedAmount: Decimal?) {
        self.accountID = accountID
        self.suggestedAmount = suggestedAmount
        _amount = State(initialValue: suggestedAmount.flatMap { $0 > .zero ? $0 : nil })
    }

    var body: some View {
        let target = accounts.first { $0.id == accountID }
        let sources = accounts.filter { !$0.isArchived && !$0.kind.isOwed }
        NavigationStack {
            Form {
                Section {
                    AmountField("Amount", amount: $amount, accessibilityLabel: "Payment amount")
                    Picker("From", selection: $fromAccountID) {
                        Text("Choose").tag(UUID?.none)
                        ForEach(sources) { account in
                            Text(account.name).tag(UUID?.some(account.id))
                        }
                    }
                    DatePicker("Date", selection: $date, in: ...Date.now)
                } footer: {
                    Text(BillsCopy.paymentFooter)
                }
            }
            .navigationTitle("Pay")
            .navigationSubtitle(target?.name ?? "")
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
            .onAppear {
                if fromAccountID == nil {
                    fromAccountID = sources.first?.id
                }
            }
            .ledgerAlert($alert)
        }
    }

    /// Records the transfer and closes the sheet only after the save succeeded.
    private func save() {
        guard !isSaving, let amount, let fromAccountID else { return }
        isSaving = true
        do {
            try LedgerService(context: modelContext).record(
                .transfer(amount: amount, fromAccountID: fromAccountID, toAccountID: accountID, occurredAt: date)
            )
            dismiss()
        } catch {
            isSaving = false
            alert = LedgerAlert(error)
        }
    }
}
