import Foundation
import SwiftData
import SwiftUI

/// Sheet for recording a new transaction or editing an existing one, presented by `RootView` for
/// each `TransactionEditorRequest`. Every write goes through `LedgerService`, and repeated saves
/// within one editor session record a single transaction.
struct TransactionEditorView: View {
    let request: TransactionEditorRequest

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.moneyFormatter) private var formatter
    @AppStorage(AppPreferences.Keys.lastUsedAccountID) private var lastUsedAccountID = ""

    @Query(sort: [SortDescriptor(\Account.sortOrder), SortDescriptor(\Account.createdAt)])
    private var accounts: [Account]
    @Query(sort: [SortDescriptor(\LedgerCategory.sortOrder), SortDescriptor(\LedgerCategory.createdAt)])
    private var categories: [LedgerCategory]

    @State private var phase: Phase
    @State private var form: TransactionEditorForm
    /// The form as first shown, to tell whether anything changed.
    @State private var initialForm: TransactionEditorForm
    /// What the edited transaction already refers to. Its archived accounts and category stay
    /// selectable, and its date stays allowed even if it is later than now.
    @State private var original: OriginalReferences?
    @State private var hasLoaded = false
    /// The category chosen for each type in this session, restored when switching back to it.
    @State private var categoryByKind: [TransactionKind: UUID] = [:]
    /// The transfer destination chosen in this session, restored when switching back to Transfer.
    @State private var lastDestinationID: UUID?
    /// Identifies this editor session's submission, so a repeated save records one transaction.
    @State private var requestID = UUID()
    @State private var isSaving = false
    @State private var duplicateWarning: DuplicateWarning?
    @State private var isConfirmingDiscard = false
    @State private var isConfirmingDeletion = false
    @State private var alert: LedgerAlert?
    @FocusState private var focusedField: Field?

    init(request: TransactionEditorRequest) {
        self.request = request
        let form: TransactionEditorForm
        let phase: Phase
        switch request.mode {
        case .create(let kind, let accountID):
            form = TransactionEditorForm(kind: kind, occurredAt: .now, accountID: accountID)
            phase = .ready
        case .edit:
            form = TransactionEditorForm(kind: .expense, occurredAt: .now)
            phase = .loading
        }
        _form = State(initialValue: form)
        _initialForm = State(initialValue: form)
        _phase = State(initialValue: phase)
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(title)
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbarContent }
        }
        .interactiveDismissDisabled(hasUnsavedChanges || isSaving)
        .ledgerAlert($alert)
        .onAppear(perform: load)
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            ProgressView()
        case .ready:
            editorForm
        case .notFound:
            ContentUnavailableView {
                Label("Transaction Not Found", systemImage: "questionmark.circle")
            } description: {
                Text("It may have been deleted.")
            } actions: {
                Button("Close") { dismiss() }
            }
        case .unsupported:
            ContentUnavailableView {
                Label("Can't Edit This Entry", systemImage: "exclamationmark.triangle")
            } description: {
                Text("It was created by a newer version of Ledger. Update Ledger to edit it.")
            } actions: {
                Button("Close") { dismiss() }
            }
        }
    }

    // MARK: Form

    private var editorForm: some View {
        Form {
            Section {
                Picker("Type", selection: kindSelection) {
                    ForEach(TransactionKind.allCases) { kind in
                        Text(kind.title).tag(kind)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .listRowBackground(Color.clear)
                .listRowInsets(EdgeInsets())
            }

            Section {
                AmountField("Amount", amount: $form.amount)
                    .font(.system(.largeTitle, design: .rounded, weight: .semibold))
                    .focused($focusedField, equals: .amount)
                    .padding(.vertical, 4)
            }

            if let categoryKind = form.kind.requiredCategoryKind {
                categorySection(categoryKind)
            }

            accountSection

            Section {
                DatePicker(
                    "Date",
                    selection: $form.occurredAt,
                    in: ...latestSelectableDate,
                    displayedComponents: [.date, .hourAndMinute]
                )
                TextField("Note", text: $form.note, axis: .vertical)
                    .lineLimit(1...5)
                    .focused($focusedField, equals: .note)
            } footer: {
                if noteCharactersRemaining <= 50 {
                    Text(noteCharactersRemaining == 1 ? "1 character left" : "\(noteCharactersRemaining) characters left")
                }
            }

            if isEditing {
                Section {
                    Button("Delete Transaction", role: .destructive) {
                        focusedField = nil
                        isConfirmingDeletion = true
                    }
                    .frame(maxWidth: .infinity)
                    .disabled(isSaving)
                    .confirmationDialog(
                        "Delete Transaction?",
                        isPresented: $isConfirmingDeletion,
                        titleVisibility: .visible
                    ) {
                        Button("Delete Transaction", role: .destructive, action: deleteTransaction)
                    } message: {
                        Text("This can't be undone.")
                    }
                }
            }
        }
        .scrollDismissesKeyboard(.interactively)
        .onAppear {
            if !isEditing { focusedField = .amount }
        }
        .onChange(of: form.accountID) { _, accountID in
            if form.destinationAccountID == accountID { form.destinationAccountID = nil }
        }
        .onChange(of: form.note) { _, note in
            if note.count > LedgerService.noteLengthLimit {
                form.note = String(note.prefix(LedgerService.noteLengthLimit))
            }
        }
        .alert("Possible Duplicate", isPresented: isShowingDuplicateWarning, presenting: duplicateWarning) { warning in
            Button("Save Anyway") { record(warning.draft) }
            Button("Cancel", role: .cancel) {}
        } message: { warning in
            Text(warning.message)
        }
    }

    private func categorySection(_ categoryKind: CategoryKind) -> some View {
        let options = categoryOptions(for: categoryKind)
        return Section(categoryKind == .expense ? "Category" : "Income Source") {
            if options.isEmpty {
                Text(categoryKind == .expense
                    ? "No expense categories yet. Add one in Settings."
                    : "No income sources yet. Add one in Settings.")
                    .foregroundStyle(.secondary)
            } else {
                CategoryGrid(
                    options: options,
                    selection: $form.categoryID,
                    tint: LedgerTheme.badgeTint(for: form.kind)
                )
            }
        }
    }

    private var accountSection: some View {
        let options = accountOptions
        return Section {
            if options.isEmpty {
                Text("No active accounts. Add one in Accounts.")
                    .foregroundStyle(.secondary)
            } else if form.kind == .transfer {
                accountPicker("From", selection: $form.accountID, options: options)
                let destinations = options.filter { $0.id != form.accountID }
                if destinations.isEmpty {
                    Text("Add another account to make a transfer.")
                        .foregroundStyle(.secondary)
                } else {
                    accountPicker("To", selection: $form.destinationAccountID, options: destinations)
                }
            } else {
                accountPicker(form.kind == .income ? "Deposited To" : "Paid From", selection: $form.accountID, options: options)
            }
        }
    }

    private func accountPicker(_ title: String, selection: Binding<UUID?>, options: [EditorOption]) -> some View {
        Picker(title, selection: selection) {
            if !options.contains(where: { $0.id == selection.wrappedValue }) {
                Text("Choose").tag(selection.wrappedValue)
            }
            ForEach(options) { option in
                Label(option.menuTitle, systemImage: option.symbolName)
                    .tag(UUID?.some(option.id))
            }
        }
        .pickerStyle(.menu)
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel", action: cancel)
                .confirmationDialog(
                    isEditing ? "Discard Changes?" : "Discard This Transaction?",
                    isPresented: $isConfirmingDiscard,
                    titleVisibility: .visible
                ) {
                    Button(isEditing ? "Discard Changes" : "Discard Transaction", role: .destructive) {
                        dismiss()
                    }
                    Button("Keep Editing", role: .cancel) {}
                }
        }
        ToolbarItem(placement: .confirmationAction) {
            Button("Save", role: .confirm, action: save)
                .disabled(!canSave)
        }
        ToolbarItemGroup(placement: .keyboard) {
            Spacer()
            Button("Done") { focusedField = nil }
        }
    }

    // MARK: State

    private var ledger: LedgerService { LedgerService(context: modelContext) }

    private var isEditing: Bool {
        if case .edit = request.mode { true } else { false }
    }

    private var title: String {
        switch request.mode {
        case .create:
            switch form.kind {
            case .expense: "New Expense"
            case .income: "New Income"
            case .transfer: "New Transfer"
            }
        case .edit:
            "Edit Transaction"
        }
    }

    private var hasUnsavedChanges: Bool {
        phase == .ready && form != initialForm
    }

    private var canSave: Bool {
        phase == .ready && !isSaving && form.draft != nil && selectionsAreAvailable
    }

    /// Whether the chosen accounts and category are still offered, for example not archived since
    /// they were picked.
    private var selectionsAreAvailable: Bool {
        let accountIDs = Set(accountOptions.map(\.id))
        guard let accountID = form.accountID, accountIDs.contains(accountID) else { return false }
        if let categoryKind = form.kind.requiredCategoryKind {
            guard let categoryID = form.categoryID else { return false }
            return categoryOptions(for: categoryKind).contains { $0.id == categoryID }
        }
        guard let destinationID = form.destinationAccountID else { return false }
        return destinationID != accountID && accountIDs.contains(destinationID)
    }

    /// Active accounts plus any archived account the edited transaction already uses.
    private var accountOptions: [EditorOption] {
        accounts
            .filter { !$0.isArchived || original?.accountIDs.contains($0.id) == true }
            .map(EditorOption.init)
    }

    /// Active categories of `categoryKind` plus the edited transaction's category if archived.
    private func categoryOptions(for categoryKind: CategoryKind) -> [EditorOption] {
        categories
            .filter { $0.kind == categoryKind && (!$0.isArchived || $0.id == original?.categoryID) }
            .map(EditorOption.init)
    }

    private var latestSelectableDate: Date {
        max(Date.now, original?.occurredAt ?? .distantPast)
    }

    private var noteCharactersRemaining: Int {
        LedgerService.noteLengthLimit - form.note.count
    }

    private var kindSelection: Binding<TransactionKind> {
        Binding(get: { form.kind }, set: { changeKind(to: $0) })
    }

    private var isShowingDuplicateWarning: Binding<Bool> {
        Binding(
            get: { duplicateWarning != nil },
            set: { if !$0 { duplicateWarning = nil } }
        )
    }

    // MARK: Actions

    private func load() {
        guard !hasLoaded else { return }
        hasLoaded = true
        switch request.mode {
        case .create(_, let requestedAccountID):
            form.accountID = preselectedAccountID(requested: requestedAccountID)
            initialForm = form
        case .edit(let transactionID):
            do {
                guard let transaction = try ledger.transaction(id: transactionID) else {
                    phase = .notFound
                    return
                }
                guard let draft = TransactionDraft(transaction) else {
                    phase = .unsupported
                    return
                }
                form = TransactionEditorForm(draft)
                initialForm = form
                original = OriginalReferences(
                    accountIDs: Set([transaction.account?.id, transaction.destinationAccount?.id].compactMap { $0 }),
                    categoryID: transaction.category?.id,
                    occurredAt: transaction.occurredAt
                )
                phase = .ready
            } catch {
                phase = .notFound
                alert = LedgerAlert(error)
            }
        }
    }

    /// The requested account if active, else the account used last if still active, else none.
    private func preselectedAccountID(requested: UUID?) -> UUID? {
        let activeIDs = Set(accounts.filter { !$0.isArchived }.map(\.id))
        if let requested, activeIDs.contains(requested) {
            return requested
        }
        if let lastUsed = UUID(uuidString: lastUsedAccountID), activeIDs.contains(lastUsed) {
            return lastUsed
        }
        return nil
    }

    /// Switches the type, clearing selections the new type can't use and restoring ones made for
    /// it earlier in this session.
    private func changeKind(to newKind: TransactionKind) {
        let oldKind = form.kind
        guard newKind != oldKind else { return }
        if let categoryID = form.categoryID {
            categoryByKind[oldKind] = categoryID
        }
        if let destinationID = form.destinationAccountID {
            lastDestinationID = destinationID
        }
        form.kind = newKind
        form.categoryID = newKind == .transfer ? nil : categoryByKind[newKind]
        form.destinationAccountID = newKind == .transfer && lastDestinationID != form.accountID ? lastDestinationID : nil
    }

    private func save() {
        guard canSave, var draft = form.draft else { return }
        focusedField = nil
        switch request.mode {
        case .create:
            // An untouched date means "now": the entry is dated when it's saved, like entries
            // logged from Shortcuts, rather than when the editor was opened.
            if form.occurredAt == initialForm.occurredAt {
                draft.occurredAt = .now
            }
            if AppPreferences.warnsAboutDuplicates(), let match = try? ledger.recentDuplicate(of: draft) {
                duplicateWarning = DuplicateWarning(draft: draft, message: duplicateMessage(for: match))
            } else {
                record(draft)
            }
        case .edit(let transactionID):
            update(transactionID: transactionID, with: draft)
        }
    }

    /// "You logged ₱250.00 · Food · GCash 30 seconds ago. Save another?"
    private func duplicateMessage(for match: LedgerTransaction) -> String {
        let line = TransactionSummary(match).confirmationLine(formatter: formatter)
        // An entry saved this instant would read "in 0 seconds", so it is shown as a second ago.
        let loggedAt = min(match.createdAt, Date.now.addingTimeInterval(-1))
        // Non-breaking spaces keep "30 seconds ago" together when the message wraps.
        let when = loggedAt.formatted(.relative(presentation: .numeric, unitsStyle: .wide))
            .replacingOccurrences(of: " ", with: "\u{00A0}")
        return "You logged \(line) \(when). Save another?"
    }

    private func record(_ draft: TransactionDraft) {
        guard !isSaving else { return }
        isSaving = true
        do {
            try ledger.record(draft, origin: .app, requestID: requestID)
            if let accountID = draft.accountID {
                lastUsedAccountID = accountID.uuidString
            }
            dismiss()
        } catch {
            isSaving = false
            alert = LedgerAlert(error)
        }
    }

    private func update(transactionID: UUID, with draft: TransactionDraft) {
        guard !isSaving else { return }
        isSaving = true
        do {
            guard let transaction = try ledger.transaction(id: transactionID) else {
                throw LedgerError.transactionNotFound
            }
            try ledger.update(transaction, with: draft)
            dismiss()
        } catch {
            isSaving = false
            alert = LedgerAlert(error)
        }
    }

    private func deleteTransaction() {
        guard case .edit(let transactionID) = request.mode, !isSaving else { return }
        isSaving = true
        do {
            guard let transaction = try ledger.transaction(id: transactionID) else {
                throw LedgerError.transactionNotFound
            }
            try ledger.delete(transaction)
            dismiss()
        } catch {
            isSaving = false
            alert = LedgerAlert(error)
        }
    }

    private func cancel() {
        focusedField = nil
        if hasUnsavedChanges {
            isConfirmingDiscard = true
        } else {
            dismiss()
        }
    }
}

private extension TransactionEditorView {
    enum Phase {
        case loading
        case ready
        /// The transaction to edit no longer exists.
        case notFound
        /// The transaction's type is unknown to this app version.
        case unsupported
    }

    enum Field: Hashable {
        case amount
        case note
    }

    /// References of the transaction being edited.
    struct OriginalReferences {
        let accountIDs: Set<UUID>
        let categoryID: UUID?
        let occurredAt: Date
    }

    /// An identical entry was saved moments ago; asks before recording another.
    struct DuplicateWarning: Identifiable {
        let id = UUID()
        let draft: TransactionDraft
        let message: String
    }
}

#Preview("New Expense") {
    TransactionEditorView(request: .newTransaction(.expense))
        .ledgerPreview()
}

#Preview("New Transfer") {
    TransactionEditorView(request: .newTransaction(.transfer))
        .ledgerPreview()
}

#if DEBUG
#Preview("Edit Transaction") {
    NewestTransactionPreview { id in
        TransactionEditorView(request: TransactionEditorRequest(mode: .edit(transactionID: id)))
    }
    .ledgerPreview()
}
#endif
