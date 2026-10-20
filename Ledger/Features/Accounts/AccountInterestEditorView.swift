import SwiftData
import SwiftUI

/// Sheet for turning an account's daily interest on or off and setting its rates.
struct AccountInterestEditorView: View {
    let account: Account

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @State private var earnsInterest: Bool
    @State private var rateText: String
    @State private var taxText: String
    @State private var isSaving = false
    @State private var alert: LedgerAlert?
    @State private var isConfirmingDiscard = false
    @FocusState private var focusedField: Field?

    private enum Field: Hashable {
        case rate
        case tax
    }

    private let savedEarnsInterest: Bool
    private let savedRateText: String
    private let savedTaxText: String

    init(account: Account) {
        self.account = account
        let terms = account.interestTerms
        let rateText = terms.map { AmountParser.editableText(for: $0.annualRate.percent) } ?? ""
        let taxText = AmountParser.editableText(for: (terms?.taxRate ?? InterestTerms.defaultTaxRate).percent)
        savedEarnsInterest = terms != nil
        savedRateText = rateText
        savedTaxText = taxText
        _earnsInterest = State(initialValue: terms != nil)
        _rateText = State(initialValue: rateText)
        _taxText = State(initialValue: taxText)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Toggle("Earns Interest", isOn: $earnsInterest.animation())
                } footer: {
                    if !earnsInterest {
                        Text(AccountsCopy.interestFooter)
                    }
                }
                if earnsInterest {
                    Section {
                        percentField("Interest Rate", text: $rateText, unit: "% a year", field: .rate)
                        percentField("Withholding Tax", text: $taxText, unit: "%", field: .tax)
                    } footer: {
                        Text(AccountsCopy.interestFooter)
                    }
                }
            }
            .navigationTitle("Interest")
            .navigationSubtitle(account.name)
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
            .onChange(of: earnsInterest) { _, isOn in
                if isOn, rateText.isEmpty {
                    focusedField = .rate
                }
            }
            .interactiveDismissDisabled(hasChanges)
            .ledgerAlert($alert)
        }
    }

    private func percentField(_ title: String, text: Binding<String>, unit: String, field: Field) -> some View {
        LabeledContent(title) {
            HStack(spacing: 4) {
                TextField(title, text: text, prompt: Text("0"))
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .focused($focusedField, equals: field)
                    .onChange(of: text.wrappedValue) { _, newValue in
                        let sanitized = AmountParser.sanitize(
                            newValue,
                            locale: locale,
                            maximumFractionDigits: RateRules.maximumFractionDigits,
                            maximumIntegerDigits: 3
                        )
                        if sanitized != newValue { text.wrappedValue = sanitized }
                    }
                Text(unit)
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var hasChanges: Bool {
        earnsInterest != savedEarnsInterest
            || (earnsInterest && (rateText != savedRateText || taxText != savedTaxText))
    }

    private var canSave: Bool {
        !isSaving && hasChanges && (!earnsInterest || !rateText.isEmpty)
    }

    /// The terms typed, or `nil` when interest is off. Throws when a rate can't be used.
    private func enteredTerms() throws -> InterestTerms? {
        guard earnsInterest else { return nil }
        guard let rate = Rate.parse(rateText, locale: locale) else { throw LedgerError.interestRateOutOfRange }
        guard let tax = Rate.parse(taxText, locale: locale) else { throw LedgerError.taxRateOutOfRange }
        return InterestTerms(annualRate: try RateRules.annualRate(percent: rate), taxRate: try RateRules.taxRate(percent: tax))
    }

    /// Saves through the ledger and closes the sheet only after the save succeeded.
    private func save() {
        guard canSave else { return }
        isSaving = true
        do {
            guard !account.isDeleted, account.modelContext != nil else {
                throw LedgerError.accountNotFound
            }
            try LedgerService(context: modelContext).setInterest(try enteredTerms(), for: account)
            dismiss()
        } catch {
            isSaving = false
            alert = LedgerAlert(error)
        }
    }
}

#if DEBUG
/// Edits the interest of the first account in the preview container.
private struct AccountInterestEditorPreviewHost: View {
    @Query(sort: \Account.sortOrder) private var accounts: [Account]

    var body: some View {
        if let account = accounts.first {
            AccountInterestEditorView(account: account)
        }
    }
}

#Preview {
    AccountInterestEditorPreviewHost()
        .ledgerPreview()
}
#endif
