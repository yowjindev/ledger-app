import SwiftData
import SwiftUI

/// Sheet for adding a credit card or pay later account, or editing one: its name, statement and
/// due days, limit, and cashback or monthly fee. When adding, it also asks what's owed now and what's still
/// due on a statement that has already closed.
struct OwedAccountEditorView: View {
    private enum Field: Hashable {
        case name
        case owed
        case stillDue
        case limit
        case cashback
        case splitFee
    }

    let kind: AccountKind
    let account: Account?

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @Environment(\.calendar) private var calendar
    @State private var name: String
    @State private var statementDay: Int
    @State private var dueDay: Int
    @State private var limit: Decimal?
    @State private var cashbackText: String
    @State private var splitFeeText: String
    @State private var feesUseLimit: Bool
    @State private var owedNow: Decimal?
    @State private var stillDue: Decimal?
    @State private var isSaving = false
    @State private var alert: LedgerAlert?
    @State private var isConfirmingDiscard = false
    @FocusState private var focusedField: Field?

    private let saved: Snapshot

    /// The editable values, to tell whether anything changed.
    private struct Snapshot: Equatable {
        var name: String
        var statementDay: Int
        var dueDay: Int
        var limit: Decimal?
        var cashbackText: String
        var splitFeeText: String
        var feesUseLimit: Bool
        var owedNow: Decimal?
        var stillDue: Decimal?
    }

    /// - Parameters:
    ///   - kind: `.creditCard` or `.payLater` when adding; when editing, the account's own kind,
    ///     including `.loan`, whose editor shows only its name and due day.
    ///   - account: The account to edit, or `nil` to add one.
    init(kind: AccountKind, account: Account? = nil) {
        self.kind = account?.kind ?? kind
        self.account = account
        let snapshot = Snapshot(
            name: account?.name ?? "",
            statementDay: account?.statementDay ?? (kind == .payLater ? 31 : 5),
            dueDay: account?.dueDay ?? (kind == .payLater ? 5 : 25),
            limit: account?.creditLimit?.amount,
            cashbackText: account?.cashbackRate?.editableText() ?? "",
            splitFeeText: account?.splitFeeRate?.editableText() ?? "",
            feesUseLimit: account?.feesUseLimit ?? false,
            owedNow: nil,
            stillDue: nil
        )
        saved = snapshot
        _name = State(initialValue: snapshot.name)
        _statementDay = State(initialValue: snapshot.statementDay)
        _dueDay = State(initialValue: snapshot.dueDay)
        _limit = State(initialValue: snapshot.limit)
        _cashbackText = State(initialValue: snapshot.cashbackText)
        _splitFeeText = State(initialValue: snapshot.splitFeeText)
        _feesUseLimit = State(initialValue: snapshot.feesUseLimit)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .textInputAutocapitalization(.words)
                        .autocorrectionDisabled()
                        .focused($focusedField, equals: .name)
                }
                Section {
                    if kind != .loan {
                        dayPicker("Statement Closes", selection: $statementDay)
                    }
                    dayPicker("Payment Due", selection: $dueDay)
                } header: {
                    Text("Billing")
                } footer: {
                    Text(kind == .loan
                        ? "Payments are due on this day every month."
                        : "Purchases up to the statement day are due on the next due day.")
                }
                if kind != .loan {
                    Section {
                        AmountField(BillsCopy.limitTitle(for: kind), amount: $limit)
                            .focused($focusedField, equals: .limit)
                        if kind == .creditCard {
                            percentField("Cashback", text: $cashbackText, unit: "% back", field: .cashback)
                        }
                        if kind == .payLater {
                            percentField("Monthly Fee", text: $splitFeeText, unit: "% a month", field: .splitFee)
                            Toggle("Fees Use the Limit", isOn: $feesUseLimit)
                        }
                    } footer: {
                        if kind == .creditCard {
                            Text("Cashback is added automatically to every purchase you log on this card, rounded down to the centavo.")
                        } else if kind == .payLater {
                            Text("The monthly fee fills in each payment when you split a purchase: the price split evenly, plus this share of the price each month. Turn on Fees Use the Limit if this service's available limit goes down by its fees too.")
                        }
                    }
                }
                if account == nil {
                    owedSection
                }
            }
            .navigationTitle(account == nil ? "New \(BillsCopy.kindTitle(kind))" : "Edit \(BillsCopy.kindTitle(kind))")
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
                    Button("Done") { focusedField = nil }
                }
            }
            .onChange(of: name) { _, newValue in
                if newValue.count > LedgerService.nameLengthLimit {
                    name = String(newValue.prefix(LedgerService.nameLengthLimit))
                }
            }
            .onAppear {
                if account == nil { focusedField = .name }
            }
            .interactiveDismissDisabled(hasChanges)
            .ledgerAlert($alert)
        }
    }

    // MARK: Sections

    @ViewBuilder
    private var owedSection: some View {
        let waitingDue = ledger.awaitingDue(for: DueSchedule(statementDay: statementDay, dueDay: dueDay))
        Section {
            AmountField("Total You Owe Now", amount: $owedNow)
                .focused($focusedField, equals: .owed)
            if let waitingDue {
                AmountField(
                    "Still Due on \(DueStatusCopy.shortDate(waitingDue, calendar: calendar))",
                    amount: $stillDue
                )
                .focused($focusedField, equals: .stillDue)
            }
        } header: {
            Text("What You Owe")
        } footer: {
            Text(waitingDue == nil ? BillsCopy.owedFooter : "\(BillsCopy.owedFooter) \(BillsCopy.stillDueFooter)")
        }
    }

    private func dayPicker(_ title: String, selection: Binding<Int>) -> some View {
        Picker(title, selection: selection) {
            ForEach(LedgerService.dayRange, id: \.self) { day in
                Text(BillsCopy.dayTitle(day)).tag(day)
            }
        }
    }

    /// A percentage typed on the decimal pad, with its unit after it, such as "1 % back".
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

    // MARK: Saving

    private var ledger: LedgerService { LedgerService(context: modelContext) }

    private var current: Snapshot {
        Snapshot(
            name: name, statementDay: statementDay, dueDay: dueDay, limit: limit,
            cashbackText: cashbackText, splitFeeText: splitFeeText, feesUseLimit: feesUseLimit, owedNow: owedNow, stillDue: stillDue
        )
    }

    private var hasChanges: Bool { current != saved }

    private var canSave: Bool {
        guard !isSaving, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard account == nil else { return true }
        let isStatementWaiting = ledger.awaitingDue(for: DueSchedule(statementDay: statementDay, dueDay: dueDay)) != nil
        return owedNow != nil && (!isStatementWaiting || stillDue != nil)
    }

    private var terms: OwedTerms {
        let cashback = cashbackText.trimmingCharacters(in: .whitespaces).isEmpty ? nil : Rate.parse(cashbackText, locale: locale)
        let splitFee = splitFeeText.trimmingCharacters(in: .whitespaces).isEmpty ? nil : Rate.parse(splitFeeText, locale: locale)
        return OwedTerms(
            statementDay: kind == .loan ? nil : statementDay,
            dueDay: dueDay,
            creditLimit: limit,
            cashbackPercent: cashback,
            splitFeePercent: splitFee,
            feesUseLimit: feesUseLimit
        )
    }

    /// Saves through the ledger and closes the sheet only after the save succeeded.
    private func save() {
        guard canSave else { return }
        isSaving = true
        do {
            if let account {
                guard !account.isDeleted, account.modelContext != nil else { throw LedgerError.accountNotFound }
                try ledger.updateOwedAccount(account, name: name, terms: terms)
            } else if let owedNow {
                let waiting = ledger.awaitingDue(for: DueSchedule(statementDay: statementDay, dueDay: dueDay))
                try ledger.createOwedAccount(
                    name: name,
                    kind: kind,
                    terms: terms,
                    owedNow: owedNow,
                    stillDue: waiting == nil ? nil : stillDue
                )
            }
            dismiss()
        } catch {
            isSaving = false
            alert = LedgerAlert(error)
        }
    }
}

#Preview("New Credit Card") {
    OwedAccountEditorView(kind: .creditCard)
        .ledgerPreview(sampleData: false)
}

#Preview("New Pay Later") {
    OwedAccountEditorView(kind: .payLater)
        .ledgerPreview(sampleData: false)
}
