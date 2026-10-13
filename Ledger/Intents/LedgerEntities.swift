import AppIntents
import Foundation

/// An account offered in Shortcuts, Siri, and Action Button prompts.
struct AccountEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Account")
    static let defaultQuery = AccountEntityQuery()

    let id: UUID
    let name: String
    let kind: AccountKind

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(
            title: "\(name)",
            subtitle: "\(kind.title)",
            image: DisplayRepresentation.Image(systemName: kind.systemImage)
        )
    }
}

extension AccountEntity {
    @MainActor
    init(_ account: Account) {
        self.init(id: account.id, name: account.name, kind: account.kind)
    }
}

/// Offers active accounts in display order. Lookups by ID include archived accounts, so a saved
/// shortcut that names one gets a clear "archived" message rather than failing silently.
struct AccountEntityQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [AccountEntity] {
        let ledger = try IntentLedger.service()
        return try identifiers.compactMap { try ledger.account(id: $0) }.map(AccountEntity.init)
    }

    @MainActor
    func suggestedEntities() async throws -> [AccountEntity] {
        try IntentLedger.service().accounts().map(AccountEntity.init)
    }

    @MainActor
    func entities(matching string: String) async throws -> [AccountEntity] {
        try await suggestedEntities().filter { $0.name.localizedStandardContains(string) }
    }
}

/// An expense category offered when logging an expense.
struct ExpenseCategoryEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Expense Category")
    static let defaultQuery = ExpenseCategoryQuery()

    let id: UUID
    let name: String
    let symbolName: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", image: DisplayRepresentation.Image(systemName: symbolName))
    }
}

extension ExpenseCategoryEntity {
    @MainActor
    init(_ category: LedgerCategory) {
        self.init(id: category.id, name: category.name, symbolName: category.symbolName)
    }
}

/// Offers active expense categories in display order.
struct ExpenseCategoryQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [ExpenseCategoryEntity] {
        try CategoryLookup.categories(for: identifiers, kind: .expense).map(ExpenseCategoryEntity.init)
    }

    @MainActor
    func suggestedEntities() async throws -> [ExpenseCategoryEntity] {
        try CategoryLookup.active(kind: .expense).map(ExpenseCategoryEntity.init)
    }

    @MainActor
    func entities(matching string: String) async throws -> [ExpenseCategoryEntity] {
        try await suggestedEntities().filter { $0.name.localizedStandardContains(string) }
    }
}

/// An income source offered when logging income.
struct IncomeSourceEntity: AppEntity {
    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Income Source")
    static let defaultQuery = IncomeSourceQuery()

    let id: UUID
    let name: String
    let symbolName: String

    var displayRepresentation: DisplayRepresentation {
        DisplayRepresentation(title: "\(name)", image: DisplayRepresentation.Image(systemName: symbolName))
    }
}

extension IncomeSourceEntity {
    @MainActor
    init(_ category: LedgerCategory) {
        self.init(id: category.id, name: category.name, symbolName: category.symbolName)
    }
}

/// Offers active income sources in display order.
struct IncomeSourceQuery: EntityStringQuery {
    @MainActor
    func entities(for identifiers: [UUID]) async throws -> [IncomeSourceEntity] {
        try CategoryLookup.categories(for: identifiers, kind: .income).map(IncomeSourceEntity.init)
    }

    @MainActor
    func suggestedEntities() async throws -> [IncomeSourceEntity] {
        try CategoryLookup.active(kind: .income).map(IncomeSourceEntity.init)
    }

    @MainActor
    func entities(matching string: String) async throws -> [IncomeSourceEntity] {
        try await suggestedEntities().filter { $0.name.localizedStandardContains(string) }
    }
}

/// Category lookups shared by the category queries.
@MainActor
private enum CategoryLookup {
    /// Categories of `kind` with the given IDs, archived ones included.
    static func categories(for identifiers: [UUID], kind: CategoryKind) throws -> [LedgerCategory] {
        let ledger = try IntentLedger.service()
        return try identifiers.compactMap { try ledger.category(id: $0) }.filter { $0.kind == kind }
    }

    static func active(kind: CategoryKind) throws -> [LedgerCategory] {
        try IntentLedger.service().categories(kind: kind)
    }
}

/// The choices offered by the Ledger Menu shortcut.
enum LedgerAction: String, AppEnum, CaseIterable {
    case expense
    case income
    case transfer
    case balances

    static let typeDisplayRepresentation = TypeDisplayRepresentation(name: "Ledger Action")

    static let caseDisplayRepresentations: [LedgerAction: DisplayRepresentation] = [
        .expense: DisplayRepresentation(
            title: "Expense",
            subtitle: "Log money you spent",
            image: DisplayRepresentation.Image(systemName: "arrow.up.right.circle.fill"),
            synonyms: ["Spend", "Spent", "Purchase"]
        ),
        .income: DisplayRepresentation(
            title: "Income",
            subtitle: "Log money you received",
            image: DisplayRepresentation.Image(systemName: "arrow.down.left.circle.fill"),
            synonyms: ["Received", "Salary"]
        ),
        .transfer: DisplayRepresentation(
            title: "Transfer",
            subtitle: "Move money between your accounts",
            image: DisplayRepresentation.Image(systemName: "arrow.left.arrow.right.circle.fill"),
            synonyms: ["Move money"]
        ),
        .balances: DisplayRepresentation(
            title: "Check Balances",
            subtitle: "See what each account holds",
            image: DisplayRepresentation.Image(systemName: "banknote.fill"),
            synonyms: ["Balances", "Balance"]
        ),
    ]
}
