import Foundation
import SwiftData
import os

/// The single entry point for financial reads, writes, and calculations.
///
/// The SwiftUI app and App Intents both create a `LedgerService` over the shared main context,
/// so every entry point applies the same validation and arithmetic. Each mutation saves before
/// returning. If saving fails, pending changes are rolled back and `LedgerError.persistenceFailed`
/// is thrown, so a failed save is never reported as success.
///
/// Views must not modify model objects directly; all writes go through this type.
@MainActor
struct LedgerService {
    static let nameLengthLimit = 40
    static let noteLengthLimit = 500
    static let referenceLengthLimit = 100

    let context: ModelContext
    /// The calendar and time zone that decide where one day ends and the next begins.
    let calendar: Calendar
    private let clock: () -> Date
    private let persist: (ModelContext) throws -> Void

    /// - Parameters:
    ///   - clock: Supplies the current time; injectable for deterministic tests.
    ///   - calendar: Defines days for daily interest; injectable for deterministic tests.
    ///   - persist: Saves the context; injectable to simulate storage failures in tests.
    init(
        context: ModelContext,
        clock: @escaping () -> Date = { Date.now },
        calendar: Calendar = .current,
        persist: @escaping (ModelContext) throws -> Void = { try $0.save() }
    ) {
        self.context = context
        self.calendar = calendar
        self.clock = clock
        self.persist = persist
    }

    var now: Date { clock() }

    /// Saves pending changes. On failure, discards them so no unsaved state lingers in the
    /// context, then throws `LedgerError.persistenceFailed`.
    func commit() throws {
        do {
            try persist(context)
        } catch {
            context.rollback()
            refreshLoadedModels()
            Log.persistence.error("Save failed and was rolled back: \(String(describing: error), privacy: .private)")
            throw LedgerError.persistenceFailed
        }
    }

    /// `rollback()` reverts the context, but model objects that are already loaded keep showing
    /// the discarded values until they are fetched again. Fetching every type the ledger writes
    /// reloads their saved values.
    private func refreshLoadedModels() {
        _ = try? context.fetch(FetchDescriptor<Account>())
        _ = try? context.fetch(FetchDescriptor<LedgerCategory>())
        _ = try? context.fetch(FetchDescriptor<LedgerTransaction>())
        _ = try? context.fetch(FetchDescriptor<PaymentPlan>())
        _ = try? context.fetch(FetchDescriptor<Bill>())
        _ = try? context.fetch(FetchDescriptor<DueOverride>())
    }

    /// Trims a name and checks it is non-empty, short enough, and not already used
    /// (ignoring case, diacritics, and width).
    func validatedName(_ raw: String, existingNames: [String]) throws -> String {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw LedgerError.emptyName }
        guard name.count <= Self.nameLengthLimit else {
            throw LedgerError.nameTooLong(limit: Self.nameLengthLimit)
        }
        let isTaken = existingNames.contains {
            $0.compare(name, options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive]) == .orderedSame
        }
        guard !isTaken else { throw LedgerError.duplicateName(name) }
        return name
    }

    /// Trims optional free text; empty text becomes `nil`.
    func normalizedText(_ text: String?, limit: Int) throws -> String? {
        guard let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        guard trimmed.count <= limit else { throw LedgerError.textTooLong(limit: limit) }
        return trimmed
    }
}
