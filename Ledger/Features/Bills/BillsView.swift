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
    @State private var isAddingLoan = false
    @State private var isAddingBill = false

    var body: some View {
        let sheet = LedgerService.balanceSheet(accounts: accounts, transactions: transactions)
        let today = CalendarDay(containing: now, calendar: calendar)
        Group {
            if sheet.owedBalances.isEmpty && bills.isEmpty && !hasArchived(sheet) {
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
        .sheet(isPresented: $isAddingLoan) {
            LoanEditorView()
        }
        .sheet(isPresented: $isAddingBill) {
            BillEditorView()
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
            let activeBills = bills.filter { !$0.isArchived }
            if !activeBills.isEmpty {
                Section("Bills") {
                    ForEach(activeBills) { bill in
                        NavigationLink(value: LedgerRoute.bill(bill.id)) {
                            BillRow(bill: bill)
                        }
                    }
                }
            }
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
            let archivedBills = bills.filter(\.isArchived)
            if !archived.isEmpty || !archivedBills.isEmpty {
                Section("Archived") {
                    ForEach(archived) { balance in
                        NavigationLink(value: LedgerRoute.account(balance.id)) {
                            OwedAccountRow(balance: balance)
                        }
                    }
                    ForEach(archivedBills) { bill in
                        NavigationLink(value: LedgerRoute.bill(bill.id)) {
                            BillRow(bill: bill)
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
                NavigationLink(value: LedgerRoute.bill(id)) {
                    DueStatusRow(status: status, name: bill.name, systemImage: bill.category?.symbolName ?? "doc.text", today: today, calendar: calendar)
                }
            }
        }
    }

    @ViewBuilder
    private func group(_ title: String, kind: AccountKind, sheet: BalanceSheet) -> some View {
        let balances = sheet.owedBalances.filter { $0.account.kind == kind }
        if !balances.isEmpty {
            let movements = transactions.compactMap(Movement.init)
            let today = CalendarDay(containing: now, calendar: calendar)
            Section(title) {
                ForEach(balances) { balance in
                    NavigationLink(value: LedgerRoute.account(balance.id)) {
                        OwedAccountRow(
                            balance: balance,
                            available: available(for: balance, movements: movements, today: today),
                            detail: loanProgress(for: balance, movements: movements, today: today)
                        )
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        ContentUnavailableView {
            Label("No Bills Yet", systemImage: "calendar")
        } description: {
            Text("Add your credit cards, pay later accounts, loans, and regular bills to see what you owe and when it's due.")
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
            Button("Add Loan") {
                isAddingLoan = true
            }
            Button("Add Bill") {
                isAddingBill = true
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
            Button("Loan", systemImage: AccountKind.loan.systemImage) {
                isAddingLoan = true
            }
            Divider()
            Button("Bill", systemImage: "doc.text") {
                isAddingBill = true
            }
        } label: {
            Label("Add", systemImage: "plus")
        }
    }

    // MARK: Helpers

    /// What's left of an account's limit, leaving out unpaid split fees where they don't use it.
    private func available(for balance: AccountBalance, movements: [Movement], today: CalendarDay) -> Money? {
        guard let account = accounts.first(where: { $0.id == balance.id }) else { return nil }
        return DueCalculator.limitStatus(
            limitMinor: account.creditLimitMinor,
            balance: balance,
            input: dueInput(for: account, balance: balance, movements: movements),
            feesUseLimit: account.feesUseLimit,
            today: today,
            calendar: calendar
        )?.available
    }

    private func dueInput(for account: Account, balance: AccountBalance, movements: [Movement]) -> OwedDueInput? {
        LedgerService.owedDueInput(for: account, balance: balance, movements: movements, plans: plans, overrides: overrides)
    }

    /// A loan's progress, such as "6 of 12 paid", from its first plan.
    private func loanProgress(for balance: AccountBalance, movements: [Movement], today: CalendarDay) -> String? {
        guard
            balance.account.kind == .loan,
            let account = accounts.first(where: { $0.id == balance.id }),
            let plan = plans.filter({ $0.account?.id == balance.id }).min(by: { $0.createdAt < $1.createdAt }),
            let snapshot = PlanSnapshot(plan),
            let input = dueInput(for: account, balance: balance, movements: movements)
        else { return nil }
        return PlanCopy.progress(paid: DueCalculator.monthsPaid(snapshot, input, today: today, calendar: calendar), months: plan.months)
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

/// A regular bill in a list: its category symbol, name, and due day, with the monthly amount.
private struct BillRow: View {
    let bill: Bill

    @Environment(\.moneyFormatter) private var formatter

    var body: some View {
        AdaptiveRowLayout {
            HStack(spacing: 12) {
                SymbolBadge(systemName: bill.category?.symbolName ?? "doc.text", tint: bill.isArchived ? .secondary : .accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text(bill.name)
                    Text("Due \(BillsCopy.dayPhrase(bill.dueDay))")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }
        } trailing: {
            Text(bill.amount.map { formatter.string($0) } ?? "Varies")
                .font(.body.weight(.semibold))
                .foregroundStyle(bill.amount == nil ? .secondary : .primary)
                .monospacedDigit()
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(bill.name), due \(BillsCopy.dayPhrase(bill.dueDay)), \(bill.amount.map { formatter.string($0, alwaysShowCentavos: true) } ?? "amount varies")")
    }
}
