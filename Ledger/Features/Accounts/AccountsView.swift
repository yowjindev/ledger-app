import SwiftData
import SwiftUI

/// The Accounts tab: the total liquid balance, active accounts in display order (reorderable),
/// and archived accounts. Also pushed from Settings, so it never owns a navigation stack.
struct AccountsView: View {
    @Environment(\.modelContext) private var modelContext
    @Query(sort: [SortDescriptor(\Account.sortOrder), SortDescriptor(\Account.createdAt)])
    private var accounts: [Account]
    @Query private var transactions: [LedgerTransaction]
    @State private var isAddingAccount = false
    @State private var alert: LedgerAlert?

    var body: some View {
        let balanceSheet = LedgerService.balanceSheet(accounts: accounts, transactions: transactions)
        content(balanceSheet)
            .navigationTitle("Accounts")
            .toolbar {
                if balanceSheet.activeBalances.count > 1 {
                    ToolbarItem(placement: .topBarTrailing) {
                        EditButton()
                    }
                    ToolbarSpacer(.fixed, placement: .topBarTrailing)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Add Account", systemImage: "plus") {
                        isAddingAccount = true
                    }
                }
            }
            .sheet(isPresented: $isAddingAccount) {
                AccountEditorView(account: nil)
            }
            .ledgerAlert($alert)
    }

    @ViewBuilder
    private func content(_ balanceSheet: BalanceSheet) -> some View {
        if accounts.isEmpty {
            ContentUnavailableView {
                Label("No Accounts", systemImage: "wallet.bifold")
            } description: {
                Text("Add the places you keep money, like a bank account, an e-wallet, or cash.")
            } actions: {
                Button {
                    isAddingAccount = true
                } label: {
                    ContrastingButtonTitle("Add Account")
                }
                .buttonStyle(.borderedProminent)
            }
        } else {
            List {
                Section {
                    AccountsTotalSummary(liquidTotal: balanceSheet.liquidTotal)
                }
                Section {
                    if balanceSheet.activeBalances.isEmpty {
                        Text("No active accounts. Add one, or open an archived account to unarchive it.")
                            .foregroundStyle(.secondary)
                    }
                    ForEach(balanceSheet.activeBalances) { balance in
                        NavigationLink(value: LedgerRoute.account(balance.id)) {
                            AccountListRow(balance: balance)
                        }
                    }
                    .onMove { source, destination in
                        move(from: source, to: destination, in: balanceSheet)
                    }
                } header: {
                    Text("Active")
                } footer: {
                    Text(AccountsCopy.balanceFormula)
                }
                if !balanceSheet.archivedBalances.isEmpty {
                    Section("Archived") {
                        ForEach(balanceSheet.archivedBalances) { balance in
                            NavigationLink(value: LedgerRoute.account(balance.id)) {
                                AccountListRow(balance: balance)
                            }
                        }
                    }
                }
            }
            .listStyle(.insetGrouped)
        }
    }

    /// Saves the order shown after a drag. Archived accounts keep their relative order after
    /// the active ones, so every account ends up with a distinct position.
    private func move(from source: IndexSet, to destination: Int, in balanceSheet: BalanceSheet) {
        var activeIDs = balanceSheet.activeBalances.map(\.id)
        activeIDs.move(fromOffsets: source, toOffset: destination)
        let models = Dictionary(accounts.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let ordered = (activeIDs + balanceSheet.archivedBalances.map(\.id)).compactMap { models[$0] }
        do {
            try LedgerService(context: modelContext).reorderAccounts(ordered)
        } catch {
            alert = LedgerAlert(error)
        }
    }
}

#if DEBUG
#Preview("Sample Data") {
    NavigationStack {
        AccountsView()
            .ledgerRouteDestinations()
    }
    .ledgerPreview()
}

#Preview("No Opening Balances") {
    NavigationStack {
        AccountsView()
            .ledgerRouteDestinations()
    }
    .ledgerPreview(sampleData: false)
}
#endif
