import SwiftData
import SwiftUI

/// Sheet for creating an account (`account == nil`) or editing one: name, type, and opening
/// balance. An empty opening balance is saved as "not set", never as zero.
struct AccountEditorView: View {
    /// Fields that can be focused when the sheet opens.
    enum Field: Hashable {
        case name
        case openingBalance
    }

    let account: Account?

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var kind: AccountKind
    @State private var openingBalance: Decimal?
    @State private var isSaving = false
    @State private var alert: LedgerAlert?
    @State private var isConfirmingDiscard = false
    @FocusState private var focusedField: Field?

    private let initialFocus: Field?
    private let savedName: String
    private let savedKind: AccountKind
    private let savedOpeningBalance: Decimal?
    private let currency: CurrencyCode

    /// - Parameters:
    ///   - account: The account to edit, or `nil` to create one.
    ///   - initialFocus: The field to focus when the sheet opens. Defaults to the name when
    ///     creating and to nothing when editing.
    init(account: Account?, initialFocus: Field? = nil) {
        self.account = account
        let name = account?.name ?? ""
        let kind = account?.kind ?? .bank
        let openingBalance = account?.openingBalance?.amount
        self.savedName = name
        self.savedKind = kind
        self.savedOpeningBalance = openingBalance
        self.currency = account?.currency ?? .php
        self.initialFocus = initialFocus ?? (account == nil ? .name : nil)
        _name = State(initialValue: name)
        _kind = State(initialValue: kind)
        _openingBalance = State(initialValue: openingBalance)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .submitLabel(.next)
                        .focused($focusedField, equals: .name)
                        .onSubmit { focusedField = .openingBalance }
                    Picker("Type", selection: $kind) {
                        ForEach(AccountKind.moneyKinds) { kind in
                            Label(kind.title, systemImage: kind.systemImage)
                                .tag(kind)
                        }
                    }
                }
                Section {
                    AmountField("Opening Balance", amount: $openingBalance, currency: currency)
                        .focused($focusedField, equals: .openingBalance)
                    if showsClearOpeningBalance {
                        Button("Clear Opening Balance", role: .destructive) {
                            openingBalance = nil
                        }
                    }
                } footer: {
                    Text("The balance before any transaction you record in Ledger. Leave it empty if you don't know it yet — Ledger won't treat it as ₱0. Don't record transactions already included in it.")
                }
                Section {
                    LabeledContent("Currency", value: currencyName)
                }
            }
            .navigationTitle(account == nil ? "New Account" : "Edit Account")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        if hasChanges {
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
                    Button("Save", action: save)
                        .disabled(!canSave)
                }
                ToolbarItemGroup(placement: .keyboard) {
                    Spacer()
                    Button("Done") {
                        focusedField = nil
                    }
                }
            }
            .onChange(of: name) { _, newValue in
                if newValue.count > LedgerService.nameLengthLimit {
                    name = String(newValue.prefix(LedgerService.nameLengthLimit))
                }
            }
            .onAppear {
                if let initialFocus {
                    focusedField = initialFocus
                }
            }
            .interactiveDismissDisabled(hasChanges)
            .ledgerAlert($alert)
        }
    }

    private var canSave: Bool {
        !isSaving && !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private var hasChanges: Bool {
        name != savedName || kind != savedKind || openingBalance != savedOpeningBalance
    }

    private var showsClearOpeningBalance: Bool {
        account != nil && savedOpeningBalance != nil && openingBalance != nil
    }

    private var currencyName: String {
        currency == .php ? "Philippine Peso (PHP)" : currency.rawValue
    }

    /// Saves through the ledger and closes the sheet only after the save succeeded. Save stays
    /// disabled from the tap until the sheet is gone, so a double tap can't save twice.
    private func save() {
        guard canSave else { return }
        isSaving = true
        let ledger = LedgerService(context: modelContext)
        do {
            if let account {
                guard !account.isDeleted, account.modelContext != nil else {
                    throw LedgerError.accountNotFound
                }
                try ledger.updateAccount(account, name: name, kind: kind, openingBalance: openingBalance)
            } else {
                try ledger.createAccount(name: name, kind: kind, openingBalance: openingBalance)
            }
            dismiss()
        } catch {
            isSaving = false
            alert = LedgerAlert(error)
        }
    }
}

#if DEBUG
/// Edits the first account in the preview container.
private struct AccountEditorPreviewHost: View {
    @Query(sort: \Account.sortOrder) private var accounts: [Account]

    var body: some View {
        if let account = accounts.first {
            AccountEditorView(account: account)
        }
    }
}

#Preview("New Account") {
    AccountEditorView(account: nil)
        .ledgerPreview(sampleData: false)
}

#Preview("Edit Account") {
    AccountEditorPreviewHost()
        .ledgerPreview()
}
#endif
