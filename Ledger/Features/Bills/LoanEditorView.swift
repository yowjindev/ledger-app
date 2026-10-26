import SwiftData
import SwiftUI

/// Sheet for adding a loan for an item bought in a store, such as a phone paid monthly. A loan
/// already under way starts out owing its remaining payments; a new one records the item as an
/// expense and the extra the payments cost as fees.
struct LoanEditorView: View {
    private enum Stage: Hashable {
        case alreadyPaying
        case new
    }

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.moneyFormatter) private var formatter
    @Query(sort: [SortDescriptor(\LedgerCategory.sortOrder), SortDescriptor(\LedgerCategory.createdAt)])
    private var categories: [LedgerCategory]
    @State private var name = ""
    @State private var stage = Stage.alreadyPaying
    @State private var input = PlanPaymentsInput()
    @State private var nextDue = Date.now
    @State private var price: Decimal?
    @State private var categoryID: UUID?
    @State private var boughtOn = Date.now
    @State private var isSaving = false
    @State private var alert: LedgerAlert?
    @State private var isConfirmingDiscard = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Loan Name", text: $name)
                        .textInputAutocapitalization(.words)
                    TextField("What It's For", text: $input.title)
                        .textInputAutocapitalization(.sentences)
                    Picker("Loan", selection: $stage.animation()) {
                        Text("Already Paying").tag(Stage.alreadyPaying)
                        Text("New Loan").tag(Stage.new)
                    }
                    .pickerStyle(.segmented)
                }
                Section {
                    PlanPaymentRows(input: $input, months: LedgerService.loanMonths, asksPaidSoFar: stage == .alreadyPaying)
                    DatePicker(stage == .new ? "First Payment Due" : "Next Payment Due", selection: $nextDue, displayedComponents: .date)
                } header: {
                    Text("Payments")
                } footer: {
                    Text("Payments are due on this day every month.")
                }
                if stage == .new {
                    purchaseSection
                }
            }
            .navigationTitle("New Loan")
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
            .onChange(of: stage) { _, stage in
                if stage == .new { input.paidAtStart = 0 }
            }
            .interactiveDismissDisabled(hasChanges)
            .ledgerAlert($alert)
        }
    }

    private var purchaseSection: some View {
        Section {
            AmountField("Item Price", amount: $price)
            Picker("Category", selection: $categoryID) {
                Text("Choose").tag(UUID?.none)
                ForEach(categories.filter { $0.kind == .expense && !$0.isArchived }) { category in
                    Label(category.name, systemImage: category.symbolName).tag(UUID?.some(category.id))
                }
            }
            DatePicker("Bought On", selection: $boughtOn, in: ...Date.now, displayedComponents: .date)
        } header: {
            Text("The Item")
        } footer: {
            Text(purchaseFooter)
        }
    }

    private var purchaseFooter: String {
        guard let price, let monthly = input.monthly else {
            return "The price counts as spending in its category. What the payments cost over it is recorded as fees and interest."
        }
        let last = input.usesDifferentLast ? (input.last ?? monthly) : monthly
        let total = monthly * Decimal(input.months - 1) + last
        let extra = total - price
        guard extra > .zero else {
            return "The price counts as spending in its category."
        }
        return "You'll pay \(formatter.string(Money(total))) in all: \(formatter.string(Money(extra))) more than the price, recorded as fees and interest."
    }

    private var hasChanges: Bool {
        !name.isEmpty || input != PlanPaymentsInput() || price != nil || categoryID != nil
    }

    private var canSave: Bool {
        guard !isSaving, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, input.isComplete else { return false }
        return stage == .alreadyPaying || (price != nil && categoryID != nil)
    }

    private func save() {
        guard canSave else { return }
        let calendar = Calendar.current
        guard let terms = input.terms(nextDue: CalendarDay(containing: nextDue, calendar: calendar)) else { return }
        var purchase: LoanPurchase?
        if stage == .new {
            guard let price, let categoryID else { return }
            purchase = LoanPurchase(price: price, categoryID: categoryID, occurredAt: boughtOn)
        }
        isSaving = true
        do {
            try LedgerService(context: modelContext).createLoan(name: name, terms: terms, purchase: purchase)
            dismiss()
        } catch {
            isSaving = false
            alert = LedgerAlert(error)
        }
    }
}

#Preview {
    LoanEditorView()
        .ledgerPreview()
}
