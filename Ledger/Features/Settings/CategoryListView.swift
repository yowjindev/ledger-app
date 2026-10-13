import SwiftData
import SwiftUI

/// Expense categories or income sources: edit, reorder, archive, and delete unused ones.
/// The order here is the order shown when logging and in Shortcuts.
struct CategoryListView: View {
    let kind: CategoryKind

    var body: some View {
        CategoryListContent(kind: kind)
    }
}

/// The list behind `CategoryListView`, which owns the filtered queries.
///
/// `CategoryListView` stores only `kind`, so when SwiftUI rebuilds a navigation destination with
/// the same kind it skips that body and these queries aren't recreated. A view that creates a
/// filtered `@Query` in its initializer and is pushed with `navigationDestination(isPresented:)`
/// is otherwise rebuilt endlessly, freezing the app.
private struct CategoryListContent: View {
    let kind: CategoryKind

    @Environment(\.modelContext) private var modelContext
    @Environment(\.editMode) private var editMode
    @Query private var categories: [LedgerCategory]
    @Query private var transactions: [LedgerTransaction]
    @State private var editor: CategoryEditorRoute?
    @State private var pendingDeletion: CategoryRowReference?
    @State private var archiveSuggestion: CategoryRowReference?
    @State private var alert: LedgerAlert?
    @ScaledMetric(relativeTo: .body) private var badgeSize: CGFloat = 36

    init(kind: CategoryKind) {
        self.kind = kind
        let kindRaw = kind.rawValue
        _categories = Query(
            filter: #Predicate<LedgerCategory> { $0.kindRaw == kindRaw },
            sort: [SortDescriptor(\LedgerCategory.sortOrder), SortDescriptor(\LedgerCategory.createdAt)]
        )
    }

    var body: some View {
        let usage = usageCounts
        let active = activeCategories
        let archived = archivedCategories
        List {
            if !categories.isEmpty {
                Section {
                    if active.isEmpty {
                        Text(noActiveMessage)
                            .foregroundStyle(.secondary)
                    }
                    ForEach(active) { category in
                        row(for: category, usage: usage[category.id, default: 0])
                    }
                    .onMove(perform: move)
                } footer: {
                    Text(footerText)
                }
            }
            if !archived.isEmpty {
                Section("Archived") {
                    ForEach(archived) { category in
                        row(for: category, usage: usage[category.id, default: 0])
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .overlay {
            if categories.isEmpty {
                emptyState
            }
        }
        .navigationTitle(kind.pluralTitle)
        .toolbar {
            // Stays while editing so the list can always leave edit mode.
            if active.count > 1 || editMode?.wrappedValue.isEditing == true {
                ToolbarItem(placement: .topBarTrailing) {
                    EditButton()
                }
            }
            ToolbarItem(placement: .topBarTrailing) {
                Button("Add \(kind.title)", systemImage: "plus") {
                    editor = .create
                }
            }
        }
        .sheet(item: $editor) { route in
            switch route {
            case .create:
                CategoryEditorView(kind: kind)
            case .edit(let categoryID):
                CategoryEditorView(categoryID: categoryID)
            }
        }
        .alert(
            "Can't Delete",
            isPresented: isPresenting($archiveSuggestion),
            presenting: archiveSuggestion
        ) { reference in
            Button("Archive") {
                archive(reference)
            }
            Button("Cancel", role: .cancel) {}
        } message: { reference in
            Text(LedgerError.categoryInUse(name: reference.name).errorDescription ?? "")
        }
        .ledgerAlert($alert)
    }

    // MARK: Rows

    private func row(for category: LedgerCategory, usage: Int) -> some View {
        let reference = CategoryRowReference(category)
        return Button {
            editor = .edit(category.id)
        } label: {
            HStack(spacing: 12) {
                SymbolBadge(
                    systemName: category.symbolName,
                    tint: category.isArchived ? .secondary : tint,
                    size: min(badgeSize, 56)
                )
                // Concrete colors: inside a button, `.primary` and `.secondary` follow the tint.
                VStack(alignment: .leading, spacing: 2) {
                    Text(category.name)
                        .foregroundStyle(category.isArchived ? Color.secondary : Color.primary)
                    Text(detail(for: category, usage: usage))
                        .font(.subheadline)
                        .foregroundStyle(Color.secondary)
                }
            }
            .padding(.vertical, 2)
        }
        .accessibilityLabel(accessibilityLabel(for: category, usage: usage))
        .accessibilityHint("Edits the name and symbol.")
        // Attached to the row so the dialog points at the category being deleted.
        .confirmationDialog(
            "Delete “\(category.name)”?",
            isPresented: isConfirmingDeletion(of: category.id),
            titleVisibility: .visible
        ) {
            Button("Delete \(kind.title)", role: .destructive) {
                delete(reference)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("No transactions use it. This can't be undone.")
        }
        .swipeActions(edge: .trailing) {
            if usage == 0 {
                // A red tint rather than the destructive role, which would animate the row away
                // before the deletion is confirmed.
                Button {
                    pendingDeletion = reference
                } label: {
                    Label("Delete", systemImage: "trash")
                }
                .tint(.red)
            }
            archiveButton(for: category, reference: reference)
        }
        .contextMenu {
            Button("Edit", systemImage: "pencil") {
                editor = .edit(category.id)
            }
            archiveButton(for: category, reference: reference)
            if usage == 0 {
                Button("Delete", systemImage: "trash", role: .destructive) {
                    pendingDeletion = reference
                }
            }
        }
    }

    @ViewBuilder
    private func archiveButton(for category: LedgerCategory, reference: CategoryRowReference) -> some View {
        if category.isArchived {
            Button {
                unarchive(reference)
            } label: {
                Label("Unarchive", systemImage: "tray.and.arrow.up")
            }
            .tint(.blue)
        } else {
            Button {
                archive(reference)
            } label: {
                Label("Archive", systemImage: "archivebox")
            }
            .tint(.indigo)
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No \(kind.pluralTitle)", systemImage: kind.defaultSymbolName)
        } description: {
            Text("Add an \(kind.title.lowercased()) to use when logging \(loggedEntries).")
        } actions: {
            Button("Add \(kind.title)") {
                editor = .create
            }
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: Data

    private var activeCategories: [LedgerCategory] {
        categories.filter { !$0.isArchived }
    }

    private var archivedCategories: [LedgerCategory] {
        categories.filter(\.isArchived)
    }

    /// Number of transactions referencing each category, counted in one pass over all
    /// transactions (any kind), matching what `LedgerService.deleteCategory` checks.
    private var usageCounts: [UUID: Int] {
        var counts: [UUID: Int] = [:]
        for transaction in transactions {
            if let categoryID = transaction.category?.id {
                counts[categoryID, default: 0] += 1
            }
        }
        return counts
    }

    private var tint: Color {
        LedgerTheme.badgeTint(for: kind == .income ? .income : .expense)
    }

    /// "expenses" or "income", as in "logging expenses".
    private var loggedEntries: String {
        kind == .income ? "income" : "expenses"
    }

    private var footerText: String {
        "Archived \(kind.pluralTitle.lowercased()) stay on past transactions but are hidden when logging. "
            + "The order here is the order shown when logging and in Shortcuts."
    }

    private var noActiveMessage: String {
        "No active \(kind.pluralTitle.lowercased()). Add or unarchive one to log \(loggedEntries)."
    }

    private func usageText(_ usage: Int) -> String {
        switch usage {
        case 0: "No transactions"
        case 1: "1 transaction"
        default: "\(usage.formatted()) transactions"
        }
    }

    private func detail(for category: LedgerCategory, usage: Int) -> String {
        category.isArchived ? "Archived · \(usageText(usage))" : usageText(usage)
    }

    private func accessibilityLabel(for category: LedgerCategory, usage: Int) -> String {
        category.isArchived
            ? "\(category.name), archived, \(usageText(usage))"
            : "\(category.name), \(usageText(usage))"
    }

    // MARK: Actions

    private var ledger: LedgerService {
        LedgerService(context: modelContext)
    }

    /// Saves the new order of active categories. Archived ones keep their relative order after them.
    private func move(from source: IndexSet, to destination: Int) {
        var reordered = activeCategories
        reordered.move(fromOffsets: source, toOffset: destination)
        do {
            try ledger.reorderCategories(reordered + archivedCategories)
        } catch {
            alert = LedgerAlert(error)
        }
    }

    private func archive(_ reference: CategoryRowReference) {
        do {
            guard let category = try ledger.category(id: reference.id) else {
                throw LedgerError.categoryNotFound
            }
            try ledger.archiveCategory(category)
        } catch {
            alert = LedgerAlert(error)
        }
    }

    private func unarchive(_ reference: CategoryRowReference) {
        do {
            guard let category = try ledger.category(id: reference.id) else {
                throw LedgerError.categoryNotFound
            }
            try ledger.unarchiveCategory(category)
        } catch {
            alert = LedgerAlert(error)
        }
    }

    /// Deletes the category after confirmation. If a transaction started using it in the
    /// meantime, the service refuses and archiving is offered instead.
    private func delete(_ reference: CategoryRowReference) {
        do {
            guard let category = try ledger.category(id: reference.id) else { return }
            do {
                try ledger.deleteCategory(category)
            } catch LedgerError.categoryInUse {
                if category.isArchived {
                    alert = LedgerAlert(LedgerError.categoryInUse(name: category.name))
                } else {
                    archiveSuggestion = CategoryRowReference(category)
                }
            }
        } catch {
            alert = LedgerAlert(error)
        }
    }

    private func isConfirmingDeletion(of categoryID: UUID) -> Binding<Bool> {
        Binding(
            get: { pendingDeletion?.id == categoryID },
            set: { if !$0 { pendingDeletion = nil } }
        )
    }

    private func isPresenting(_ item: Binding<CategoryRowReference?>) -> Binding<Bool> {
        Binding(
            get: { item.wrappedValue != nil },
            set: { if !$0 { item.wrappedValue = nil } }
        )
    }
}

/// What the category editor sheet should open.
private enum CategoryEditorRoute: Identifiable, Hashable {
    case create
    case edit(UUID)

    var id: Self { self }
}

/// A category identified by ID, with its name captured for confirmation text, so dialogs never
/// hold on to a model that might be deleted while they're shown.
private struct CategoryRowReference: Identifiable, Equatable {
    let id: UUID
    let name: String

    @MainActor
    init(_ category: LedgerCategory) {
        id = category.id
        name = category.name
    }
}

#Preview("Expense Categories") {
    NavigationStack {
        CategoryListView(kind: .expense)
    }
    .ledgerPreview()
}

#Preview("Income Sources") {
    NavigationStack {
        CategoryListView(kind: .income)
    }
    .ledgerPreview()
}

#Preview("No Transactions") {
    NavigationStack {
        CategoryListView(kind: .expense)
    }
    .ledgerPreview(sampleData: false)
}
