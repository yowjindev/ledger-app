import SwiftData
import SwiftUI

/// Sheet for creating or editing an expense category or income source: its name and symbol.
/// Presents its own navigation stack.
struct CategoryEditorView: View {
    private enum Mode {
        case create(CategoryKind)
        case edit(UUID)
    }

    private let mode: Mode

    /// Creates a new category or income source of `kind`.
    init(kind: CategoryKind) {
        mode = .create(kind)
    }

    /// Edits the category with `categoryID`, or explains that it no longer exists.
    init(categoryID: UUID) {
        mode = .edit(categoryID)
    }

    var body: some View {
        NavigationStack {
            switch mode {
            case .create(let kind):
                CategoryEditorForm(kind: kind, category: nil)
            case .edit(let categoryID):
                CategoryEditorLookup(categoryID: categoryID)
            }
        }
    }
}

/// Looks up the category being edited by ID, so a category deleted elsewhere is never touched.
private struct CategoryEditorLookup: View {
    @Query private var matches: [LedgerCategory]
    @Environment(\.dismiss) private var dismiss

    init(categoryID: UUID) {
        _matches = Query(filter: #Predicate<LedgerCategory> { $0.id == categoryID })
    }

    var body: some View {
        if let category = matches.first {
            CategoryEditorForm(kind: category.kind, category: category)
        } else {
            ContentUnavailableView(
                "No Longer Available",
                systemImage: "tag.slash",
                description: Text("This category or source was deleted.")
            )
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", role: .close) { dismiss() }
                }
            }
        }
    }
}

/// The editor's form. `category` is `nil` when creating.
private struct CategoryEditorForm: View {
    let kind: CategoryKind
    let category: LedgerCategory?

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var symbolName: String
    @State private var isSaving = false
    @State private var alert: LedgerAlert?
    @State private var isConfirmingDiscard = false
    @FocusState private var isNameFocused: Bool
    @ScaledMetric(relativeTo: .largeTitle) private var previewSize: CGFloat = 76

    private let originalName: String
    private let originalSymbolName: String
    private let symbolChoices: [CategorySymbolChoice]

    init(kind: CategoryKind, category: LedgerCategory?) {
        self.kind = kind
        self.category = category
        let name = category?.name ?? ""
        let symbolName = category?.symbolName ?? kind.defaultSymbolName
        originalName = name
        originalSymbolName = symbolName
        symbolChoices = CategorySymbolCatalog.choices(for: kind, keeping: category?.symbolName)
        _name = State(initialValue: name)
        _symbolName = State(initialValue: symbolName)
    }

    var body: some View {
        Form {
            Section {
                VStack(spacing: 16) {
                    SymbolBadge(systemName: symbolName, tint: tint, size: min(previewSize, 120))
                    TextField(namePrompt, text: $name)
                        .font(.title3.weight(.semibold))
                        .multilineTextAlignment(.center)
                        .textInputAutocapitalization(.words)
                        .submitLabel(.done)
                        .focused($isNameFocused)
                        .padding(.vertical, 12)
                        .padding(.horizontal, 16)
                        .background(.fill.tertiary, in: .rect(cornerRadius: 12, style: .continuous))
                        .accessibilityLabel("Name")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            } footer: {
                nameFooter
            }

            Section("Symbol") {
                CategorySymbolGrid(selection: $symbolName, choices: symbolChoices, tint: tint)
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button("Cancel", role: .cancel) {
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
                Button("Save", role: .confirm, action: save)
                    .disabled(!canSave)
            }
        }
        .interactiveDismissDisabled(hasChanges)
        .onChange(of: name) { _, newValue in
            if newValue.count > LedgerService.nameLengthLimit {
                name = String(newValue.prefix(LedgerService.nameLengthLimit))
            }
        }
        .onAppear {
            if category == nil { isNameFocused = true }
        }
        .ledgerAlert($alert)
    }

    // MARK: Content

    private var tint: Color {
        LedgerTheme.badgeTint(for: kind == .income ? .income : .expense)
    }

    private var title: String {
        category == nil ? "New \(kind.title)" : "Edit \(kind.title)"
    }

    private var namePrompt: String {
        kind == .income ? "Source Name" : "Category Name"
    }

    @ViewBuilder
    private var nameFooter: some View {
        let remaining = LedgerService.nameLengthLimit - name.count
        if category?.isArchived == true || remaining <= 10 {
            VStack(alignment: .leading, spacing: 4) {
                if category?.isArchived == true {
                    Text("Archived: hidden when logging, but kept on past transactions.")
                }
                if remaining <= 10 {
                    Text(remaining == 1 ? "1 character left" : "\(remaining) characters left")
                        .monospacedDigit()
                }
            }
        }
    }

    // MARK: Saving

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var hasChanges: Bool {
        name != originalName || symbolName != originalSymbolName
    }

    private var canSave: Bool {
        !isSaving && !trimmedName.isEmpty && (category == nil || hasChanges)
    }

    private func save() {
        guard canSave else { return }
        isSaving = true
        let ledger = LedgerService(context: modelContext)
        do {
            if let category {
                guard category.modelContext != nil, !category.isDeleted else {
                    throw LedgerError.categoryNotFound
                }
                try ledger.updateCategory(category, name: name, symbolName: symbolName)
            } else {
                try ledger.createCategory(name: name, kind: kind, symbolName: symbolName)
            }
            // Saving stays disabled while the sheet dismisses, so a second tap can't save again.
            dismiss()
        } catch {
            isSaving = false
            alert = LedgerAlert(error)
        }
    }
}

/// Opens the editor for the first seeded expense category.
private struct EditCategoryPreview: View {
    @Query(filter: #Predicate<LedgerCategory> { $0.kindRaw == "expense" }, sort: \LedgerCategory.sortOrder)
    private var categories: [LedgerCategory]

    var body: some View {
        if let category = categories.first {
            CategoryEditorView(categoryID: category.id)
        }
    }
}

#Preview("New Category") {
    CategoryEditorView(kind: .expense)
        .ledgerPreview()
}

#Preview("New Income Source") {
    CategoryEditorView(kind: .income)
        .ledgerPreview()
}

#Preview("Edit Category") {
    EditCategoryPreview()
        .ledgerPreview()
}
