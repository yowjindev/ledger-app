import Foundation

/// Top-level tabs of the main app.
enum AppTab: String, CaseIterable, Hashable, Sendable {
    case dashboard
    case transactions
    case accounts
    case settings
}

/// Process-wide launch options. The debug arguments have no effect in Release builds.
///
/// Debug arguments (pass in the scheme or to `simctl launch`):
/// - `-LedgerInMemoryStore YES`: keep all data in memory; the on-disk store is untouched.
/// - `-LedgerSampleData YES`: with an in-memory store, add illustrative sample records.
/// - `-LedgerSkipOnboarding YES`: start on the tabs.
/// - `-LedgerInitialTab transactions`: open a specific tab.
/// - `-LedgerOpenEditor expense`: open the transaction editor for a kind on launch.
struct AppLaunchConfiguration: Sendable {
    var usesInMemoryStore: Bool
    var loadsSampleData: Bool
    var skipsOnboarding: Bool
    var initialTab: AppTab?
    var initialEditorKind: TransactionKind?

    static let current = resolve(
        environment: ProcessInfo.processInfo.environment,
        defaults: .standard
    )

    static func resolve(environment: [String: String], defaults: UserDefaults) -> AppLaunchConfiguration {
        let isUnitTesting = environment["XCTestConfigurationFilePath"] != nil
        #if DEBUG
        let inMemory = isUnitTesting || defaults.bool(forKey: "LedgerInMemoryStore")
        return AppLaunchConfiguration(
            usesInMemoryStore: inMemory,
            loadsSampleData: inMemory && !isUnitTesting && defaults.bool(forKey: "LedgerSampleData"),
            skipsOnboarding: isUnitTesting || defaults.bool(forKey: "LedgerSkipOnboarding"),
            initialTab: defaults.string(forKey: "LedgerInitialTab").flatMap(AppTab.init(rawValue:)),
            initialEditorKind: defaults.string(forKey: "LedgerOpenEditor")
                .flatMap(TransactionKind.init(rawValue:))
                .flatMap { TransactionKind.loggable.contains($0) ? $0 : nil }
        )
        #else
        return AppLaunchConfiguration(
            usesInMemoryStore: isUnitTesting,
            loadsSampleData: false,
            skipsOnboarding: isUnitTesting,
            initialTab: nil,
            initialEditorKind: nil
        )
        #endif
    }
}
