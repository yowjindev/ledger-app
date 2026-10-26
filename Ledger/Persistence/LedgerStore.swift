import Foundation
import SwiftData
import os

/// Shown when the data store can't be opened. Recovery never deletes the store file.
struct LedgerStoreError: Error, LocalizedError, Sendable {
    let underlyingDescription: String

    var errorDescription: String? {
        "Ledger couldn't open its data. Your data has not been deleted."
    }
}

/// Owns the app's single SwiftData container. The app UI and App Intents share it, so every
/// entry point reads and writes the same records through `LedgerService`.
@MainActor
enum LedgerStore {
    enum Storage {
        case onDisk(URL)
        case inMemory
    }

    /// The shared container, opened on first use from either the app or an App Intent.
    static let shared: Result<ModelContainer, LedgerStoreError> = openShared(configuration: .current)

    /// Application Support/Ledger/Ledger.store. Included in iCloud and computer backups.
    nonisolated static var defaultStoreURL: URL {
        URL.applicationSupportDirectory
            .appending(path: "Ledger", directoryHint: .isDirectory)
            .appending(path: "Ledger.store", directoryHint: .notDirectory)
    }

    /// The shared main context.
    static func mainContext() throws -> ModelContext {
        try shared.get().mainContext
    }

    /// Creates a container for the current schema, running any registered migrations.
    /// Local only: CloudKit is explicitly disabled so no data leaves the device.
    static func makeContainer(storage: Storage) throws -> ModelContainer {
        let schema = Schema(versionedSchema: LedgerSchemaV4.self)
        let configuration: ModelConfiguration
        switch storage {
        case .onDisk(let url):
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            configuration = ModelConfiguration(
                "Ledger",
                schema: schema,
                url: url,
                allowsSave: true,
                cloudKitDatabase: .none
            )
        case .inMemory:
            configuration = ModelConfiguration(
                UUID().uuidString,
                schema: schema,
                isStoredInMemoryOnly: true,
                allowsSave: true,
                groupContainer: .none,
                cloudKitDatabase: .none
            )
        }
        let container = try ModelContainer(
            for: schema,
            migrationPlan: LedgerMigrationPlan.self,
            configurations: [configuration]
        )
        // Every write goes through LedgerService, which saves explicitly and reports failures.
        container.mainContext.autosaveEnabled = false
        return container
    }

    private static func openShared(configuration: AppLaunchConfiguration) -> Result<ModelContainer, LedgerStoreError> {
        do {
            let container: ModelContainer
            let bootstrapper: LedgerBootstrapper
            if configuration.usesInMemoryStore {
                container = try makeContainer(storage: .inMemory)
                bootstrapper = LedgerBootstrapper(context: container.mainContext, marker: nil)
            } else {
                container = try makeContainer(storage: .onDisk(defaultStoreURL))
                bootstrapper = LedgerBootstrapper(context: container.mainContext, marker: .standard)
            }
            bootstrapper.seedIfNeeded(with: .personalDefault)
            #if DEBUG
            if configuration.loadsSampleData {
                SampleData.load(into: container.mainContext)
            }
            #endif
            return .success(container)
        } catch {
            Log.persistence.fault("Could not open the data store: \(String(describing: error), privacy: .private)")
            return .failure(LedgerStoreError(underlyingDescription: String(describing: error)))
        }
    }
}

/// Prepares a newly created store.
@MainActor
struct LedgerBootstrapper {
    static let seedMarkerKey = "ledger.seed.v1.applied"

    let context: ModelContext
    /// Records that seeding happened, so deleting every account later doesn't re-seed.
    /// `nil` for in-memory stores, which must not affect the on-disk store's marker.
    let marker: UserDefaults?

    /// Inserts the seed accounts and categories in one save when the store is empty.
    /// Never modifies a store that already contains accounts or categories.
    @discardableResult
    func seedIfNeeded(with seed: SeedConfiguration, now: Date = .now) -> Bool {
        if marker?.bool(forKey: Self.seedMarkerKey) == true { return false }
        do {
            let isEmpty = try context.fetchCount(FetchDescriptor<Account>()) == 0
                && context.fetchCount(FetchDescriptor<LedgerCategory>()) == 0
            guard isEmpty else {
                marker?.set(true, forKey: Self.seedMarkerKey)
                return false
            }
            for (index, item) in seed.accounts.enumerated() {
                let openingMinor = try item.openingBalance.map {
                    try AmountRules.openingBalanceMinorUnits($0, currency: .php)
                }
                context.insert(Account(
                    name: item.name,
                    kind: item.kind,
                    openingBalanceMinor: openingMinor,
                    createdAt: now,
                    sortOrder: index
                ))
            }
            for kind in CategoryKind.allCases {
                for (index, item) in seed.categories.filter({ $0.kind == kind }).enumerated() {
                    context.insert(LedgerCategory(
                        name: item.name,
                        kind: kind,
                        symbolName: item.symbolName,
                        createdAt: now,
                        sortOrder: index
                    ))
                }
            }
            try context.save()
            marker?.set(true, forKey: Self.seedMarkerKey)
            Log.persistence.info("Seeded default accounts and categories")
            return true
        } catch {
            context.rollback()
            Log.persistence.error("Seeding failed: \(String(describing: error), privacy: .private)")
            return false
        }
    }
}
