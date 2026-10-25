import SwiftData
import SwiftUI

/// Sheet for matching what a credit card, pay later account, or loan owes to the bank's figure.
/// Shows what will be recorded as the amount is typed.
struct UpdateOwedView: View {
    let account: Account

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.moneyFormatter) private var formatter
    @State private var owed: Decimal?
    @State private var isSaving = false
    @State private var alert: LedgerAlert?
    @State private var isConfirmingDiscard = false
    @FocusState private var isFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    AmountField(
                        "What You Owe",
                        amount: $owed,
                        currency: account.currency,
                        accessibilityLabel: "What you owe on \(account.name)"
                    )
                    .focused($isFocused)
                } footer: {
                    Text(footer)
                }
            }
            .navigationTitle("Update What You Owe")
            .navigationSubtitle(account.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        if owed != nil {
                            isConfirmingDiscard = true
                        } else {
                            dismiss()
                        }
                    }
                    .confirmationDialog("Discard Changes?", isPresented: $isConfirmingDiscard, titleVisibility: .visible) {
                        Button("Discard Changes", role: .destructive) { dismiss() }
                        Button("Keep Editing", role: .cancel) {}
                    }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Update", action: save)
                        .disabled(!canSave)
                }
            }
            .onAppear { isFocused = true }
            .interactiveDismissDisabled(owed != nil)
            .ledgerAlert($alert)
        }
    }

    private var ledger: LedgerService { LedgerService(context: modelContext) }

    private var preview: Result<BalanceCorrection, Error>? {
        guard let owed else { return nil }
        return Result { try ledger.owedCorrection(toOwe: owed, for: account) }
    }

    private var footer: String {
        switch preview {
        case nil:
            "Enter the total \(account.name) owes now, as your app or statement shows it. Ledger records the difference as a balance adjustment, which isn't counted as income or spending."
        case .success(let correction):
            BillsCopy.owedCorrectionPreview(correction, accountName: account.name, formatter: formatter)
        case .failure(let error):
            (error as? LocalizedError)?.errorDescription ?? "Ledger can't use that amount."
        }
    }

    private var canSave: Bool {
        guard !isSaving, case .success(let correction) = preview else { return false }
        return correction != .alreadyMatches
    }

    private func save() {
        guard canSave, let owed else { return }
        isSaving = true
        do {
            guard !account.isDeleted, account.modelContext != nil else { throw LedgerError.accountNotFound }
            try ledger.updateOwed(of: account, to: owed)
            dismiss()
        } catch {
            isSaving = false
            alert = LedgerAlert(error)
        }
    }
}
