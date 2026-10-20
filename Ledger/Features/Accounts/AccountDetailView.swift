import SwiftData
import SwiftUI

/// One account: its current balance and how it's derived, its transactions, and account actions.
/// Looks the account up by ID, so it copes with the account being deleted elsewhere.
struct AccountDetailView: View {
    /// Transactions listed here before linking to the full history.
    static let recentTransactionLimit = 50

    let accountID: UUID

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.moneyFormatter) private var formatter
    @Environment(AppRouter.self) private var router
    @Query private var matches: [Account]
    @Query(sort: LedgerService.newestFirst) private var transactions: [LedgerTransaction]
    @State private var editor: AccountEditorPresentation?
    @State private var isUpdatingBalance = false
    @State private var isConfirmingArchive = false
    @State private var isConfirmingDelete = false
    /// Set once this screen deleted the account, while it closes.
    @State private var didDelete = false
    @State private var alert: LedgerAlert?

    init(accountID: UUID) {
        self.accountID = accountID
        _matches = Query(filter: #Predicate<Account> { $0.id == accountID })
    }

    var body: some View {
        if let account = matches.first,
           let balance = LedgerService.balanceSheet(accounts: [account], transactions: transactions)
               .balance(for: account.id) {
            content(account: account, balance: balance)
        } else if didDelete {
            ContentUnavailableView("Account Deleted", systemImage: "trash")
        } else {
            ContentUnavailableView(
                "Account Not Found",
                systemImage: "questionmark.folder",
                description: Text("It may have been deleted.")
            )
        }
    }

    private func content(account: Account, balance: AccountBalance) -> some View {
        let history = transactions.filter {
            $0.account?.id == accountID || $0.destinationAccount?.id == accountID
        }
        return List {
            Section {
                header(balance)
            }
            breakdownSection(balance)
            transactionsSection(history)
            actionsSection(account: account, balance: balance, hasTransactions: !history.isEmpty)
        }
        .listStyle(.insetGrouped)
        .navigationTitle(balance.account.name)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Edit") {
                    openEditor(focusing: nil)
                }
            }
        }
        .sheet(item: $editor) { presentation in
            AccountEditorView(account: account, initialFocus: presentation.focus)
        }
        .sheet(isPresented: $isUpdatingBalance) {
            UpdateBalanceView(account: account)
        }
        .ledgerAlert($alert)
    }

    // MARK: Sections

    private func header(_ balance: AccountBalance) -> some View {
        VStack(spacing: 8) {
            VStack(spacing: 8) {
                SymbolBadge(
                    systemName: balance.account.kind.systemImage,
                    tint: balance.account.isArchived ? .secondary : .accentColor,
                    size: 52
                )
                HStack(spacing: 8) {
                    Text(balance.account.kind.title)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    if balance.account.isArchived {
                        ArchivedAccountTag()
                    }
                }
                if let current = balance.currentBalance {
                    MoneyText(current)
                        .font(.system(.largeTitle, design: .rounded, weight: .bold))
                        .lineLimit(1)
                        .minimumScaleFactor(0.5)
                        .padding(.top, 4)
                    Text("Current Balance")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Image(systemName: "exclamationmark.circle.fill")
                            .foregroundStyle(.orange)
                        Text("Opening balance not set")
                    }
                    .font(.headline)
                    .padding(.top, 4)
                    Text("Set it to see this account's current balance.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(headerAccessibilityText(balance))

            if balance.currentBalance == nil {
                Button {
                    openEditor(focusing: .openingBalance)
                } label: {
                    ContrastingButtonTitle("Set Opening Balance")
                }
                .buttonStyle(.borderedProminent)
                .padding(.top, 4)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }

    private func breakdownSection(_ balance: AccountBalance) -> some View {
        Section {
            LabeledContent("Opening Balance") {
                if let opening = balance.openingBalance {
                    MoneyText(opening)
                } else {
                    Text("Not Set")
                }
            }
            LabeledContent("Income") { signedAmount(balance.income) }
            LabeledContent("Transfers In") { signedAmount(balance.transfersIn) }
            LabeledContent("Expenses") { signedAmount(-balance.expenses) }
            LabeledContent("Transfers Out") { signedAmount(-balance.transfersOut) }
            LabeledContent("Adjustments") { signedAmount(balance.adjustments) }
            LabeledContent("Net Activity") { signedAmount(balance.netActivity) }
            LabeledContent("Current Balance") {
                if let current = balance.currentBalance {
                    MoneyText(current)
                        .foregroundStyle(.primary)
                } else {
                    Text("Unknown")
                }
            }
            .fontWeight(.semibold)
        } header: {
            Text("Breakdown")
        } footer: {
            Text(AccountsCopy.balanceFormula)
        }
    }

    private func transactionsSection(_ history: [LedgerTransaction]) -> some View {
        Section {
            if history.isEmpty {
                Text("No transactions yet")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(history.prefix(Self.recentTransactionLimit)) { transaction in
                    NavigationLink(value: LedgerRoute.transaction(transaction.id)) {
                        TransactionRow(transaction: transaction, showsDate: true)
                    }
                }
                if history.count > Self.recentTransactionLimit {
                    NavigationLink {
                        AccountTransactionsView(accountID: accountID)
                    } label: {
                        Text("Show All \(history.count) Transactions")
                    }
                }
            }
        } header: {
            Text(history.count > Self.recentTransactionLimit ? "Latest Transactions" : "Transactions")
        }
    }

    private func actionsSection(account: Account, balance: AccountBalance, hasTransactions: Bool) -> some View {
        Section {
            if balance.account.isArchived {
                Button("Unarchive Account", systemImage: "tray.and.arrow.up") {
                    unarchive(account)
                }
            } else {
                Button("Update Balance", systemImage: "plus.forwardslash.minus") {
                    isUpdatingBalance = true
                }
                Button("Add Transaction", systemImage: "plus.circle") {
                    router.addTransaction(.expense, accountID: accountID)
                }
                Button("Archive Account", systemImage: "archivebox") {
                    isConfirmingArchive = true
                }
                .confirmationDialog(
                    "Archive \(balance.account.name)?",
                    isPresented: $isConfirmingArchive,
                    titleVisibility: .visible
                ) {
                    Button("Archive Account") {
                        archive(account)
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text(archiveMessage(for: balance))
                }
            }
            if !hasTransactions {
                Button("Delete Account", systemImage: "trash", role: .destructive) {
                    isConfirmingDelete = true
                }
                .confirmationDialog(
                    "Delete \(balance.account.name)?",
                    isPresented: $isConfirmingDelete,
                    titleVisibility: .visible
                ) {
                    Button("Delete Account", role: .destructive) {
                        delete(account)
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This can't be undone.")
                }
            }
        } footer: {
            if hasTransactions {
                Text("An account with transactions can't be deleted, only archived, so its history stays.")
            }
        }
    }

    // MARK: Text

    /// A sign for every non-zero amount, so direction never depends on color.
    private func signedAmount(_ money: Money) -> some View {
        Text(formatter.string(money, sign: money.isZero ? .never : .always))
            .monospacedDigit()
    }

    private func headerAccessibilityText(_ balance: AccountBalance) -> String {
        var parts: [String] = []
        if let current = balance.currentBalance {
            parts.append("Current balance \(formatter.string(current, alwaysShowCentavos: true))")
        } else {
            parts.append("Opening balance not set. Current balance unknown")
        }
        parts.append(balance.account.kind.title)
        if balance.account.isArchived {
            parts.append("Archived")
        }
        return parts.joined(separator: ", ")
    }

    private func archiveMessage(for balance: AccountBalance) -> String {
        let consequences = "Archived accounts are hidden when logging and excluded from Total Liquid. Its history stays."
        guard let current = balance.currentBalance, !current.isZero else { return consequences }
        let amount = formatter.string(current)
        let holding = current.isNegative
            ? "\(balance.account.name) has a balance of \(amount)."
            : "\(balance.account.name) still holds \(amount)."
        return "\(holding) \(consequences)"
    }

    // MARK: Actions

    private func openEditor(focusing field: AccountEditorView.Field?) {
        editor = AccountEditorPresentation(focus: field)
    }

    private func archive(_ account: Account) {
        perform(on: account) { try $0.archiveAccount(account) }
    }

    private func unarchive(_ account: Account) {
        perform(on: account) { try $0.unarchiveAccount(account) }
    }

    private func delete(_ account: Account) {
        if perform(on: account, { try $0.deleteAccount(account) }) {
            didDelete = true
            dismiss()
        }
    }

    /// Runs a ledger change to `account`, reporting failure in an alert. Returns whether it
    /// succeeded. An account deleted elsewhere is reported instead of being touched.
    @discardableResult
    private func perform(on account: Account, _ change: (LedgerService) throws -> Void) -> Bool {
        guard !account.isDeleted, account.modelContext != nil else {
            alert = LedgerAlert(LedgerError.accountNotFound)
            return false
        }
        do {
            try change(LedgerService(context: modelContext))
            return true
        } catch {
            alert = LedgerAlert(error)
            return false
        }
    }
}

/// Opens the account editor, optionally focusing one of its fields.
private struct AccountEditorPresentation: Identifiable {
    let id = UUID()
    let focus: AccountEditorView.Field?
}

/// A small capsule marking an archived account.
private struct ArchivedAccountTag: View {
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "archivebox.fill")
            Text("Archived")
        }
        .font(.caption.weight(.semibold))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(.quaternary, in: .capsule)
    }
}

#if DEBUG
/// Shows the detail of the first account in the preview container.
private struct AccountDetailPreviewHost: View {
    @Query(sort: \Account.sortOrder) private var accounts: [Account]

    var body: some View {
        if let account = accounts.first {
            AccountDetailView(accountID: account.id)
        }
    }
}

#Preview("Sample Data") {
    NavigationStack {
        AccountDetailPreviewHost()
            .ledgerRouteDestinations()
    }
    .ledgerPreview()
}

#Preview("No Opening Balance") {
    NavigationStack {
        AccountDetailPreviewHost()
            .ledgerRouteDestinations()
    }
    .ledgerPreview(sampleData: false)
}

#Preview("Not Found") {
    NavigationStack {
        AccountDetailView(accountID: UUID())
    }
    .ledgerPreview()
}
#endif
