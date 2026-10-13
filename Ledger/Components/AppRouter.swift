import Foundation
import Observation
import SwiftUI

/// What the transaction editor sheet should do.
struct TransactionEditorRequest: Identifiable, Hashable, Sendable {
    enum Mode: Hashable, Sendable {
        case create(kind: TransactionKind, accountID: UUID?)
        case edit(transactionID: UUID)
    }

    let id = UUID()
    let mode: Mode

    static func newTransaction(_ kind: TransactionKind = .expense, accountID: UUID? = nil) -> TransactionEditorRequest {
        TransactionEditorRequest(mode: .create(kind: kind, accountID: accountID))
    }

    @MainActor
    static func edit(_ transaction: LedgerTransaction) -> TransactionEditorRequest {
        TransactionEditorRequest(mode: .edit(transactionID: transaction.id))
    }
}

/// App-wide navigation state: the selected tab and the transaction editor sheet.
/// Injected into the environment by `RootView`.
@MainActor
@Observable
final class AppRouter {
    var selectedTab: AppTab
    var editorRequest: TransactionEditorRequest?

    init(selectedTab: AppTab = .dashboard) {
        self.selectedTab = selectedTab
    }

    /// Opens the editor to record a new transaction.
    func addTransaction(_ kind: TransactionKind = .expense, accountID: UUID? = nil) {
        editorRequest = .newTransaction(kind, accountID: accountID)
    }

    /// Opens the editor for an existing transaction.
    func edit(_ transaction: LedgerTransaction) {
        editorRequest = .edit(transaction)
    }
}

/// Destinations pushed onto a tab's navigation stack.
enum LedgerRoute: Hashable, Sendable {
    case transaction(UUID)
    case account(UUID)
}

extension View {
    /// Registers the destinations every tab's navigation stack supports.
    func ledgerRouteDestinations() -> some View {
        navigationDestination(for: LedgerRoute.self) { route in
            switch route {
            case .transaction(let id):
                TransactionDetailView(transactionID: id)
            case .account(let id):
                AccountDetailView(accountID: id)
            }
        }
    }
}

extension EnvironmentValues {
    /// Formats amounts with the user's display preferences. Set by `RootView`.
    @Entry var moneyFormatter = MoneyFormatter()
}
