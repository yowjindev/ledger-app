#if DEBUG
import Foundation
import SwiftData
import SwiftUI
import os

/// Illustrative records for SwiftUI previews and debug screenshots. Loaded only into in-memory
/// stores and only in Debug builds; never written to the user's data.
@MainActor
enum SampleData {
    static func load(into context: ModelContext, now: Date = .now) {
        let ledger = LedgerService(context: context, clock: { now })
        do {
            let accounts = Dictionary(try ledger.accounts().map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
            let expenses = Dictionary(try ledger.categories(kind: .expense).map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })
            let income = Dictionary(try ledger.categories(kind: .income).map { ($0.name, $0) }, uniquingKeysWith: { first, _ in first })

            let openingBalances: [(String, Decimal)] = [
                ("GCash", 4_230), ("GoTyme", 8_500), ("Maya", 1_250), ("PNB", 12_800), ("Wallet", 1_000),
            ]
            for (name, amount) in openingBalances {
                if let account = accounts[name] { try ledger.setOpeningBalance(amount, for: account) }
            }

            func hoursAgo(_ hours: Double) -> Date { now.addingTimeInterval(-hours * 3_600) }
            let entries: [(TransactionKind, Decimal, String, String, Double)] = [
                (.expense, 250, "GCash", "Food", 1),
                (.expense, 13, "Wallet", "Jeep", 3),
                (.expense, 99, "GCash", "Mobile Data", 26),
                (.transfer, 500, "PNB", "GCash", 50),
                (.expense, 1_850, "PNB", "Bills", 75),
                (.expense, 150, "Wallet", "Haircut", 120),
                (.income, 25_000, "PNB", "Salary", 150),
                (.expense, 642.75, "GoTyme", "Marketing", 170),
            ]
            for (kind, amount, accountName, other, age) in entries {
                guard let account = accounts[accountName] else { continue }
                switch kind {
                case .expense:
                    if let category = expenses[other] {
                        try ledger.recordExpense(amount: amount, accountID: account.id, categoryID: category.id, occurredAt: hoursAgo(age))
                    }
                case .income:
                    if let source = income[other] {
                        try ledger.recordIncome(amount: amount, accountID: account.id, sourceID: source.id, occurredAt: hoursAgo(age))
                    }
                case .transfer:
                    if let destination = accounts[other] {
                        try ledger.recordTransfer(amount: amount, fromAccountID: account.id, toAccountID: destination.id, occurredAt: hoursAgo(age))
                    }
                case .adjustment:
                    break
                }
            }
            // PNB earns interest from three days ago, so its daily interest rows appear at once.
            if let pnb = accounts["PNB"] {
                let threeDaysAgo = LedgerService(context: context, clock: { hoursAgo(72) })
                try threeDaysAgo.setInterest(
                    InterestTerms(annualRate: Rate(partsPerMillion: 32_500), taxRate: InterestTerms.defaultTaxRate),
                    for: pnb
                )
                try ledger.postDueInterest()
            }
            try loadOwedAccounts(ledger: ledger, existing: accounts, expenses: expenses, hoursAgo: hoursAgo)
            try loadBills(ledger: ledger, expenses: expenses, payFrom: accounts["PNB"])
        } catch {
            Log.persistence.error("Could not load sample data: \(String(describing: error), privacy: .private)")
        }
    }

    /// A credit card with cashback and two purchases, a loan partway through, and a pay later
    /// account with a split purchase. Skips any whose name is already taken.
    private static func loadOwedAccounts(
        ledger: LedgerService,
        existing: [String: Account],
        expenses: [String: LedgerCategory],
        hoursAgo: (Double) -> Date
    ) throws {
        if existing["Visa card"] == nil {
            let card = try ledger.createOwedAccount(
                name: "Visa card",
                kind: .creditCard,
                terms: OwedTerms(statementDay: 5, dueDay: 25, creditLimit: 20_000, cashbackPercent: 1),
                owedNow: 1_500,
                stillDue: ledger.awaitingDue(for: DueSchedule(statementDay: 5, dueDay: 25)).map { _ in 1_200 }
            )
            for (amount, category, age) in [(Decimal(650), "Food", 4.0), (Decimal(250), "Shopping", 30.0)] {
                if let category = expenses[category] {
                    try ledger.recordExpense(amount: amount, accountID: card.id, categoryID: category.id, occurredAt: hoursAgo(age))
                }
            }
        }
        if existing["Phone loan"] == nil {
            let nextDue = CalendarDay(containing: hoursAgo(-24 * 10), calendar: ledger.calendar)
            try ledger.createLoan(
                name: "Phone loan",
                terms: PlanTerms(title: "Phone", monthly: 2_400, last: nil, months: 12, paidAtStart: 6, nextDue: nextDue),
                purchase: nil
            )
        }
        if existing["PayLater"] == nil {
            let payLater = try ledger.createOwedAccount(
                name: "PayLater",
                kind: .payLater,
                terms: OwedTerms(statementDay: 31, dueDay: 5, creditLimit: 8_000, splitFeePercent: 5),
                owedNow: 1_500,
                stillDue: ledger.awaitingDue(for: DueSchedule(statementDay: 31, dueDay: 5)).map { _ in 1_500 }
            )
            if let shopping = expenses["Shopping"] {
                try ledger.recordSplitPurchase(SplitPurchase(
                    amount: 1_200, accountID: payLater.id, categoryID: shopping.id, occurredAt: hoursAgo(48),
                    note: "Earbuds", months: 3, monthly: 460, last: nil
                ))
            }
        }
    }

    /// Rent and internet at fixed amounts, internet due today, and electricity whose amount
    /// varies. Skips any whose name is already taken.
    private static func loadBills(ledger: LedgerService, expenses: [String: LedgerCategory], payFrom: Account?) throws {
        let existing = Set(try ledger.bills(includeArchived: true).map(\.name))
        if !existing.contains("Rent"), let bills = expenses["Bills"] {
            try ledger.createBill(BillTerms(
                name: "Rent", categoryID: bills.id, dueDay: 25, amount: 8_000, arrivesDay: nil, payFromAccountID: payFrom?.id
            ))
        }
        // Due today, so the due reminder Live Activity shows in previews and screenshots.
        if !existing.contains("Internet"), let bills = expenses["Bills"] {
            try ledger.createBill(BillTerms(
                name: "Internet", categoryID: bills.id, dueDay: ledger.today.day, amount: 1_699, arrivesDay: nil, payFromAccountID: payFrom?.id
            ))
        }
        if !existing.contains("Electricity"), let bills = expenses["Bills"] {
            try ledger.createBill(BillTerms(
                name: "Electricity", categoryID: bills.id, dueDay: 30, amount: nil, arrivesDay: 19, payFromAccountID: nil
            ))
        }
    }

    /// An in-memory container with the seed data, plus sample records when requested.
    static func previewContainer(withSampleData: Bool = true) -> ModelContainer {
        do {
            let container = try LedgerStore.makeContainer(storage: .inMemory)
            LedgerBootstrapper(context: container.mainContext, marker: nil).seedIfNeeded(with: .personalDefault)
            if withSampleData { load(into: container.mainContext) }
            return container
        } catch {
            fatalError("Could not create a preview container: \(error)")
        }
    }
}

extension View {
    /// Supplies what Ledger's views expect from their environment, for SwiftUI previews.
    func ledgerPreview(sampleData: Bool = true) -> some View {
        modelContainer(SampleData.previewContainer(withSampleData: sampleData))
            .environment(AppRouter())
            .environment(\.moneyFormatter, MoneyFormatter())
    }
}
#else
import SwiftUI

extension View {
    /// Previews only run in Debug builds; Release builds compile `#Preview` blocks without sample data.
    func ledgerPreview(sampleData: Bool = true) -> some View {
        self
    }
}
#endif
