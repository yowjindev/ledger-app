import Foundation
import SwiftData
import os

extension LedgerService {
    // MARK: Queries

    func category(id: UUID) throws -> LedgerCategory? {
        var descriptor = FetchDescriptor<LedgerCategory>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try context.fetch(descriptor).first
    }

    /// Expense categories or income sources in display order. Archived ones are excluded unless requested.
    func categories(kind: CategoryKind, includeArchived: Bool = false) throws -> [LedgerCategory] {
        let kindRaw = kind.rawValue
        let sort = [SortDescriptor(\LedgerCategory.sortOrder), SortDescriptor(\LedgerCategory.createdAt)]
        let predicate: Predicate<LedgerCategory>
        if includeArchived {
            predicate = #Predicate { $0.kindRaw == kindRaw }
        } else {
            predicate = #Predicate { $0.kindRaw == kindRaw && !$0.isArchived }
        }
        return try context.fetch(FetchDescriptor<LedgerCategory>(predicate: predicate, sortBy: sort))
    }

    func transactionCount(for category: LedgerCategory) throws -> Int {
        let id = category.id
        return try context.fetch(FetchDescriptor<LedgerTransaction>()).count { $0.category?.id == id }
    }

    // MARK: Mutations

    @discardableResult
    func createCategory(name: String, kind: CategoryKind, symbolName: String? = nil) throws -> LedgerCategory {
        let existing = try categories(kind: kind, includeArchived: true)
        let cleanName = try validatedName(name, existingNames: existing.map(\.name))
        let category = LedgerCategory(
            name: cleanName,
            kind: kind,
            symbolName: normalizedSymbol(symbolName, kind: kind),
            createdAt: now,
            sortOrder: (existing.map(\.sortOrder).max() ?? -1) + 1
        )
        context.insert(category)
        try commit()
        Log.ledger.info("Created a category")
        return category
    }

    /// Renames a category or changes its symbol. Its kind can't change, so existing transactions
    /// stay valid; history shows the new name. A `nil` symbol keeps the current one.
    func updateCategory(_ category: LedgerCategory, name: String, symbolName: String? = nil) throws {
        let others = try categories(kind: category.kind, includeArchived: true).filter { $0.id != category.id }
        let cleanName = try validatedName(name, existingNames: others.map(\.name))
        category.name = cleanName
        if let symbolName {
            category.symbolName = normalizedSymbol(symbolName, kind: category.kind)
        }
        try commit()
        Log.ledger.info("Updated a category")
    }

    /// Hides a category from pickers. Transactions that use it keep it.
    func archiveCategory(_ category: LedgerCategory) throws {
        guard !category.isArchived else { return }
        category.isArchived = true
        category.archivedAt = now
        try commit()
        Log.ledger.info("Archived a category")
    }

    /// Restores an archived category to its previous position, or after the others of its kind
    /// if another category has taken that position since.
    func unarchiveCategory(_ category: LedgerCategory) throws {
        guard category.isArchived else { return }
        let otherOrders = try categories(kind: category.kind, includeArchived: true).filter { $0.id != category.id }.map(\.sortOrder)
        category.isArchived = false
        category.archivedAt = nil
        if otherOrders.contains(category.sortOrder) {
            category.sortOrder = (otherOrders.max() ?? -1) + 1
        }
        try commit()
        Log.ledger.info("Unarchived a category")
    }

    /// Deletes a category no transaction uses. Categories with history can only be archived.
    func deleteCategory(_ category: LedgerCategory) throws {
        guard try transactionCount(for: category) == 0 else {
            throw LedgerError.categoryInUse(name: category.name)
        }
        context.delete(category)
        try commit()
        Log.ledger.info("Deleted a category")
    }

    /// Persists a new display order for categories of one kind (also used by App Intents pickers).
    func reorderCategories(_ ordered: [LedgerCategory]) throws {
        for (index, category) in ordered.enumerated() where category.sortOrder != index {
            category.sortOrder = index
        }
        try commit()
    }

    private func normalizedSymbol(_ symbolName: String?, kind: CategoryKind) -> String {
        guard let trimmed = symbolName?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return kind.defaultSymbolName
        }
        return trimmed
    }
}
