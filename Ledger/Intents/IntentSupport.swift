import AppIntents
import Foundation

/// Errors shown by Shortcuts, Siri, and the Action Button. Messages never include balances.
enum LedgerIntentError: Error, Equatable, CustomLocalizedStringResourceConvertible {
    case storeUnavailable
    case noActiveAccounts
    case needsTwoAccounts
    case noCategories(CategoryKind)
    case ledger(LedgerError)

    var message: String {
        switch self {
        case .storeUnavailable:
            "Ledger couldn't open its data, so nothing was recorded. Open the Ledger app for details."
        case .noActiveAccounts:
            "You don't have any active accounts. Add one in the Ledger app first."
        case .needsTwoAccounts:
            "A transfer needs two active accounts. Add another account in the Ledger app."
        case .noCategories(let kind):
            kind == .expense
                ? "You don't have any expense categories. Add one in Ledger Settings."
                : "You don't have any income sources. Add one in Ledger Settings."
        case .ledger(let error):
            error.errorDescription ?? "Something went wrong. Nothing was recorded."
        }
    }

    var localizedStringResource: LocalizedStringResource { "\(message)" }
}

/// Access to the ledger for App Intents. Intents run on the main actor in the app's process and
/// use the same container and `LedgerService` as the app.
@MainActor
enum IntentLedger {
    static func service() throws -> LedgerService {
        do {
            return LedgerService(context: try LedgerStore.mainContext())
        } catch {
            throw LedgerIntentError.storeUnavailable
        }
    }

    /// Runs a ledger operation, presenting `LedgerError`s with their user-facing messages.
    static func perform<T>(_ operation: () throws -> T) throws -> T {
        do {
            return try operation()
        } catch let error as LedgerError {
            throw LedgerIntentError.ledger(error)
        }
    }
}

/// Extra confirmations in the logging flows.
enum IntentPolicy {
    /// Expenses and income at or above this amount ask for confirmation, to catch an extra zero
    /// typed in a hurry.
    static let largeAmountThreshold: Decimal = 100_000
    /// How many times an invalid amount is asked for again before the flow gives up.
    static let amountAttempts = 3
}

extension IntentDialog {
    /// A dialog showing runtime text as-is.
    static func plain(_ text: String) -> IntentDialog {
        IntentDialog("\(text)")
    }
}
