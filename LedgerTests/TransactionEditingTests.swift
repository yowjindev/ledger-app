import Foundation
import SwiftData
import XCTest
@testable import Ledger

/// Editing existing transactions: transfer direction, archived references, kind changes, fields a
/// kind doesn't use, and the metadata an edit must keep.
@MainActor
final class TransactionEditingTests: XCTestCase {
    func testSwappingATransfersAccountsReversesBothMovements() throws {
        let h = try LedgerHarness()
        let pnb = try h.account("PNB", opening: 10_000)
        let gcash = try h.account("GCash", opening: 2_000, kind: .eWallet)
        let transfer = try h.ledger.recordTransfer(amount: 500, fromAccountID: pnb.id, toAccountID: gcash.id)

        var draft = try XCTUnwrap(TransactionDraft(transfer))
        draft.accountID = gcash.id
        draft.destinationAccountID = pnb.id
        try h.ledger.update(transfer, with: draft)

        XCTAssertEqual(transfer.account?.id, gcash.id)
        XCTAssertEqual(transfer.destinationAccount?.id, pnb.id)
        XCTAssertEqual(try h.balance(pnb), 10_500)
        XCTAssertEqual(try h.balance(gcash), 1_500)
        let gcashBalance = try XCTUnwrap(try h.ledger.balance(of: gcash))
        XCTAssertEqual(gcashBalance.transfersOut.amount, 500)
        XCTAssertEqual(gcashBalance.transfersIn.amount, 0, "The old incoming side is gone, not left behind")
        XCTAssertEqual(try h.liquidTotal().total.amount, 12_000)
        XCTAssertEqual(try h.transactionCount(), 1)
    }

    func testEditingATransferIntoASelfTransferIsRefused() throws {
        let h = try LedgerHarness()
        let pnb = try h.account("PNB", opening: 10_000)
        let gcash = try h.account("GCash", opening: 2_000, kind: .eWallet)
        let transfer = try h.ledger.recordTransfer(amount: 500, fromAccountID: pnb.id, toAccountID: gcash.id)

        var draft = try XCTUnwrap(TransactionDraft(transfer))
        draft.accountID = gcash.id
        assertThrowsLedgerError(.sameSourceAndDestination) { try h.ledger.update(transfer, with: draft) }

        XCTAssertEqual(transfer.account?.id, pnb.id)
        XCTAssertEqual(transfer.destinationAccount?.id, gcash.id)
        XCTAssertFalse(h.context.hasChanges)
        XCTAssertEqual(try h.balance(gcash), 2_500)
    }

    func testEditingKeepsAnArchivedDestinationButRefusesAnotherArchivedAccount() throws {
        let h = try LedgerHarness()
        let pnb = try h.account("PNB", opening: 10_000)
        let maya = try h.account("Maya", opening: 1_000, kind: .eWallet)
        let gotyme = try h.account("GoTyme", opening: 0)
        let transfer = try h.ledger.recordTransfer(amount: 500, fromAccountID: pnb.id, toAccountID: maya.id)
        try h.ledger.archiveAccount(maya)
        try h.ledger.archiveAccount(gotyme)

        var draft = try XCTUnwrap(TransactionDraft(transfer))
        draft.amount = 750
        try h.ledger.update(transfer, with: draft)
        XCTAssertEqual(transfer.amountMinor, 75_000)
        XCTAssertEqual(transfer.destinationAccount?.id, maya.id)
        XCTAssertEqual(try h.balance(maya), 1_750)
        XCTAssertEqual(try h.balance(pnb), 9_250)

        draft.destinationAccountID = gotyme.id
        assertThrowsLedgerError(.accountArchived(name: "GoTyme")) { try h.ledger.update(transfer, with: draft) }
        XCTAssertEqual(transfer.destinationAccount?.id, maya.id)
        XCTAssertEqual(try h.balance(gotyme), 0)
        XCTAssertFalse(h.context.hasChanges)
    }

    func testEditingKeepsAnArchivedSourceWhileMovingTheDestination() throws {
        let h = try LedgerHarness()
        let maya = try h.account("Maya", opening: 1_000, kind: .eWallet)
        let pnb = try h.account("PNB", opening: 0)
        let gcash = try h.account("GCash", opening: 0, kind: .eWallet)
        let transfer = try h.ledger.recordTransfer(amount: 300, fromAccountID: maya.id, toAccountID: pnb.id)
        try h.ledger.archiveAccount(maya)

        var draft = try XCTUnwrap(TransactionDraft(transfer))
        draft.destinationAccountID = gcash.id
        try h.ledger.update(transfer, with: draft)

        XCTAssertEqual(transfer.account?.id, maya.id)
        XCTAssertEqual(try h.balance(maya), 700)
        XCTAssertEqual(try h.balance(pnb), 0)
        XCTAssertEqual(try h.balance(gcash), 300)
    }

    func testSwappingWithAnArchivedAccountKeepsItButNewEntriesStillCannotUseIt() throws {
        let h = try LedgerHarness()
        let pnb = try h.account("PNB", opening: 10_000)
        let maya = try h.account("Maya", opening: 1_000, kind: .eWallet)
        let transfer = try h.ledger.recordTransfer(amount: 500, fromAccountID: pnb.id, toAccountID: maya.id)
        try h.ledger.archiveAccount(maya)

        var draft = try XCTUnwrap(TransactionDraft(transfer))
        draft.accountID = maya.id
        draft.destinationAccountID = pnb.id
        try h.ledger.update(transfer, with: draft)

        XCTAssertEqual(try h.balance(maya), 500)
        XCTAssertEqual(try h.balance(pnb), 10_500)
        assertThrowsLedgerError(.accountArchived(name: "Maya")) {
            try h.ledger.recordTransfer(amount: 1, fromAccountID: maya.id, toAccountID: pnb.id)
        }
    }

    func testEditingKeepsAnArchivedCategoryButRefusesSwitchingBackOnceLeft() throws {
        let h = try LedgerHarness()
        let gcash = try h.account("GCash", opening: 1_000, kind: .eWallet)
        let haircut = try h.expenseCategory("Haircut")
        let gym = try h.expenseCategory("Gym")
        let food = try h.expenseCategory("Food")
        let expense = try h.ledger.recordExpense(amount: 150, accountID: gcash.id, categoryID: haircut.id)
        try h.ledger.archiveCategory(haircut)
        try h.ledger.archiveCategory(gym)

        var draft = try XCTUnwrap(TransactionDraft(expense))
        draft.amount = 180
        try h.ledger.update(expense, with: draft)
        XCTAssertEqual(expense.category?.id, haircut.id)
        XCTAssertEqual(try h.balance(gcash), 820)

        draft.categoryID = gym.id
        assertThrowsLedgerError(.categoryArchived(name: "Gym")) { try h.ledger.update(expense, with: draft) }
        XCTAssertEqual(expense.category?.id, haircut.id)

        draft.categoryID = food.id
        try h.ledger.update(expense, with: draft)
        draft.categoryID = haircut.id
        assertThrowsLedgerError(.categoryArchived(name: "Haircut")) { try h.ledger.update(expense, with: draft) }
        XCTAssertEqual(expense.category?.id, food.id)
    }

    func testChangingKindRequiresACategoryOfTheNewKind() throws {
        let h = try LedgerHarness()
        let gcash = try h.account("GCash", opening: 1_000, kind: .eWallet)
        let food = try h.expenseCategory("Food")
        let refund = try h.incomeSource("Refund")
        let expense = try h.ledger.recordExpense(amount: 100, accountID: gcash.id, categoryID: food.id)

        var draft = try XCTUnwrap(TransactionDraft(expense))
        draft.kind = .income
        assertThrowsLedgerError(.categoryKindMismatch(expected: .income)) { try h.ledger.update(expense, with: draft) }
        XCTAssertEqual(expense.kind, .expense)
        XCTAssertEqual(try h.balance(gcash), 900)

        draft.categoryID = refund.id
        try h.ledger.update(expense, with: draft)
        XCTAssertEqual(expense.kind, .income)
        XCTAssertEqual(try h.balance(gcash), 1_100)
    }

    func testTurningATransferIntoAnExpenseStopsCreditingTheOldDestination() throws {
        let h = try LedgerHarness()
        let pnb = try h.account("PNB", opening: 10_000)
        let gcash = try h.account("GCash", opening: 2_000, kind: .eWallet)
        let food = try h.expenseCategory("Food")
        let transfer = try h.ledger.recordTransfer(amount: 500, fromAccountID: pnb.id, toAccountID: gcash.id)

        var draft = try XCTUnwrap(TransactionDraft(transfer))
        draft.kind = .expense
        draft.categoryID = food.id
        XCTAssertEqual(draft.destinationAccountID, gcash.id, "The draft still names the old destination")
        try h.ledger.update(transfer, with: draft)

        XCTAssertNil(transfer.destinationAccount)
        XCTAssertEqual(transfer.category?.id, food.id)
        XCTAssertEqual(try h.balance(pnb), 9_500)
        XCTAssertEqual(try h.balance(gcash), 2_000)
        XCTAssertEqual(try h.liquidTotal().total.amount, 11_500, "Unlike a transfer, an expense leaves the total")
        XCTAssertEqual(try h.ledger.transactionCount(for: gcash), 0, "The old destination can now be deleted")
    }

    func testRecordingDropsReferencesTheKindDoesNotUse() throws {
        let h = try LedgerHarness()
        let pnb = try h.account("PNB", opening: 1_000)
        let gcash = try h.account("GCash", opening: 1_000, kind: .eWallet)
        let food = try h.expenseCategory("Food")
        let now = h.clock.now

        let expense = try h.ledger.record(TransactionDraft(
            kind: .expense, amount: 10, occurredAt: now,
            accountID: pnb.id, destinationAccountID: gcash.id, categoryID: food.id
        ))
        let transfer = try h.ledger.record(TransactionDraft(
            kind: .transfer, amount: 20, occurredAt: now,
            accountID: pnb.id, destinationAccountID: gcash.id, categoryID: food.id
        ))

        XCTAssertNil(expense.destinationAccount)
        XCTAssertNil(transfer.category)
        XCTAssertEqual(try h.balance(pnb), 970)
        XCTAssertEqual(try h.balance(gcash), 1_020)
        XCTAssertEqual(try h.ledger.transactionCount(for: food), 1, "Only the expense uses the category")
    }

    func testEditingStampsUpdatedAtAndKeepsCreationMetadata() throws {
        let h = try LedgerHarness()
        let gcash = try h.account("GCash", opening: 1_000, kind: .eWallet)
        let food = try h.expenseCategory("Food")
        let requestID = UUID()
        let createdAt = h.clock.now
        let expense = try h.ledger.recordExpense(
            amount: 10, accountID: gcash.id, categoryID: food.id, origin: .appIntent, requestID: requestID
        )
        XCTAssertEqual(expense.updatedAt, createdAt)

        h.clock.advance(by: 3_600)
        var draft = try XCTUnwrap(TransactionDraft(expense))
        draft.note = "Lunch"
        draft.reference = "  OR-1234  "
        try h.ledger.update(expense, with: draft)

        XCTAssertEqual(expense.createdAt, createdAt)
        XCTAssertEqual(expense.updatedAt, h.clock.now)
        XCTAssertEqual(expense.origin, .appIntent)
        XCTAssertEqual(expense.requestID, requestID)
        XCTAssertEqual(expense.reference, "OR-1234")
    }

    func testReferenceLengthIsLimitedLikeNotes() throws {
        let h = try LedgerHarness()
        let gcash = try h.account("GCash", opening: 1_000, kind: .eWallet)
        let food = try h.expenseCategory("Food")
        let limit = LedgerService.referenceLengthLimit
        let expense = try h.ledger.recordExpense(amount: 10, accountID: gcash.id, categoryID: food.id)

        var draft = try XCTUnwrap(TransactionDraft(expense))
        draft.reference = String(repeating: "ñ", count: limit)
        try h.ledger.update(expense, with: draft)
        XCTAssertEqual(expense.reference?.count, limit)

        draft.reference = String(repeating: "ñ", count: limit + 1)
        assertThrowsLedgerError(.textTooLong(limit: limit)) { try h.ledger.update(expense, with: draft) }
        XCTAssertEqual(expense.reference?.count, limit)
    }
}
