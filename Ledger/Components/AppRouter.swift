import Foundation
import Observation
import SwiftData
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
    /// The automatic interest credited at one moment, for one account or every account.
    case interest(postedAt: Date, accountID: UUID?)
}

extension View {
    /// Registers the destinations every tab's navigation stack supports.
    func ledgerRouteDestinations() -> some View {
        navigationDestination(for: LedgerRoute.self) { route in
            switch route {
            case .transaction(let id):
                TransactionDetailView(transactionID: id)
            case .account(let id):
                AccountDestination(accountID: id)
            case .interest(let postedAt, let accountID):
                InterestPostingDetailView(postedAt: postedAt, accountID: accountID)
            }
        }
    }
}

/// Shows an account's screen: the one for money owed when it's a credit card, pay later
/// account, or loan, otherwise the money account screen.
private struct AccountDestination: View {
    let accountID: UUID
    @Query private var matches: [Account]

    init(accountID: UUID) {
        self.accountID = accountID
        _matches = Query(filter: #Predicate<Account> { $0.id == accountID })
    }

    var body: some View {
        if matches.first?.kind.isOwed == true {
            OwedAccountDetailView(accountID: accountID)
        } else {
            AccountDetailView(accountID: accountID)
        }
    }
}

extension EnvironmentValues {
    /// Formats amounts with the user's display preferences. Set by `RootView`.
    @Entry var moneyFormatter = MoneyFormatter()
}
