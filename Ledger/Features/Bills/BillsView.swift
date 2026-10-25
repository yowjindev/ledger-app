import SwiftData
import SwiftUI

/// The Bills tab: everything coming due, then credit cards, pay later accounts, and loans in
/// their own groups, and what they owe in total. Reads everything with `@Query`, so a payment
/// logged anywhere, including from the Action Button, updates it at once.
struct BillsView: View {
    @Environment(\.calendar) private var calendar
    @Environment(\.moneyFormatter) private var formatter
    @Query(sort: [SortDescriptor(\Account.sortOrder), SortDescriptor(\Account.createdAt)])
    private var accounts: [Account]
    @Query private var transactions: [LedgerTransaction]
    @Query private var plans: [PaymentPlan]
    @Query(sort: [SortDescriptor(\Bill.sortOrder), SortDescriptor(\Bill.createdAt)])
    private var bills: [Bill]
    @Query private var overrides: [DueOverride]
    @State private var now = Date.now
    @State private var adding: AccountKind?

    var body: some View {
        let sheet = LedgerService.balanceSheet(accounts: accounts, transactions: transactions)
        let today = CalendarDay(containing: now, calendar: calendar)
        Group {
            if sheet.owedBalances.isEmpty && bills.allSatisfy(\.isArchived) && !hasArchived(sheet) {
                emptyState
            } else {
                list(sheet, today: today)
            }
        }
        .navigationTitle("Bills")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                addMenu
            }
        }
        .refreshingCurrentDate($now)
        .sheet(item: $adding) { kind in
            OwedAccountEditorView(kind: kind)
        }
    }

    // MARK: Content

    private func list(_ sheet: BalanceSheet, today: CalendarDay) -> some View {
        let dues = LedgerService.comingUp(
            accounts: accounts,
            transactions: transactions,
            plans: plans,
            bills: bills,
            overrides: overrides,
            today: today,
            calendar: calendar
        )
        return List {
            if !dues.isEmpty {
                Section("Coming Up") {
                    ForEach(dues, id: \.owner) { status in
                        dueRow(status, today: today)
                    }
                }
            }
            group("Credit Cards", kind: .creditCard, sheet: sheet)
            group("Pay Later", kind: .payLater, sheet: sheet)
            group("Loans", kind: .loan, sheet: sheet)
            if !sheet.owedBalances.isEmpty {
                Section {
                    LabeledContent("Total You Owe") {
                        MoneyText(sheet.totalOwed)
                            .foregroundStyle(.primary)
                    }
                    .fontWeight(.semibold)
                } footer: {
                    Text(BillsCopy.totalOwedFooter)
                }
            }
            let archived = sheet.archivedBalances.filter { $0.account.kind.isOwed }
            if !archived.isEmpty {
                Section("Archived") {
                    ForEach(archived) { balance in
                        NavigationLink(value: LedgerRoute.account(balance.id)) {
                            OwedAccountRow(balance: balance)
                        }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    @ViewBuilder
    private func dueRow(_ status: DueStatus, today: CalendarDay) -> some View {
        switch status.owner {
        case .account(let id):
            if let account = accounts.first(where: { $0.id == id }) {
                NavigationLink(value: LedgerRoute.account(id)) {
                    DueStatusRow(status: status, name: account.name, systemImage: account.kind.systemImage, today: today, calendar: calendar)
                }
            }
        case .bill(let id):
            if let bill = bills.first(where: { $0.id == id }) {
                DueStatusRow(status: status, name: bill.name, systemImage: bill.category?.symbolName ?? "doc.text", today: today, calendar: calendar)
            }
        }
    }

    @ViewBuilder
    private func group(_ title: String, kind: AccountKind, sheet: BalanceSheet) -> some View {
        let balances = sheet.owedBalances.filter { $0.account.kind == kind }
        if !balances.isEmpty {
            Section(title) {
                ForEach(balances) { balance in
                    NavigationLink(value: LedgerRoute.account(balance.id)) {
                        OwedAccountRow(balance: balance, available: available(for: balance))
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Bills Yet", systemImage: "calendar")
        } description: {
            Text("Add your credit cards, pay later accounts, and loans to see what you owe and when it's due.")
        } actions: {
            Button {
                adding = .creditCard
            } label: {
                ContrastingButtonTitle("Add Credit Card")
            }
            .buttonStyle(.borderedProminent)
            Button("Add Pay Later") {
                adding = .payLater
            }
        }
    }

    private var addMenu: some View {
        Menu {
            Button("Credit Card", systemImage: AccountKind.creditCard.systemImage) {
                adding = .creditCard
            }
            Button("Pay Later", systemImage: AccountKind.payLater.systemImage) {
                adding = .payLater
            }
        } label: {
            Label("Add", systemImage: "plus")
        }
    }

    // MARK: Helpers

    private func available(for balance: AccountBalance) -> Money? {
        let limit = accounts.first { $0.id == balance.id }?.creditLimitMinor
        return DueCalculator.availableCredit(limitMinor: limit, balance: balance)
    }

    private func hasArchived(_ sheet: BalanceSheet) -> Bool {
        sheet.archivedBalances.contains { $0.account.kind.isOwed }
    }
}

#Preview("Sample Data") {
    NavigationStack {
        BillsView()
            .ledgerRouteDestinations()
    }
    .ledgerPreview()
}

#Preview("Empty") {
    NavigationStack {
        BillsView()
            .ledgerRouteDestinations()
    }
    .ledgerPreview(sampleData: false)
}
