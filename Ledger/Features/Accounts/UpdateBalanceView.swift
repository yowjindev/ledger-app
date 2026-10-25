import SwiftData
import SwiftUI

/// Sheet for bringing an account to its real balance. Shows what will be recorded as the amount
/// is typed: a balance adjustment for the difference, or the opening balance when it isn't set.
struct UpdateBalanceView: View {
    let account: Account

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.moneyFormatter) private var formatter
    @State private var realBalance: Decimal?
    @State private var isSaving = false
    @State private var alert: LedgerAlert?
    @State private var isConfirmingDiscard = false
    @FocusState private var isFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    AmountField(
                        "Real Balance",
                        amount: $realBalance,
                        currency: account.currency,
                        accessibilityLabel: "Real balance of \(account.name)"
                    )
                    .focused($isFocused)
                } footer: {
                    Text(footer)
                }
            }
            .navigationTitle("Update Balance")
            .navigationSubtitle(account.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        if realBalance != nil {
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
            .interactiveDismissDisabled(realBalance != nil)
            .ledgerAlert($alert)
        }
    }

    private var ledger: LedgerService { LedgerService(context: modelContext) }

    /// What will be recorded, or why the amount can't be used.
    private var preview: Result<BalanceCorrection, Error>? {
        guard let realBalance else { return nil }
        return Result { try ledger.balanceCorrection(toReach: realBalance, for: account) }
    }

    private var footer: String {
        switch preview {
        case nil:
            "Enter what \(account.name) holds right now. Ledger records the difference as a balance adjustment, which isn't counted as income or spending."
        case .success(let correction):
            AccountsCopy.correctionPreview(correction, accountName: account.name, formatter: formatter)
        case .failure(let error):
            (error as? LocalizedError)?.errorDescription ?? "Ledger can't use that balance."
        }
    }

    private var canSave: Bool {
        guard !isSaving, case .success(let correction) = preview else { return false }
        return correction != .alreadyMatches
    }

    /// Saves through the ledger and closes the sheet only after the save succeeded. Update stays
    /// disabled from the tap until the sheet is gone, so a double tap can't record twice.
    private func save() {
        guard canSave, let realBalance else { return }
        isSaving = true
        do {
            guard !account.isDeleted, account.modelContext != nil else {
                throw LedgerError.accountNotFound
            }
            try ledger.updateBalance(of: account, to: realBalance)
            dismiss()
        } catch {
            isSaving = false
            alert = LedgerAlert(error)
        }
    }
}

#if DEBUG
/// Updates the first account in the preview container.
private struct UpdateBalancePreviewHost: View {
    @Query(sort: \Account.sortOrder) private var accounts: [Account]

    var body: some View {
        if let account = accounts.first {
            UpdateBalanceView(account: account)
        }
    }
}

#Preview {
    UpdateBalancePreviewHost()
        .ledgerPreview()
}
#endif
