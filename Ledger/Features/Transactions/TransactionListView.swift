import Foundation
import SwiftData
import SwiftUI

/// Activity tab: every transaction, newest first, grouped by local day, with search, type and
/// account filters, and swipe actions to edit or delete.
struct TransactionListView: View {
    @Environment(AppRouter.self) private var router
    @Environment(\.modelContext) private var modelContext
    @Environment(\.moneyFormatter) private var formatter
    @Environment(\.locale) private var locale

    @Query(sort: LedgerService.newestFirst, animation: .default)
    private var transactions: [LedgerTransaction]
    @Query(sort: [SortDescriptor(\Account.sortOrder), SortDescriptor(\Account.createdAt)])
    private var accounts: [Account]

    @State private var searchText = ""
    @State private var filter = TransactionFilter()
    @State private var pendingDeletion: PendingDeletion?
    @State private var alert: LedgerAlert?
    @State private var now = Date.now

    var body: some View {
        let matches = transactions.filter {
            filter.includes($0) && TransactionSearch.matches($0, query: searchText, locale: locale)
        }
        List {
            if filter.isActive, !matches.isEmpty {
                Section {
                    activeFilterRow(matchCount: matches.count)
                }
            }
            ForEach(TransactionDay.group(matches)) { day in
                Section(TransactionDay.title(for: day.date, now: now)) {
                    ForEach(HistoryItem.items(from: day.transactions)) { item in
                        switch item {
                        case .transaction(let transaction, let cashback):
                            row(for: transaction, cashback: cashback)
                        case .interest:
                            HistoryItemLink(item: item, accountID: filter.accountID)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(Color(uiColor: .systemGroupedBackground))
        .navigationTitle("Activity")
        .searchable(text: $searchText, prompt: "Category, account, note, or amount")
        .overlay {
            if matches.isEmpty {
                emptyState
            }
        }
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                filterMenu
            }
            ToolbarSpacer(.fixed, placement: .topBarTrailing)
            ToolbarItem(placement: .topBarTrailing) {
                AddTransactionMenu(activeAccountCount: activeAccountCount)
            }
        }
        .confirmationDialog(
            "Delete Transaction?",
            isPresented: isConfirmingDeletion,
            titleVisibility: .visible,
            presenting: pendingDeletion
        ) { item in
            Button("Delete Transaction", role: .destructive) {
                deleteTransaction(id: item.id)
            }
        } message: { item in
            Text("\(item.summary)\nThis can't be undone.")
        }
        .ledgerAlert($alert)
        .refreshingCurrentDate($now)
        .onChange(of: accounts.map(\.id)) { _, ids in
            if let accountID = filter.accountID, !ids.contains(accountID) {
                filter.accountID = nil
            }
        }
    }

    // MARK: Rows

    private func row(for transaction: LedgerTransaction, cashback: LedgerTransaction?) -> some View {
        NavigationLink(value: LedgerRoute.transaction(transaction.id)) {
            TransactionRow(transaction: transaction, cashback: cashback)
        }
        .swipeActions(edge: .trailing) {
            // No destructive role here: the row stays in place until the deletion is confirmed.
            Button {
                requestDeletion(of: transaction)
            } label: {
                Label("Delete", systemImage: "trash")
            }
            .tint(.red)
            if transaction.isEditable {
                Button {
                    router.edit(transaction)
                } label: {
                    Label("Edit", systemImage: "pencil")
                }
                .tint(.accentColor)
            }
        }
        .contextMenu {
            if transaction.isEditable {
                Button("Edit", systemImage: "pencil") {
                    router.edit(transaction)
                }
            }
            Button("Delete", systemImage: "trash", role: .destructive) {
                requestDeletion(of: transaction)
            }
        }
    }

    private func activeFilterRow(matchCount: Int) -> some View {
        HStack(spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "line.3.horizontal.decrease.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.tint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(filterDescription)
                        .font(.subheadline.weight(.semibold))
                    Text(TransactionLogging.countText(matchCount))
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Filtered by \(filterParts.joined(separator: ", ")), \(TransactionLogging.countText(matchCount))")
            Spacer(minLength: 8)
            Button("Clear") {
                withAnimation { filter.clear() }
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Clear Filters")
        }
    }

    // MARK: Toolbar

    private var filterMenu: some View {
        Menu {
            Section("Type") {
                Picker("Type", selection: $filter.type) {
                    ForEach(TransactionTypeFilter.allCases) { type in
                        Label(type.title, systemImage: type.systemImage)
                            .tag(type)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            }
            Picker("Account", selection: $filter.accountID) {
                Text("All Accounts")
                    .tag(UUID?.none)
                ForEach(accounts) { account in
                    Text(account.isArchived ? "\(account.name) (Archived)" : account.name)
                        .tag(UUID?.some(account.id))
                }
            }
            .pickerStyle(.menu)
            if filter.isActive {
                Section {
                    Button("Clear Filters", systemImage: "xmark.circle") {
                        withAnimation { filter.clear() }
                    }
                }
            }
        } label: {
            Label(
                "Filter",
                systemImage: filter.isActive
                    ? "line.3.horizontal.decrease.circle.fill"
                    : "line.3.horizontal.decrease"
            )
        }
        .tint(filter.isActive ? Color.accentColor : nil)
        .accessibilityValue(filter.isActive ? filterParts.joined(separator: ", ") : "Off")
        .disabled(transactions.isEmpty)
    }

    // MARK: Empty states

    @ViewBuilder
    private var emptyState: some View {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        if transactions.isEmpty {
            ContentUnavailableView {
                Label("No Transactions Yet", systemImage: "list.bullet.rectangle")
            } description: {
                Text("Expenses, income, and transfers you log appear here. Log from the Action Button or right here.")
            } actions: {
                Button {
                    router.addTransaction(.expense)
                } label: {
                    Text("Log Expense")
                        .font(.headline)
                        .foregroundStyle(.background)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .disabled(activeAccountCount == 0)
            }
        } else if !query.isEmpty {
            ContentUnavailableView {
                Label("No Results for “\(query)”", systemImage: "magnifyingglass")
            } description: {
                Text(filter.isActive
                    ? "Check the spelling, or clear the filters to search everything."
                    : "Check the spelling or try a different search.")
            } actions: {
                if filter.isActive {
                    Button("Clear Filters") {
                        withAnimation { filter.clear() }
                    }
                }
            }
        } else {
            ContentUnavailableView {
                Label("No Matching Transactions", systemImage: "line.3.horizontal.decrease.circle")
            } description: {
                Text(noMatchesDescription)
            } actions: {
                Button("Clear Filters") {
                    withAnimation { filter.clear() }
                }
            }
        }
    }

    // MARK: Helpers

    private var activeAccountCount: Int {
        accounts.count { !$0.isArchived }
    }

    /// "Expenses · GCash", "Transfers", or "Maya".
    private var filterDescription: String {
        filterParts.joined(separator: " · ")
    }

    /// The active type and account filters, for example ["Expenses", "GCash"].
    private var filterParts: [String] {
        var parts: [String] = []
        if filter.type != .all {
            parts.append(filter.type.title)
        }
        if let accountID = filter.accountID {
            parts.append(accounts.first { $0.id == accountID }?.name ?? TransactionSummary.unknownAccount)
        }
        return parts
    }

    /// Explains an empty result for the active filters, for example "No transfers to or from Maya."
    private var noMatchesDescription: String {
        let accountName = filter.accountID.map { id in
            accounts.first { $0.id == id }?.name ?? TransactionSummary.unknownAccount
        }
        return switch (filter.type, accountName) {
        case (.all, let name?): "No transactions involve \(name)."
        case (.expenses, let name?): "No expenses paid from \(name)."
        case (.income, let name?): "No income deposited to \(name)."
        case (.transfers, let name?): "No transfers to or from \(name)."
        case (.expenses, nil): "No expenses yet."
        case (.income, nil): "No income yet."
        case (.transfers, nil): "No transfers yet."
        case (.all, nil): "Nothing matches these filters."
        }
    }

    private var isConfirmingDeletion: Binding<Bool> {
        Binding(
            get: { pendingDeletion != nil },
            set: { if !$0 { pendingDeletion = nil } }
        )
    }

    private func requestDeletion(of transaction: LedgerTransaction) {
        pendingDeletion = PendingDeletion(
            id: transaction.id,
            summary: TransactionSummary(transaction).confirmationLine(formatter: formatter)
        )
    }

    private func deleteTransaction(id: UUID) {
        let ledger = LedgerService(context: modelContext)
        do {
            guard let transaction = try ledger.transaction(id: id) else {
                throw LedgerError.transactionNotFound
            }
            try ledger.delete(transaction)
        } catch {
            alert = LedgerAlert(error)
        }
    }
}

/// A transaction awaiting confirmation of its deletion. Holds only its ID and description, so the
/// dialog never reads a model that may have changed.
private struct PendingDeletion: Identifiable {
    let id: UUID
    let summary: String
}

#Preview("Activity") {
    NavigationStack {
        TransactionListView()
            .ledgerRouteDestinations()
    }
    .ledgerPreview()
}

#Preview("Activity – Empty") {
    NavigationStack {
        TransactionListView()
    }
    .ledgerPreview(sampleData: false)
}
