import SwiftData
import SwiftUI

/// Sheet for adding a regular monthly bill, such as rent or electricity, or editing one: its
/// name, category, due day, amount (fixed or varying), and the account it's usually paid from.
struct BillEditorView: View {
    private enum AmountKind: Hashable {
        case fixed
        case varies
    }

    let bill: Bill?

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Query(sort: [SortDescriptor(\LedgerCategory.sortOrder), SortDescriptor(\LedgerCategory.createdAt)])
    private var categories: [LedgerCategory]
    @Query(sort: [SortDescriptor(\Account.sortOrder), SortDescriptor(\Account.createdAt)])
    private var accounts: [Account]
    @State private var name: String
    @State private var categoryID: UUID?
    @State private var dueDay: Int
    @State private var amountKind: AmountKind
    @State private var amount: Decimal?
    @State private var arrivesDay: Int?
    @State private var payFromID: UUID?
    @State private var isAlreadyPaid = false
    @State private var isSaving = false
    @State private var alert: LedgerAlert?
    @State private var isConfirmingDiscard = false

    private let saved: BillTerms?

    init(bill: Bill? = nil) {
        self.bill = bill
        _name = State(initialValue: bill?.name ?? "")
        _categoryID = State(initialValue: bill?.category?.id)
        _dueDay = State(initialValue: bill?.dueDay ?? 25)
        _amountKind = State(initialValue: bill != nil && bill?.amountMinor == nil ? .varies : .fixed)
        _amount = State(initialValue: bill?.amount?.amount)
        _arrivesDay = State(initialValue: bill?.arrivesDay)
        _payFromID = State(initialValue: bill?.payFrom?.id)
        saved = bill.flatMap { bill in
            bill.category.map {
                BillTerms(
                    name: bill.name, categoryID: $0.id, dueDay: bill.dueDay, amount: bill.amount?.amount,
                    arrivesDay: bill.arrivesDay, payFromAccountID: bill.payFrom?.id
                )
            }
        }
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $name)
                        .textInputAutocapitalization(.words)
                    Picker("Category", selection: $categoryID) {
                        Text("Choose").tag(UUID?.none)
                        ForEach(categoryOptions) { category in
                            Label(category.name, systemImage: category.symbolName).tag(UUID?.some(category.id))
                        }
                    }
                    Picker("Due", selection: $dueDay) {
                        ForEach(LedgerService.dayRange, id: \.self) { day in
                            Text(BillsCopy.dayTitle(day)).tag(day)
                        }
                    }
                }
                Section {
                    Picker("Amount", selection: $amountKind.animation()) {
                        Text("Same Every Month").tag(AmountKind.fixed)
                        Text("Varies").tag(AmountKind.varies)
                    }
                    .pickerStyle(.segmented)
                    if amountKind == .fixed {
                        AmountField("Monthly Amount", amount: $amount)
                    } else {
                        Picker("Usually Arrives", selection: $arrivesDay) {
                            Text("Not Sure").tag(Int?.none)
                            ForEach(LedgerService.dayRange, id: \.self) { day in
                                Text(BillsCopy.dayTitle(day)).tag(Int?.some(day))
                            }
                        }
                    }
                } footer: {
                    Text(amountKind == .fixed
                        ? "Rent, internet, and subscriptions usually cost the same each month."
                        : "Electricity and water change each month. Enter the amount when the bill arrives.")
                }
                if bill == nil {
                    Section {
                        Toggle("Already Paid This Month", isOn: $isAlreadyPaid)
                    } footer: {
                        Text("Turn this on if you've already paid and logged this month's bill, so it isn't due twice.")
                    }
                }
                Section {
                    Picker("Pay From", selection: $payFromID) {
                        Text("Choose Each Time").tag(UUID?.none)
                        ForEach(accounts.filter { !$0.isArchived || $0.id == bill?.payFrom?.id }) { account in
                            Label(account.name, systemImage: account.kind.systemImage).tag(UUID?.some(account.id))
                        }
                    }
                }
            }
            .navigationTitle(bill == nil ? "New Bill" : "Edit Bill")
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
            }
            .onChange(of: name) { _, newValue in
                if newValue.count > LedgerService.nameLengthLimit {
                    name = String(newValue.prefix(LedgerService.nameLengthLimit))
                }
            }
            .interactiveDismissDisabled(hasChanges)
            .ledgerAlert($alert)
        }
    }

    /// Active expense categories, plus the bill's own category if it was archived since.
    private var categoryOptions: [LedgerCategory] {
        categories.filter { $0.kind == .expense && (!$0.isArchived || $0.id == bill?.category?.id) }
    }

    private var terms: BillTerms? {
        guard let categoryID else { return nil }
        return BillTerms(
            name: name,
            categoryID: categoryID,
            dueDay: dueDay,
            amount: amountKind == .fixed ? amount : nil,
            arrivesDay: amountKind == .varies ? arrivesDay : nil,
            payFromAccountID: payFromID
        )
    }

    private var hasChanges: Bool {
        guard let saved else { return !name.isEmpty || categoryID != nil || amount != nil }
        return terms != saved
    }

    private var canSave: Bool {
        guard !isSaving, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, terms != nil else { return false }
        return amountKind == .varies || amount != nil
    }

    private func save() {
        guard canSave, let terms else { return }
        isSaving = true
        let ledger = LedgerService(context: modelContext)
        do {
            if let bill {
                try ledger.updateBill(bill, with: terms)
            } else {
                try ledger.createBill(terms, alreadyPaid: isAlreadyPaid)
            }
            dismiss()
        } catch {
            isSaving = false
            alert = LedgerAlert(error)
        }
    }
}

#Preview {
    BillEditorView()
        .ledgerPreview()
}
