import Foundation
import SwiftData
import XCTest
@testable import Ledger

/// Ledger rules beyond the required cases: opening balances, references, names, duplicates,
/// periods, seeding, and forward compatibility.
@MainActor
final class LedgerRulesTests: XCTestCase {
    func testUnsetOpeningBalanceIsNeverAssumedZero() throws {
        let h = try LedgerHarness()
        let gcash = try h.account("GCash", opening: nil, kind: .eWallet)
        let pnb = try h.account("PNB", opening: 12_800)
        let food = try h.expenseCategory("Food")
        try h.ledger.recordExpense(amount: 250, accountID: gcash.id, categoryID: food.id)

        let balance = try XCTUnwrap(try h.ledger.balance(of: gcash))
        XCTAssertNil(balance.openingBalance)
        XCTAssertNil(balance.currentBalance, "Unknown opening balance means unknown current balance")
        XCTAssertEqual(balance.netActivity.amount, -250)

        var total = try h.liquidTotal()
        XCTAssertFalse(total.isComplete)
        XCTAssertEqual(total.total.amount, 12_800)
        XCTAssertEqual(total.includedAccountIDs, [pnb.id])
        XCTAssertEqual(total.accountsMissingOpeningBalance.map(\.name), ["GCash"])

        try h.ledger.setOpeningBalance(0, for: gcash)
        XCTAssertEqual(try h.balance(gcash), -250, "An explicit zero is a real opening balance")
        total = try h.liquidTotal()
        XCTAssertTrue(total.isComplete)
        XCTAssertEqual(total.total.amount, 12_550)
    }

    func testOpeningBalanceValidation() throws {
        let h = try LedgerHarness()
        assertThrowsLedgerError(.openingBalanceNegative) {
            try h.ledger.createAccount(name: "PNB", kind: .bank, openingBalance: -1)
        }
        assertThrowsLedgerError(.amountTooPrecise) {
            try h.ledger.createAccount(name: "PNB", kind: .bank, openingBalance: dec("1.005"))
        }
        let account = try h.ledger.createAccount(name: "PNB", kind: .bank, openingBalance: 0)
        XCTAssertEqual(account.openingBalanceMinor, 0)
        try h.ledger.updateAccount(account, name: "PNB", kind: .bank, openingBalance: nil)
        XCTAssertNil(account.openingBalanceMinor)
    }

    func testCategoryKindMustMatchTransactionKind() throws {
        let h = try LedgerHarness()
        let gcash = try h.account("GCash", opening: 100, kind: .eWallet)
        let food = try h.expenseCategory("Food")
        let salary = try h.incomeSource("Salary")

        assertThrowsLedgerError(.categoryKindMismatch(expected: .expense)) {
            try h.ledger.recordExpense(amount: 10, accountID: gcash.id, categoryID: salary.id)
        }
        assertThrowsLedgerError(.categoryKindMismatch(expected: .income)) {
            try h.ledger.recordIncome(amount: 10, accountID: gcash.id, sourceID: food.id)
        }
        XCTAssertEqual(try h.transactionCount(), 0)
    }

    func testMissingAndUnknownReferencesAreRejected() throws {
        let h = try LedgerHarness()
        let gcash = try h.account("GCash", opening: 100, kind: .eWallet)
        let food = try h.expenseCategory("Food")
        let now = h.clock.now

        assertThrowsLedgerError(.missingAccount) {
            try h.ledger.record(TransactionDraft(kind: .expense, amount: 10, occurredAt: now, categoryID: food.id))
        }
        assertThrowsLedgerError(.missingCategory) {
            try h.ledger.record(TransactionDraft(kind: .expense, amount: 10, occurredAt: now, accountID: gcash.id))
        }
        assertThrowsLedgerError(.missingDestinationAccount) {
            try h.ledger.record(TransactionDraft(kind: .transfer, amount: 10, occurredAt: now, accountID: gcash.id))
        }
        assertThrowsLedgerError(.accountNotFound) {
            try h.ledger.recordExpense(amount: 10, accountID: UUID(), categoryID: food.id)
        }
        assertThrowsLedgerError(.categoryNotFound) {
            try h.ledger.recordExpense(amount: 10, accountID: gcash.id, categoryID: UUID())
        }
        assertThrowsLedgerError(.accountNotFound) {
            try h.ledger.recordTransfer(amount: 10, fromAccountID: gcash.id, toAccountID: UUID())
        }
        XCTAssertEqual(try h.transactionCount(), 0)
    }

    func testEditingCannotIntroduceArchivedReferences() throws {
        let h = try LedgerHarness()
        let gcash = try h.account("GCash", opening: 100, kind: .eWallet)
        let maya = try h.account("Maya", opening: 100, kind: .eWallet)
        let food = try h.expenseCategory("Food")
        let expense = try h.ledger.recordExpense(amount: 10, accountID: gcash.id, categoryID: food.id)
        try h.ledger.archiveAccount(maya)

        var draft = try XCTUnwrap(TransactionDraft(expense))
        draft.accountID = maya.id
        assertThrowsLedgerError(.accountArchived(name: "Maya")) { try h.ledger.update(expense, with: draft) }
        XCTAssertEqual(expense.account?.id, gcash.id)
    }

    func testDeletedTransactionCannotBeEditedOrDeletedAgain() throws {
        let h = try LedgerHarness()
        let gcash = try h.account("GCash", opening: 100, kind: .eWallet)
        let food = try h.expenseCategory("Food")
        let expense = try h.ledger.recordExpense(amount: 10, accountID: gcash.id, categoryID: food.id)
        let draft = try XCTUnwrap(TransactionDraft(expense))
        try h.ledger.delete(expense)

        assertThrowsLedgerError(.transactionNotFound) { try h.ledger.update(expense, with: draft) }
        assertThrowsLedgerError(.transactionNotFound) { try h.ledger.delete(expense) }
        XCTAssertEqual(try h.balance(gcash), 100)
    }

    func testNamesAreValidated() throws {
        let h = try LedgerHarness()
        try h.account("GCash", opening: nil, kind: .eWallet)
        assertThrowsLedgerError(.emptyName) { try h.ledger.createAccount(name: "   ", kind: .bank, openingBalance: nil) }
        assertThrowsLedgerError(.duplicateName("gcash")) { try h.ledger.createAccount(name: " gcash ", kind: .bank, openingBalance: nil) }
        assertThrowsLedgerError(.nameTooLong(limit: LedgerService.nameLengthLimit)) {
            try h.ledger.createAccount(name: String(repeating: "x", count: LedgerService.nameLengthLimit + 1), kind: .bank, openingBalance: nil)
        }

        try h.expenseCategory("Other")
        XCTAssertNoThrow(try h.incomeSource("Other"), "Expense categories and income sources have separate names")
        assertThrowsLedgerError(.duplicateName("OTHER")) { try h.ledger.createCategory(name: "OTHER", kind: .expense) }
    }

    func testNotesAreTrimmedAndLimited() throws {
        let h = try LedgerHarness()
        let gcash = try h.account("GCash", opening: 100, kind: .eWallet)
        let food = try h.expenseCategory("Food")

        let trimmed = try h.ledger.recordExpense(amount: 1, accountID: gcash.id, categoryID: food.id, note: "  lunch  ")
        XCTAssertEqual(trimmed.note, "lunch")
        let blank = try h.ledger.recordExpense(amount: 1, accountID: gcash.id, categoryID: food.id, note: "   ")
        XCTAssertNil(blank.note)
        assertThrowsLedgerError(.textTooLong(limit: LedgerService.noteLengthLimit)) {
            try h.ledger.recordExpense(amount: 1, accountID: gcash.id, categoryID: food.id, note: String(repeating: "a", count: 501))
        }
    }

    func testUnusedAccountsAndCategoriesCanBeDeleted() throws {
        let h = try LedgerHarness()
        let maya = try h.account("Maya", opening: nil, kind: .eWallet)
        let gym = try h.expenseCategory("Gym")
        try h.ledger.deleteAccount(maya)
        try h.ledger.deleteCategory(gym)
        XCTAssertTrue(try h.ledger.accounts(includeArchived: true).isEmpty)
        XCTAssertTrue(try h.ledger.categories(kind: .expense, includeArchived: true).isEmpty)
    }

    func testRecentDuplicateIsDetectedOnlyWithinTheWindow() throws {
        let h = try LedgerHarness()
        let gcash = try h.account("GCash", opening: 1_000, kind: .eWallet)
        let food = try h.expenseCategory("Food")
        let transport = try h.expenseCategory("Transport")
        let saved = try h.ledger.recordExpense(amount: 250, accountID: gcash.id, categoryID: food.id)
        let same = TransactionDraft.expense(amount: 250, accountID: gcash.id, categoryID: food.id, occurredAt: h.clock.now)

        h.clock.advance(by: 30)
        XCTAssertEqual(try h.ledger.recentDuplicate(of: same)?.id, saved.id)
        XCTAssertNil(try h.ledger.recentDuplicate(of: .expense(amount: 251, accountID: gcash.id, categoryID: food.id, occurredAt: h.clock.now)))
        XCTAssertNil(try h.ledger.recentDuplicate(of: .expense(amount: 250, accountID: gcash.id, categoryID: transport.id, occurredAt: h.clock.now)))

        h.clock.advance(by: LedgerService.possibleDuplicateWindow)
        XCTAssertNil(try h.ledger.recentDuplicate(of: same), "Old identical entries are not flagged")
    }

    func testPeriodSummaryUsesHalfOpenIntervalsAndExcludesTransfers() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Manila"))
        let h = try LedgerHarness()
        let pnb = try h.account("PNB", opening: 10_000)
        let gcash = try h.account("GCash", opening: 2_000, kind: .eWallet)
        let food = try h.expenseCategory("Food")
        let salary = try h.incomeSource("Salary")

        let march = ReportingPeriod.thisMonth.interval(containing: h.clock.now, calendar: calendar)
        XCTAssertEqual(calendar.component(.day, from: march.start), 1)
        XCTAssertEqual(calendar.component(.month, from: march.start), 3)

        try h.ledger.recordIncome(amount: 30_000, accountID: pnb.id, sourceID: salary.id, occurredAt: march.start)
        try h.ledger.recordExpense(amount: 100, accountID: gcash.id, categoryID: food.id, occurredAt: march.end.addingTimeInterval(-1))
        try h.ledger.recordExpense(amount: 999, accountID: gcash.id, categoryID: food.id, occurredAt: march.end)
        try h.ledger.recordTransfer(amount: 5_000, fromAccountID: pnb.id, toAccountID: gcash.id, occurredAt: march.start.addingTimeInterval(60))

        let summary = try h.ledger.periodSummary(for: march)
        XCTAssertEqual(summary.income.amount, 30_000)
        XCTAssertEqual(summary.expenses.amount, 100, "The first instant of April belongs to April")
        XCTAssertEqual(summary.net.amount, 29_900)
        XCTAssertEqual(summary.incomeCount, 1)
        XCTAssertEqual(summary.expenseCount, 1)

        let february = ReportingPeriod.lastMonth.interval(containing: h.clock.now, calendar: calendar)
        XCTAssertEqual(february.end, march.start)
        XCTAssertEqual(calendar.component(.month, from: february.start), 2)
    }

    func testSeedingInsertsDefaultsOnceWithoutInventingBalances() throws {
        let suiteName = "LedgerTests.seed.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
        defer { defaults.removePersistentDomain(forName: suiteName) }
        let container = try LedgerStore.makeContainer(storage: .inMemory)
        let bootstrapper = LedgerBootstrapper(context: container.mainContext, marker: defaults)

        XCTAssertTrue(bootstrapper.seedIfNeeded(with: .personalDefault))
        let ledger = LedgerService(context: container.mainContext)
        let accounts = try ledger.accounts()
        XCTAssertEqual(accounts.map(\.name), ["GCash", "GoTyme", "Maya", "PNB", "Wallet"])
        XCTAssertTrue(accounts.allSatisfy { $0.openingBalanceMinor == nil }, "Opening balances are entered by the user")
        XCTAssertEqual(try ledger.categories(kind: .expense).map(\.name), [
            "Food", "Transport", "Shopping", "Bills", "Bus", "Gym", "Haircut", "Jeep", "Marketing", "Mobile Data",
        ])
        XCTAssertEqual(try ledger.categories(kind: .income).map(\.name), ["Salary", "Other income", "Refund", "Bonus"])

        XCTAssertFalse(bootstrapper.seedIfNeeded(with: .personalDefault))
        for account in accounts { try ledger.deleteAccount(account) }
        XCTAssertFalse(bootstrapper.seedIfNeeded(with: .personalDefault), "Deleting everything must not re-seed")
        XCTAssertTrue(try ledger.accounts(includeArchived: true).isEmpty)
    }

    func testSeedingNeverTouchesAStoreWithData() throws {
        let container = try LedgerStore.makeContainer(storage: .inMemory)
        let ledger = LedgerService(context: container.mainContext)
        try ledger.createAccount(name: "Savings", kind: .bank, openingBalance: 1)

        let seeded = LedgerBootstrapper(context: container.mainContext, marker: nil).seedIfNeeded(with: .personalDefault)

        XCTAssertFalse(seeded)
        XCTAssertEqual(try ledger.accounts().map(\.name), ["Savings"])
        XCTAssertTrue(try ledger.categories(kind: .expense).isEmpty)
    }

    func testRecordsWithUnknownKindsAreLeftOutOfCalculations() throws {
        let h = try LedgerHarness()
        let gcash = try h.account("GCash", opening: 1_000, kind: .eWallet)
        let food = try h.expenseCategory("Food")
        let future = try h.ledger.recordExpense(amount: 100, accountID: gcash.id, categoryID: food.id)
        future.kindRaw = "loanRepayment"
        try h.context.save()

        XCTAssertEqual(try h.balance(gcash), 1_000)
        XCTAssertNil(TransactionDraft(future), "Unknown kinds can't be edited by this version")
    }

    func testUnarchivedItemsReturnToTheirPlaceUnlessItWasTaken() throws {
        let h = try LedgerHarness()
        let alpha = try h.account("Alpha", opening: nil)
        let mid = try h.account("Mid", opening: nil)
        let zeta = try h.account("Zeta", opening: nil)
        try h.ledger.archiveAccount(alpha)
        try h.ledger.reorderAccounts([zeta, mid])
        try h.ledger.unarchiveAccount(alpha)

        XCTAssertEqual(try h.ledger.accounts().map(\.name), ["Zeta", "Mid", "Alpha"])
        XCTAssertEqual(try h.ledger.balanceSheet().balances.map(\.account.name), ["Zeta", "Mid", "Alpha"], "Pickers and balances agree")

        let food = try h.expenseCategory("Food")
        let bus = try h.expenseCategory("Bus")
        try h.ledger.archiveCategory(food)
        try h.ledger.unarchiveCategory(food)
        XCTAssertEqual(try h.ledger.categories(kind: .expense).map(\.name), ["Food", bus.name], "A free position is kept")
    }

    func testAccountOrderIsPersisted() throws {
        let h = try LedgerHarness()
        let a = try h.account("A", opening: nil)
        let b = try h.account("B", opening: nil)
        let c = try h.account("C", opening: nil)
        try h.ledger.reorderAccounts([c, a, b])
        XCTAssertEqual(try h.ledger.accounts().map(\.name), ["C", "A", "B"])
        XCTAssertEqual(try h.ledger.balanceSheet().balances.map(\.account.name), ["C", "A", "B"])
    }
}
