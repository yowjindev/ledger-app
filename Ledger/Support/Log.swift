import Foundation
import os

/// Loggers. Never log amounts, balances, names of accounts or categories, or notes;
/// interpolated values default to private and are redacted from system logs.
enum Log {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "Ledger"

    static let persistence = Logger(subsystem: subsystem, category: "persistence")
    static let ledger = Logger(subsystem: subsystem, category: "ledger")
    static let intents = Logger(subsystem: subsystem, category: "intents")
}
