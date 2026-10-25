import Foundation
import SwiftData
import SwiftUI

/// Overview tab: total liquid balance, quick logging, income and expenses for a chosen period,
/// account balances, and the latest transactions. Reads everything with `@Query`, so it updates
/// as soon as anything is logged, including from Shortcuts or the Action Button.
struct DashboardView: View {
    private static let recentLimit = 5

    @Environment(AppRouter.self) private var router
    @AppStorage(AppPreferences.Keys.dashboardPeriod) private var period: ReportingPeriod = .thisMonth

    @Query(sort: [SortDescriptor(\Account.sortOrder), SortDescriptor(\Account.createdAt)])
    private var accounts: [Account]
    @Query(sort: LedgerService.newestFirst)
    private var transactions: [LedgerTransaction]
    @Query private var plans: [PaymentPlan]
    @Query private var bills: [Bill]
    @Query private var overrides: [DueOverride]
    @Environment(\.calendar) private var calendar
    @Environment(\.moneyFormatter) private var formatter

    /// The moment the current period is measured from; kept current by `refreshingCurrentDate`.
    @State private var now = Date.now
    @State private var isSettingBalances = false

    var body: some View {
        let sheet = LedgerService.balanceSheet(accounts: accounts, transactions: transactions)
        let activeBalances = sheet.activeBalances
        let isFirstRun = transactions.isEmpty && !accounts.contains(where: \.hasOpeningBalance)

        List {
            if isFirstRun {
                Section {
                    WelcomeCard(
                        canLog: TransactionLogging.canLog(.expense, activeAccountCount: activeBalances.count),
                        setOpeningBalances: { isSettingBalances = true },
                        logExpense: { router.addTransaction(.expense) }
                    )
                }
            } else {
                Section {
                    LiquidTotalSummary(
                        liquidTotal: sheet.liquidTotal,
                        hasActiveAccounts: !activeBalances.isEmpty,
                        showAccounts: activeBalances.isEmpty ? showAccounts : { isSettingBalances = true }
                    )
                }
                Section {
                    QuickAddButtons(activeAccountCount: activeBalances.count)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
                periodSection
                billsSection(sheet)
            }

            accountsSection(sheet.moneyBalances)

            if !isFirstRun {
                recentSection
            }
        }
        .listStyle(.insetGrouped)
        .listSectionSpacing(.compact)
        .navigationTitle("Overview")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                AddTransactionMenu(activeAccountCount: activeBalances.count)
            }
        }
        .refreshingCurrentDate($now)
        .sheet(isPresented: $isSettingBalances) {
            NavigationStack {
                OnboardingBalancesStep(
                    skipTitle: "Cancel",
                    onSkip: { isSettingBalances = false },
                    onSaved: { isSettingBalances = false }
                )
            }
        }
    }

    // MARK: Sections

    private var periodSection: some View {
        let summary = LedgerService.periodSummary(transactions: transactions, in: period.interval(containing: now))
        return Section {
            PeriodSummaryRows(summary: summary)
        } header: {
            PeriodHeader(period: $period, interval: summary.interval)
        }
    }

    /// What's owed and the next due, when there are owed accounts or bills.
    @ViewBuilder
    private func billsSection(_ sheet: BalanceSheet) -> some View {
        if !sheet.owedBalances.isEmpty || bills.contains(where: { !$0.isArchived }) {
            let today = CalendarDay(containing: now, calendar: calendar)
            let dues = LedgerService.comingUp(
                accounts: accounts, transactions: transactions, plans: plans, bills: bills,
                overrides: overrides, today: today, calendar: calendar
            )
            Section {
                Button {
                    router.selectedTab = .bills
                } label: {
                    VStack(spacing: 10) {
                        if !sheet.owedBalances.isEmpty {
                            LabeledContent("You Owe") {
                                MoneyText(sheet.totalOwed)
                                    .foregroundStyle(.primary)
                            }
                        }
                        if let next = dues.first(where: { !$0.isPaid }) {
                            LabeledContent {
                                Text(DueStatusCopy.amountText(next, formatter: formatter))
                                    .monospacedDigit()
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("Next Due")
                                    Text("\(dueName(next)) · \(DueStatusCopy.dateText(next, today: today, calendar: calendar))")
                                        .font(.subheadline)
                                        .foregroundStyle(next.isOverdue ? .red : .secondary)
                                }
                            }
                        } else {
                            LabeledContent("Next Due", value: "All paid")
                        }
                    }
                }
                .tint(.primary)
            } header: {
                Text("Bills")
            }
        }
    }

    private func dueName(_ status: DueStatus) -> String {
        switch status.owner {
        case .account(let id): accounts.first { $0.id == id }?.name ?? ""
        case .bill(let id): bills.first { $0.id == id }?.name ?? ""
        }
    }

    private func accountsSection(_ balances: [AccountBalance]) -> some View {
        Section("Accounts") {
            if balances.isEmpty {
                HStack {
                    Text("No active accounts")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Add Account", action: showAccounts)
                        .buttonStyle(.borderless)
                }
            } else {
                ForEach(balances) { balance in
                    NavigationLink(value: LedgerRoute.account(balance.id)) {
                        AccountBalanceRow(balance: balance)
                    }
                }
            }
        }
    }

    private var recentSection: some View {
        Section {
            if transactions.isEmpty {
                Text("Nothing logged yet. Use Log Expense or the Action Button.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                ForEach(HistoryItem.items(from: transactions).prefix(Self.recentLimit)) { item in
                    HistoryItemLink(item: item, showsDate: true)
                }
            }
        } header: {
            HStack(alignment: .firstTextBaseline) {
                Text("Recent")
                Spacer()
                if !transactions.isEmpty {
                    Button("See All") {
                        router.selectedTab = .transactions
                    }
                    .accessibilityLabel("See All Transactions")
                }
            }
            .textCase(nil)
        }
    }

    // MARK: Actions

    private func showAccounts() {
        router.selectedTab = .accounts
    }
}

#Preview("Overview") {
    NavigationStack {
        DashboardView()
            .ledgerRouteDestinations()
    }
    .ledgerPreview()
}

#Preview("Overview – First Run") {
    NavigationStack {
        DashboardView()
            .ledgerRouteDestinations()
    }
    .ledgerPreview(sampleData: false)
}
