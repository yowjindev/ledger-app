import Foundation
import SwiftData
import XCTest
@testable import Ledger

/// Every mutation whose save fails must throw `.persistenceFailed`, leave nothing pending in the
/// context, and leave already-loaded model objects showing their saved values, so a screen that
/// keeps a model never displays a change that was not saved. The objects must also stay usable.
@MainActor
final class SaveFailureRollbackTests: XCTestCase {
    // MARK: Accounts

    func testFailedAccountCreationLeavesNoTrace() throws {
        let h = try LedgerHarness()
        try h.account("PNB", opening: 1_000)

        h.assertSaveFails { try $0.createAccount(name: "Maya", kind: .eWallet, openingBalance: 500) }

        XCTAssertEqual(try h.ledger.accounts(includeArchived: true).map(\.name), ["PNB"])
        XCTAssertEqual(try h.liquidTotal().total.amount, 1_000)
        let maya = try h.ledger.createAccount(name: "Maya", kind: .eWallet, openingBalance: 500)
        XCTAssertEqual(maya.sortOrder, 1, "The failed attempt didn't take a position either")
    }

    func testFailedAccountUpdateRestoresNameKindAndOpeningBalance() throws {
        let h = try LedgerHarness()
        let gcash = try h.account("GCash", opening: dec("4230.50"), kind: .eWallet)

        h.assertSaveFails { try $0.updateAccount(gcash, name: "G-Cash", kind: .bank, openingBalance: nil) }

        XCTAssertEqual(gcash.name, "GCash")
        XCTAssertEqual(gcash.kind, .eWallet)
        XCTAssertEqual(gcash.openingBalanceMinor, 423_050)
        XCTAssertEqual(try h.ledger.account(id: gcash.id)?.name, "GCash")
        XCTAssertEqual(try h.balance(gcash), dec("4230.50"))
    }

    func testFailedOpeningBalanceChangesAreRolledBackInEveryDirection() throws {
        let h = try LedgerHarness()
        let maya = try h.account("Maya", opening: nil, kind: .eWallet)
        let pnb = try h.account("PNB", opening: 12_800)

        h.assertSaveFails { try $0.setOpeningBalance(500, for: maya) }
        XCTAssertNil(maya.openingBalanceMinor, "A failed save never makes an unknown balance look known")
        h.assertSaveFails { try $0.setOpeningBalance(nil, for: pnb) }
        XCTAssertEqual(pnb.openingBalanceMinor, 1_280_000)
        h.assertSaveFails { try $0.setOpeningBalance(0, for: pnb) }
        XCTAssertEqual(pnb.openingBalanceMinor, 1_280_000)

        let total = try h.liquidTotal()
        XCTAssertEqual(total.total.amount, 12_800)
        XCTAssertEqual(total.accountsMissingOpeningBalance.map(\.name), ["Maya"])
    }

    func testFailedArchiveAndUnarchiveKeepTheSavedState() throws {
        let h = try LedgerHarness()
        let maya = try h.account("Maya", opening: 1_000, kind: .eWallet)

        h.assertSaveFails { try $0.archiveAccount(maya) }
        XCTAssertFalse(maya.isArchived)
        XCTAssertNil(maya.archivedAt)
        XCTAssertEqual(try h.liquidTotal().total.amount, 1_000)

        try h.ledger.archiveAccount(maya)
        let archivedAt = try XCTUnwrap(maya.archivedAt)
        h.clock.advance(by: 60)
        h.assertSaveFails { try $0.unarchiveAccount(maya) }
        XCTAssertTrue(maya.isArchived)
        XCTAssertEqual(maya.archivedAt, archivedAt)
        XCTAssertTrue(try h.ledger.accounts().isEmpty)
        XCTAssertEqual(try h.liquidTotal().total.amount, 0)
    }

    func testFailedAccountDeletionKeepsAUsableAccount() throws {
        let h = try LedgerHarness()
        let maya = try h.account("Maya", opening: 1_000, kind: .eWallet)
        let food = try h.expenseCategory("Food")

        h.assertSaveFails { try $0.deleteAccount(maya) }

        XCTAssertFalse(maya.isDeleted)
        XCTAssertEqual(try h.ledger.accounts().map(\.id), [maya.id])
        try h.ledger.recordExpense(amount: 10, accountID: maya.id, categoryID: food.id)
        XCTAssertEqual(try h.balance(maya), 990)
    }

    func testFailedAccountReorderRestoresEveryPosition() throws {
        let h = try LedgerHarness()
        let a = try h.account("A", opening: nil)
        let b = try h.account("B", opening: nil)
        let c = try h.account("C", opening: nil)

        h.assertSaveFails { try $0.reorderAccounts([c, b, a]) }

        XCTAssertEqual([a, b, c].map(\.sortOrder), [0, 1, 2])
        XCTAssertEqual(try h.ledger.accounts().map(\.name), ["A", "B", "C"])
        XCTAssertEqual(try h.ledger.balanceSheet().balances.map(\.account.name), ["A", "B", "C"])
    }

    // MARK: Categories

    func testFailedCategoryCreationLeavesNoTrace() throws {
        let h = try LedgerHarness()
        try h.expenseCategory("Food")

        h.assertSaveFails { try $0.createCategory(name: "Gym", kind: .expense, symbolName: "dumbbell.fill") }

        XCTAssertEqual(try h.ledger.categories(kind: .expense, includeArchived: true).map(\.name), ["Food"])
        let gym = try h.ledger.createCategory(name: "Gym", kind: .expense)
        XCTAssertEqual(gym.sortOrder, 1)
    }

    func testFailedCategoryUpdateRestoresNameAndSymbol() throws {
        let h = try LedgerHarness()
        let food = try h.ledger.createCategory(name: "Food", kind: .expense, symbolName: "fork.knife")

        h.assertSaveFails { try $0.updateCategory(food, name: "Meals", symbolName: "cup.and.saucer.fill") }

        XCTAssertEqual(food.name, "Food")
        XCTAssertEqual(food.symbolName, "fork.knife")
        XCTAssertEqual(try h.ledger.category(id: food.id)?.name, "Food")
    }

    func testFailedCategoryArchiveAndUnarchiveKeepTheSavedState() throws {
        let h = try LedgerHarness()
        let gcash = try h.account("GCash", opening: 1_000, kind: .eWallet)
        let gym = try h.expenseCategory("Gym")

        h.assertSaveFails { try $0.archiveCategory(gym) }
        XCTAssertFalse(gym.isArchived)
        XCTAssertNil(gym.archivedAt)
        XCTAssertEqual(try h.ledger.categories(kind: .expense).map(\.name), ["Gym"])

        try h.ledger.archiveCategory(gym)
        let archivedAt = try XCTUnwrap(gym.archivedAt)
        h.clock.advance(by: 60)
        h.assertSaveFails { try $0.unarchiveCategory(gym) }
        XCTAssertTrue(gym.isArchived)
        XCTAssertEqual(gym.archivedAt, archivedAt)
        assertThrowsLedgerError(.categoryArchived(name: "Gym")) {
            try h.ledger.recordExpense(amount: 10, accountID: gcash.id, categoryID: gym.id)
        }
    }

    func testFailedCategoryDeletionKeepsAUsableCategory() throws {
        let h = try LedgerHarness()
        let gcash = try h.account("GCash", opening: 1_000, kind: .eWallet)
        let gym = try h.expenseCategory("Gym")

        h.assertSaveFails { try $0.deleteCategory(gym) }

        XCTAssertFalse(gym.isDeleted)
        XCTAssertEqual(try h.ledger.categories(kind: .expense).map(\.id), [gym.id])
        try h.ledger.recordExpense(amount: 10, accountID: gcash.id, categoryID: gym.id)
        XCTAssertEqual(try h.ledger.transactionCount(for: gym), 1)
    }

    func testFailedCategoryReorderRestoresEveryPosition() throws {
        let h = try LedgerHarness()
        let food = try h.expenseCategory("Food")
        let bills = try h.expenseCategory("Bills")
        let gym = try h.expenseCategory("Gym")

        h.assertSaveFails { try $0.reorderCategories([gym, food, bills]) }

        XCTAssertEqual([food, bills, gym].map(\.sortOrder), [0, 1, 2])
        XCTAssertEqual(try h.ledger.categories(kind: .expense).map(\.name), ["Food", "Bills", "Gym"])
    }

    // MARK: Transactions

    func testFailedRecordingOfEachKindLeavesBalancesAndRelationshipsUntouched() throws {
        let h = try LedgerHarness()
        let pnb = try h.account("PNB", opening: 10_000)
        let gcash = try h.account("GCash", opening: 2_000, kind: .eWallet)
        let food = try h.expenseCategory("Food")
        let salary = try h.incomeSource("Salary")

        h.assertSaveFails { try $0.recordExpense(amount: 250, accountID: gcash.id, categoryID: food.id) }
        h.assertSaveFails { try $0.recordIncome(amount: 1_000, accountID: pnb.id, sourceID: salary.id) }
        h.assertSaveFails { try $0.recordTransfer(amount: 500, fromAccountID: pnb.id, toAccountID: gcash.id) }

        XCTAssertEqual(try h.transactionCount(), 0)
        XCTAssertEqual(pnb.transactions?.count ?? 0, 0)
        XCTAssertEqual(gcash.transactions?.count ?? 0, 0)
        XCTAssertEqual(gcash.incomingTransfers?.count ?? 0, 0)
        XCTAssertEqual(food.transactions?.count ?? 0, 0)
        XCTAssertEqual(salary.transactions?.count ?? 0, 0)
        XCTAssertEqual(try h.balance(pnb), 10_000)
        XCTAssertEqual(try h.balance(gcash), 2_000)
        XCTAssertEqual(try h.ledger.periodSummary(for: h.allTime).expenseCount, 0)
        // Nothing left behind blocks deleting what the failed entries referred to.
        try h.ledger.deleteCategory(food)
        try h.ledger.deleteAccount(gcash)
    }

    func testFailedKindChangeRestoresEveryFieldAndReference() throws {
        let h = try LedgerHarness()
        let pnb = try h.account("PNB", opening: 10_000)
        let gcash = try h.account("GCash", opening: 2_000, kind: .eWallet)
        let food = try h.expenseCategory("Food")
        let transfer = try h.ledger.recordTransfer(amount: 500, fromAccountID: pnb.id, toAccountID: gcash.id, note: "Top-up")
        h.clock.advance(by: 60)

        var draft = try XCTUnwrap(TransactionDraft(transfer))
        draft.kind = .expense
        draft.accountID = gcash.id
        draft.categoryID = food.id
        draft.amount = dec("99.99")
        draft.occurredAt = h.clock.now
        draft.note = nil
        h.assertSaveFails { try $0.update(transfer, with: draft) }

        XCTAssertEqual(transfer.kind, .transfer)
        XCTAssertEqual(transfer.account?.id, pnb.id)
        XCTAssertEqual(transfer.destinationAccount?.id, gcash.id)
        XCTAssertNil(transfer.category)
        XCTAssertEqual(transfer.amountMinor, 50_000)
        XCTAssertEqual(transfer.note, "Top-up")
        XCTAssertEqual(transfer.occurredAt, transfer.createdAt)
        XCTAssertEqual(transfer.updatedAt, transfer.createdAt)
        XCTAssertEqual(gcash.incomingTransfers?.map(\.id), [transfer.id])
        XCTAssertEqual(food.transactions?.count ?? 0, 0)
        XCTAssertEqual(try h.balance(pnb), 9_500)
        XCTAssertEqual(try h.balance(gcash), 2_500)
    }

    func testFailedDeletionKeepsATransactionThatCanStillBeEditedAndDeleted() throws {
        let h = try LedgerHarness()
        let gcash = try h.account("GCash", opening: 1_000, kind: .eWallet)
        let food = try h.expenseCategory("Food")
        let expense = try h.ledger.recordExpense(amount: 250, accountID: gcash.id, categoryID: food.id)

        h.assertSaveFails { try $0.delete(expense) }

        XCTAssertFalse(expense.isDeleted)
        XCTAssertNotNil(expense.modelContext)
        XCTAssertEqual(try h.ledger.transaction(id: expense.id)?.id, expense.id)
        XCTAssertEqual(try h.balance(gcash), 750)

        var draft = try XCTUnwrap(TransactionDraft(expense))
        draft.amount = 300
        try h.ledger.update(expense, with: draft)
        XCTAssertEqual(try h.balance(gcash), 700)
        try h.ledger.delete(expense)
        XCTAssertEqual(try h.transactionCount(), 0)
        XCTAssertEqual(try h.balance(gcash), 1_000)
    }
}
