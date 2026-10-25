import SwiftData
import SwiftUI

/// One credit card, pay later account, or loan: what it owes, its current due, its limit and
/// billing days, its entries, and actions. Looks the account up by ID, so it copes with the
/// account being deleted elsewhere.
struct OwedAccountDetailView: View {
    let accountID: UUID

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.calendar) private var calendar
    @Environment(\.moneyFormatter) private var formatter
    @Environment(AppRouter.self) private var router
    @Query private var matches: [Account]
    @Query(sort: LedgerService.newestFirst) private var transactions: [LedgerTransaction]
    @Query private var plans: [PaymentPlan]
    @Query private var overrides: [DueOverride]
    @State private var now = Date.now
    @State private var isEditing = false
    @State private var isPaying = false
    @State private var isUpdatingOwed = false
    @State private var isConfirmingArchive = false
    @State private var isConfirmingDelete = false
    @State private var didDelete = false
    @State private var isAddingPlan = false
    @State private var planToDelete: PaymentPlan?
    @State private var alert: LedgerAlert?

    init(accountID: UUID) {
        self.accountID = accountID
        _matches = Query(filter: #Predicate<Account> { $0.id == accountID })
    }

    var body: some View {
        if let account = matches.first,
           let balance = LedgerService.balanceSheet(accounts: [account], transactions: transactions).balance(for: account.id) {
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
        let history = transactions.filter { $0.account?.id == accountID || $0.destinationAccount?.id == accountID }
        let today = CalendarDay(containing: now, calendar: calendar)
        let input = dueInput(account: account, balance: balance)
        let status = input.map { DueCalculator.status($0, today: today, calendar: calendar) }
        return List {
            Section {
                header(balance)
            }
            if let status {
                dueSection(status, account: account, today: today)
            }
            if account.kind == .payLater || account.kind == .loan {
                plansSection(account: account, input: input, today: today)
            }
            limitSection(account: account, balance: balance)
            if let schedule = account.dueSchedule, schedule.statementDay != nil {
                periodSection(schedule: schedule, history: history, today: today)
            }
            billingSection(account)
            transactionsSection(history)
            actionsSection(account: account, balance: balance, hasTransactions: !history.isEmpty, left: status?.left)
        }
        .listStyle(.insetGrouped)
        .navigationTitle(account.name)
        .toolbar {
            if account.kind != .loan {
                ToolbarItem(placement: .primaryAction) {
                    Button("Edit") { isEditing = true }
                }
            }
        }
        .refreshingCurrentDate($now)
        .sheet(isPresented: $isEditing) {
            OwedAccountEditorView(kind: account.kind, account: account)
        }
        .sheet(isPresented: $isPaying) {
            PayDueView(accountID: accountID, suggestedAmount: status?.left?.amount)
        }
        .sheet(isPresented: $isUpdatingOwed) {
            UpdateOwedView(account: account)
        }
        .sheet(isPresented: $isAddingPlan) {
            ExistingPlanView(account: account)
        }
        .confirmationDialog(
            "Delete \(planToDelete?.title ?? "Plan")?",
            isPresented: isConfirmingPlanDelete,
            titleVisibility: .visible,
            presenting: planToDelete
        ) { plan in
            Button("Delete Plan", role: .destructive) {
                deletePlan(plan)
            }
            Button("Cancel", role: .cancel) {}
        } message: { plan in
            Text(plan.purchaseID == nil
                ? "Ledger stops splitting its payments across dues. What \(account.name) owes doesn't change."
                : "Its purchase and fees are deleted too, so what \(account.name) owes goes down by its total.")
        }
        .ledgerAlert($alert)
    }

    // MARK: Sections

    private func header(_ balance: AccountBalance) -> some View {
        VStack(spacing: 8) {
            SymbolBadge(
                systemName: balance.account.kind.systemImage,
                tint: balance.account.isArchived ? .secondary : .accentColor,
                size: 52
            )
            Text(balance.account.isArchived ? "\(balance.account.kind.title) · Archived" : balance.account.kind.title)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let owed = balance.owed {
                MoneyText(owed.magnitude)
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .padding(.top, 4)
                Text(BillsCopy.owedCaption(owed))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Text("What it owes isn't set")
                    .font(.headline)
                    .padding(.top, 4)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(headerAccessibilityText(balance))
    }

    private func dueSection(_ status: DueStatus, account: Account, today: CalendarDay) -> some View {
        Section {
            LabeledContent {
                Text(DueStatusCopy.amountText(status, formatter: formatter))
                    .monospacedDigit()
            } label: {
                HStack(spacing: 4) {
                    if status.isOverdue {
                        Image(systemName: "exclamationmark.circle.fill")
                    }
                    Text(DueStatusCopy.dateText(status, today: today, calendar: calendar))
                }
                .foregroundStyle(status.isOverdue ? .red : .primary)
            }
        } header: {
            Text(status.isOverdue ? "Overdue" : "Current Due")
        } footer: {
            if !status.isStatementClosed, let close = account.dueSchedule?.statementClose(for: status.cycle) {
                Text("Purchases until \(DueStatusCopy.shortDate(close, calendar: calendar)) are added to this due.")
            } else if status.dueDate != status.originalDueDate {
                Text("Moved from \(DueStatusCopy.shortDate(status.originalDueDate, calendar: calendar)) for this month only.")
            }
        }
    }

    private func plansSection(account: Account, input: OwedDueInput?, today: CalendarDay) -> some View {
        let accountPlans = plans.filter { $0.account?.id == accountID }.sorted { $0.createdAt < $1.createdAt }
        return Section {
            ForEach(accountPlans) { plan in
                PlanRow(plan: plan, monthsPaid: monthsPaid(plan, input: input, today: today))
                    .swipeActions {
                        Button("Delete", systemImage: "trash", role: .destructive) {
                            planToDelete = plan
                        }
                    }
            }
            if account.kind == .payLater && !account.isArchived {
                Button("Add a Split You're Already Paying", systemImage: "plus.circle") {
                    isAddingPlan = true
                }
            }
        } header: {
            Text(account.kind == .loan ? "Payments" : "Splits")
        } footer: {
            if account.kind == .payLater {
                Text("Split a new purchase when you log it on this account.")
            }
        }
    }

    @ViewBuilder
    private func limitSection(account: Account, balance: AccountBalance) -> some View {
        if let limit = account.creditLimit {
            Section {
                LabeledContent(BillsCopy.limitTitle(for: account.kind)) { MoneyText(limit) }
                if let available = DueCalculator.availableCredit(limitMinor: account.creditLimitMinor, balance: balance) {
                    LabeledContent("Available") { MoneyText(available) }
                }
            }
        }
    }

    private func periodSection(schedule: DueSchedule, history: [LedgerTransaction], today: CalendarDay) -> some View {
        let open = schedule.billingCycle(for: today)
        let lastClose = schedule.statementClose(for: open.adding(months: -1))
        let spent = history.reduce(Decimal.zero) { sum, entry in
            guard entry.kind == .expense, entry.account?.id == accountID,
                  let lastClose, CalendarDay(containing: entry.occurredAt, calendar: calendar) > lastClose
            else { return sum }
            return sum + entry.amount.amount
        }
        return Section {
            LabeledContent("Spent This Period") { MoneyText(Money(spent)) }
        } footer: {
            if let lastClose, let nextClose = schedule.statementClose(for: open) {
                Text("Since the statement on \(DueStatusCopy.shortDate(lastClose, calendar: calendar)). The next one closes \(DueStatusCopy.shortDate(nextClose, calendar: calendar)).")
            }
        }
    }

    private func billingSection(_ account: Account) -> some View {
        Section("Billing") {
            if let statementDay = account.statementDay {
                LabeledContent("Statement Closes", value: BillsCopy.dayTitle(statementDay))
            }
            if let dueDay = account.dueDay {
                LabeledContent("Payment Due", value: BillsCopy.dayTitle(dueDay))
            }
            if let cashback = account.cashbackRate {
                LabeledContent("Cashback", value: "\(cashback.percent.formatted())% back")
            }
        }
    }

    private func transactionsSection(_ history: [LedgerTransaction]) -> some View {
        let items = HistoryItem.items(from: history)
        return Section("Transactions") {
            if items.isEmpty {
                Text("No transactions yet")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(items.prefix(AccountDetailView.recentTransactionLimit)) { item in
                    HistoryItemLink(item: item, showsDate: true, accountID: accountID)
                }
                if items.count > AccountDetailView.recentTransactionLimit {
                    NavigationLink {
                        AccountTransactionsView(accountID: accountID)
                    } label: {
                        Text("Show All Transactions")
                    }
                }
            }
        }
    }

    private func actionsSection(account: Account, balance: AccountBalance, hasTransactions: Bool, left: Money?) -> some View {
        Section {
            if account.isArchived {
                Button("Unarchive", systemImage: "tray.and.arrow.up") {
                    perform(on: account) { try $0.unarchiveAccount(account) }
                }
            } else {
                Button("Pay", systemImage: "arrow.left.arrow.right") {
                    isPaying = true
                }
                Button("Update What You Owe", systemImage: "plus.forwardslash.minus") {
                    isUpdatingOwed = true
                }
                if account.kind != .loan {
                    Button("Add Purchase", systemImage: "plus.circle") {
                        router.addTransaction(.expense, accountID: accountID)
                    }
                }
                Button("Archive", systemImage: "archivebox") {
                    isConfirmingArchive = true
                }
                .confirmationDialog("Archive \(account.name)?", isPresented: $isConfirmingArchive, titleVisibility: .visible) {
                    Button("Archive") {
                        perform(on: account) { try $0.archiveAccount(account) }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("Archived accounts are hidden when logging and leave Coming Up and Total You Owe. Their history stays.")
                }
            }
            if !hasTransactions {
                Button("Delete", systemImage: "trash", role: .destructive) {
                    isConfirmingDelete = true
                }
                .confirmationDialog("Delete \(account.name)?", isPresented: $isConfirmingDelete, titleVisibility: .visible) {
                    Button("Delete", role: .destructive) {
                        if perform(on: account, { try $0.deleteAccount(account) }) {
                            didDelete = true
                            dismiss()
                        }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This can't be undone.")
                }
            }
        } footer: {
            if !account.isArchived {
                Text(BillsCopy.paymentFooter)
            }
        }
    }

    // MARK: Helpers

    private func dueInput(account: Account, balance: AccountBalance) -> OwedDueInput? {
        LedgerService.owedDueInput(
            for: account,
            balance: balance,
            movements: transactions.compactMap(Movement.init),
            plans: plans,
            overrides: overrides
        )
    }

    private func monthsPaid(_ plan: PaymentPlan, input: OwedDueInput?, today: CalendarDay) -> Int {
        guard let input, let snapshot = PlanSnapshot(plan) else { return plan.paidAtStart }
        return DueCalculator.monthsPaid(snapshot, input, today: today, calendar: calendar)
    }

    private var isConfirmingPlanDelete: Binding<Bool> {
        Binding(get: { planToDelete != nil }, set: { if !$0 { planToDelete = nil } })
    }

    private func deletePlan(_ plan: PaymentPlan) {
        do {
            try LedgerService(context: modelContext).deletePlan(plan)
        } catch {
            alert = LedgerAlert(error)
        }
        planToDelete = nil
    }

    private func headerAccessibilityText(_ balance: AccountBalance) -> String {
        var parts = [balance.account.kind.title]
        if let owed = balance.owed {
            parts.append("\(BillsCopy.owedCaption(owed)) \(formatter.string(owed.magnitude, alwaysShowCentavos: true))")
        }
        if balance.account.isArchived { parts.append("Archived") }
        return parts.joined(separator: ", ")
    }

    /// Runs a ledger change, reporting failure in an alert. Returns whether it succeeded.
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
