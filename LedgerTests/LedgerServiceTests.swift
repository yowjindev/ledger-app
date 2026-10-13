import Foundation
import SwiftData
import XCTest
@testable import Ledger

/// The required financial-correctness cases for `LedgerService`.
@MainActor
final class LedgerServiceTests: XCTestCase {
    // 1
    func testExpenseDecreasesOnlyTheAccountUsed() throws {
        let h = try LedgerHarness()
        let gcash = try h.account("GCash", opening: 4_230, kind: .eWallet)
        let pnb = try h.account("PNB", opening: 12_800)
        let food = try h.expenseCategory("Food")

        let expense = try h.ledger.recordExpense(amount: 250, accountID: gcash.id, categoryID: food.id)

        XCTAssertEqual(expense.kind, .expense)
        XCTAssertEqual(expense.amountMinor, 25_000)
        XCTAssertEqual(try h.balance(gcash), 3_980)
        XCTAssertEqual(try h.balance(pnb), 12_800)
    }

    // 2
    func testIncomeIncreasesOnlyTheAccountUsed() throws {
        let h = try LedgerHarness()
        let pnb = try h.account("PNB", opening: 12_800)
        let gcash = try h.account("GCash", opening: 4_230, kind: .eWallet)
        let salary = try h.incomeSource("Salary")

        try h.ledger.recordIncome(amount: dec("25000.50"), accountID: pnb.id, sourceID: salary.id)

        XCTAssertEqual(try h.balance(pnb), dec("37800.50"))
        XCTAssertEqual(try h.balance(gcash), 4_230)
    }

    // 3
    func testTransferMovesMoneyBetweenAccounts() throws {
        let h = try LedgerHarness()
        let pnb = try h.account("PNB", opening: 10_000)
        let gcash = try h.account("GCash", opening: 2_000, kind: .eWallet)

        let transfer = try h.ledger.recordTransfer(amount: 500, fromAccountID: pnb.id, toAccountID: gcash.id)

        XCTAssertEqual(transfer.kind, .transfer)
        XCTAssertNil(transfer.category)
        XCTAssertEqual(try h.balance(pnb), 9_500)
        XCTAssertEqual(try h.balance(gcash), 2_500)
        XCTAssertEqual(try h.transactionCount(), 1, "A transfer is one record holding both movements")
    }

    // 4
    func testTransferDoesNotChangeTotalLiquidBalance() throws {
        let h = try LedgerHarness()
        let pnb = try h.account("PNB", opening: 10_000)
        let gcash = try h.account("GCash", opening: 2_000, kind: .eWallet)
        XCTAssertEqual(try h.liquidTotal().total.amount, 12_000)

        try h.ledger.recordTransfer(amount: 500, fromAccountID: pnb.id, toAccountID: gcash.id)

        let total = try h.liquidTotal()
        XCTAssertEqual(total.total.amount, 12_000)
        XCTAssertTrue(total.isComplete)
        let summary = try h.ledger.periodSummary(for: DateInterval(start: .distantPast, end: .distantFuture))
        XCTAssertEqual(summary.income.amount, 0, "A transfer is not income")
        XCTAssertEqual(summary.expenses.amount, 0, "A transfer is not an expense")
    }

    // 5
    func testTransferRejectsSameSourceAndDestination() throws {
        let h = try LedgerHarness()
        let pnb = try h.account("PNB", opening: 10_000)

        assertThrowsLedgerError(.sameSourceAndDestination) {
            try h.ledger.recordTransfer(amount: 500, fromAccountID: pnb.id, toAccountID: pnb.id)
        }
        XCTAssertEqual(try h.transactionCount(), 0)
        XCTAssertEqual(try h.balance(pnb), 10_000)
    }

    // 6
    func testZeroAndNegativeAmountsAreRejected() throws {
        let h = try LedgerHarness()
        let gcash = try h.account("GCash", opening: 1_000, kind: .eWallet)
        let pnb = try h.account("PNB", opening: 1_000)
        let food = try h.expenseCategory("Food")
        let salary = try h.incomeSource("Salary")

        for amount in [Decimal.zero, -1, dec("-0.01"), dec("-250")] {
            assertThrowsLedgerError(.amountNotPositive) {
                try h.ledger.recordExpense(amount: amount, accountID: gcash.id, categoryID: food.id)
            }
            assertThrowsLedgerError(.amountNotPositive) {
                try h.ledger.recordIncome(amount: amount, accountID: gcash.id, sourceID: salary.id)
            }
            assertThrowsLedgerError(.amountNotPositive) {
                try h.ledger.recordTransfer(amount: amount, fromAccountID: pnb.id, toAccountID: gcash.id)
            }
        }
        assertThrowsLedgerError(.amountTooPrecise) {
            try h.ledger.recordExpense(amount: dec("10.555"), accountID: gcash.id, categoryID: food.id)
        }
        assertThrowsLedgerError(.amountTooLarge) {
            try h.ledger.recordExpense(amount: AmountRules.maximum + dec("0.01"), accountID: gcash.id, categoryID: food.id)
        }
        XCTAssertEqual(try h.transactionCount(), 0)
        XCTAssertEqual(try h.balance(gcash), 1_000)
        XCTAssertEqual(try h.balance(pnb), 1_000)
    }

    // 7
    func testEditingATransactionUpdatesBalances() throws {
        let h = try LedgerHarness()
        let gcash = try h.account("GCash", opening: 4_230, kind: .eWallet)
        let maya = try h.account("Maya", opening: 1_250, kind: .eWallet)
        let pnb = try h.account("PNB", opening: 12_800)
        let food = try h.expenseCategory("Food")
        let refund = try h.incomeSource("Refund")
        let expense = try h.ledger.recordExpense(amount: 250, accountID: gcash.id, categoryID: food.id)

        var draft = try XCTUnwrap(TransactionDraft(expense))
        draft.amount = 400
        try h.ledger.update(expense, with: draft)
        XCTAssertEqual(try h.balance(gcash), 3_830)

        draft.accountID = maya.id
        try h.ledger.update(expense, with: draft)
        XCTAssertEqual(try h.balance(gcash), 4_230, "Moving the expense restores the old account")
        XCTAssertEqual(try h.balance(maya), 850)

        draft.kind = .income
        draft.categoryID = refund.id
        try h.ledger.update(expense, with: draft)
        XCTAssertEqual(try h.balance(maya), 1_650, "As income, the same amount now increases the account")

        draft.kind = .transfer
        draft.accountID = pnb.id
        draft.destinationAccountID = gcash.id
        try h.ledger.update(expense, with: draft)
        XCTAssertEqual(try h.balance(maya), 1_250)
        XCTAssertEqual(try h.balance(pnb), 12_400)
        XCTAssertEqual(try h.balance(gcash), 4_630)
        XCTAssertNil(expense.category, "Transfers carry no category")
        XCTAssertEqual(try h.transactionCount(), 1)
    }

    // 8
    func testDeletingATransactionUpdatesBalances() throws {
        let h = try LedgerHarness()
        let pnb = try h.account("PNB", opening: 10_000)
        let gcash = try h.account("GCash", opening: 2_000, kind: .eWallet)
        let food = try h.expenseCategory("Food")
        let expense = try h.ledger.recordExpense(amount: 250, accountID: gcash.id, categoryID: food.id)
        let transfer = try h.ledger.recordTransfer(amount: 500, fromAccountID: pnb.id, toAccountID: gcash.id)
        XCTAssertEqual(try h.balance(gcash), 2_250)

        try h.ledger.delete(expense)
        XCTAssertEqual(try h.balance(gcash), 2_500)

        try h.ledger.delete(transfer)
        XCTAssertEqual(try h.balance(pnb), 10_000)
        XCTAssertEqual(try h.balance(gcash), 2_000)
        XCTAssertEqual(try h.transactionCount(), 0)
    }

    // 9
    func testFailedPersistenceDoesNotReportSuccess() throws {
        let h = try LedgerHarness()
        let gcash = try h.account("GCash", opening: 4_230, kind: .eWallet)
        let pnb = try h.account("PNB", opening: 12_800)
        let food = try h.expenseCategory("Food")
        let failing = h.failingLedger()

        assertThrowsLedgerError(.persistenceFailed) {
            try failing.recordExpense(amount: 250, accountID: gcash.id, categoryID: food.id)
        }
        assertThrowsLedgerError(.persistenceFailed) {
            try failing.recordTransfer(amount: 500, fromAccountID: pnb.id, toAccountID: gcash.id)
        }
        XCTAssertEqual(try h.transactionCount(), 0, "Nothing unsaved may remain in the context")
        XCTAssertFalse(h.context.hasChanges)
        XCTAssertEqual(try h.balance(gcash), 4_230)
        XCTAssertEqual(try h.balance(pnb), 12_800)

        let expense = try h.ledger.recordExpense(amount: 250, accountID: gcash.id, categoryID: food.id, note: "lunch")
        var draft = try XCTUnwrap(TransactionDraft(expense))
        draft.amount = 999
        draft.accountID = pnb.id
        draft.note = "edited"
        assertThrowsLedgerError(.persistenceFailed) { try failing.update(expense, with: draft) }
        // The loaded object itself must show the saved values, not the discarded edit.
        XCTAssertEqual(expense.amountMinor, 25_000, "A failed edit is rolled back")
        XCTAssertEqual(expense.account?.id, gcash.id)
        XCTAssertEqual(expense.note, "lunch")
        XCTAssertFalse(h.context.hasChanges)
        XCTAssertEqual(try h.balance(gcash), 3_980)
        XCTAssertEqual(try h.balance(pnb), 12_800)

        assertThrowsLedgerError(.persistenceFailed) { try failing.archiveAccount(gcash) }
        XCTAssertFalse(gcash.isArchived, "A failed archive is rolled back")
        assertThrowsLedgerError(.persistenceFailed) { try failing.updateCategory(food, name: "Meals") }
        XCTAssertEqual(food.name, "Food", "A failed rename is rolled back")

        assertThrowsLedgerError(.persistenceFailed) { try failing.delete(expense) }
        XCTAssertEqual(try h.transactionCount(), 1, "A failed delete keeps the transaction")
        XCTAssertEqual(try h.balance(gcash), 3_980)

        assertThrowsLedgerError(.persistenceFailed) {
            try failing.createAccount(name: "Maya", kind: .eWallet, openingBalance: 100)
        }
        XCTAssertEqual(try h.ledger.accounts().map(\.name), ["GCash", "PNB"])
    }

    // 10
    func testManyTransactionsCalculateExactly() throws {
        let h = try LedgerHarness()
        let gcash = try h.account("GCash", opening: dec("1000.00"), kind: .eWallet)
        let wallet = try h.account("Wallet", opening: dec("500.50"), kind: .cash)
        let jeep = try h.expenseCategory("Jeep")
        let food = try h.expenseCategory("Food")
        let refund = try h.incomeSource("Refund")

        // Ten fares of ₱0.10 must total exactly ₱1.00; binary floating point would drift.
        for _ in 0..<10 {
            try h.ledger.recordExpense(amount: dec("0.10"), accountID: wallet.id, categoryID: jeep.id)
        }
        try h.ledger.recordExpense(amount: dec("199.99"), accountID: gcash.id, categoryID: food.id)
        try h.ledger.recordIncome(amount: dec("0.01"), accountID: gcash.id, sourceID: refund.id)
        try h.ledger.recordTransfer(amount: dec("300.33"), fromAccountID: gcash.id, toAccountID: wallet.id)
        try h.ledger.recordExpense(amount: dec("13"), accountID: wallet.id, categoryID: jeep.id)

        XCTAssertEqual(try h.balance(gcash), dec("499.69"))   // 1000 − 199.99 + 0.01 − 300.33
        XCTAssertEqual(try h.balance(wallet), dec("786.83"))  // 500.50 − 1.00 + 300.33 − 13
        XCTAssertEqual(try h.liquidTotal().total.amount, dec("1286.52"))

        let gcashBalance = try XCTUnwrap(try h.ledger.balance(of: gcash))
        XCTAssertEqual(gcashBalance.expenses.amount, dec("199.99"))
        XCTAssertEqual(gcashBalance.income.amount, dec("0.01"))
        XCTAssertEqual(gcashBalance.transfersOut.amount, dec("300.33"))
        XCTAssertEqual(gcashBalance.transfersIn.amount, 0)
        XCTAssertEqual(try h.transactionCount(), 14)
    }

    // 11
    func testArchivingDoesNotCorruptHistory() throws {
        let h = try LedgerHarness()
        let maya = try h.account("Maya", opening: 1_250, kind: .eWallet)
        let gcash = try h.account("GCash", opening: 4_230, kind: .eWallet)
        let haircut = try h.expenseCategory("Haircut")
        let food = try h.expenseCategory("Food")
        let old = try h.ledger.recordExpense(amount: 150, accountID: maya.id, categoryID: haircut.id)
        try h.ledger.recordTransfer(amount: 100, fromAccountID: maya.id, toAccountID: gcash.id)

        try h.ledger.archiveAccount(maya)
        try h.ledger.archiveCategory(haircut)

        // History keeps its references and balances are unchanged.
        let history = try h.ledger.transactions()
        XCTAssertEqual(history.count, 2)
        XCTAssertEqual(old.account?.name, "Maya")
        XCTAssertEqual(old.category?.name, "Haircut")
        XCTAssertEqual(try h.balance(maya), 1_000)
        XCTAssertEqual(try h.balance(gcash), 4_330)
        XCTAssertEqual(try h.ledger.accounts().map(\.name), ["GCash"], "Archived accounts leave pickers")
        XCTAssertEqual(try h.ledger.categories(kind: .expense).map(\.name), ["Food"])
        XCTAssertEqual(try h.liquidTotal().total.amount, 4_330, "Archived accounts leave the liquid total")

        // Archived items can't be used for new entries...
        assertThrowsLedgerError(.accountArchived(name: "Maya")) {
            try h.ledger.recordExpense(amount: 10, accountID: maya.id, categoryID: food.id)
        }
        assertThrowsLedgerError(.categoryArchived(name: "Haircut")) {
            try h.ledger.recordExpense(amount: 10, accountID: gcash.id, categoryID: haircut.id)
        }
        // ...but existing transactions that use them stay editable.
        var draft = try XCTUnwrap(TransactionDraft(old))
        draft.note = "Barber"
        try h.ledger.update(old, with: draft)
        XCTAssertEqual(old.note, "Barber")

        // Renaming shows the new name throughout history; deletion is refused while in use.
        try h.ledger.unarchiveCategory(haircut)
        try h.ledger.updateCategory(haircut, name: "Barber")
        XCTAssertEqual(old.category?.name, "Barber")
        assertThrowsLedgerError(.categoryInUse(name: "Barber")) { try h.ledger.deleteCategory(haircut) }
        assertThrowsLedgerError(.accountHasTransactions(name: "Maya")) { try h.ledger.deleteAccount(maya) }
        XCTAssertEqual(try h.transactionCount(), 2)
    }

    // 12
    func testRepeatedSubmissionRecordsOneTransaction() throws {
        let h = try LedgerHarness()
        let gcash = try h.account("GCash", opening: 4_230, kind: .eWallet)
        let pnb = try h.account("PNB", opening: 12_800)
        let food = try h.expenseCategory("Food")
        let requestID = UUID()

        let first = try h.ledger.recordExpense(amount: 250, accountID: gcash.id, categoryID: food.id, requestID: requestID)
        let second = try h.ledger.recordExpense(amount: 250, accountID: gcash.id, categoryID: food.id, requestID: requestID)

        XCTAssertEqual(first.id, second.id)
        XCTAssertEqual(try h.transactionCount(), 1)
        XCTAssertEqual(try h.balance(gcash), 3_980)

        // Legitimate identical purchases use separate submissions and are both kept.
        try h.ledger.recordExpense(amount: 250, accountID: gcash.id, categoryID: food.id, requestID: UUID())
        try h.ledger.recordExpense(amount: 250, accountID: gcash.id, categoryID: food.id)
        XCTAssertEqual(try h.transactionCount(), 3)
        XCTAssertEqual(try h.balance(gcash), 3_480)

        // Reusing a request ID for a different operation is refused rather than ignored.
        assertThrowsLedgerError(.conflictingRequest) {
            try h.ledger.recordExpense(amount: 999, accountID: gcash.id, categoryID: food.id, requestID: requestID)
        }

        let transferID = UUID()
        try h.ledger.recordTransfer(amount: 500, fromAccountID: pnb.id, toAccountID: gcash.id, requestID: transferID)
        try h.ledger.recordTransfer(amount: 500, fromAccountID: pnb.id, toAccountID: gcash.id, requestID: transferID)
        XCTAssertEqual(try h.balance(pnb), 12_300)
        XCTAssertEqual(try h.transactionCount(), 4)
    }
}
