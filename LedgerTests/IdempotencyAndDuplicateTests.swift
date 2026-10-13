import Foundation
import XCTest
@testable import Ledger

/// Request-ID idempotency after edits, deletions, and failed saves, and the boundaries of the
/// possible-duplicate check.
@MainActor
final class IdempotencyAndDuplicateTests: XCTestCase {
    // MARK: Request IDs

    func testRetryAfterTheUserEditedDetailsReturnsTheEditedTransaction() throws {
        let h = try LedgerHarness()
        let gcash = try h.account("GCash", opening: 1_000, kind: .eWallet)
        let food = try h.expenseCategory("Food")
        let requestID = UUID()
        let original = TransactionDraft.expense(
            amount: 250, accountID: gcash.id, categoryID: food.id, occurredAt: h.clock.now, note: "Lunch"
        )
        let saved = try h.ledger.record(original, requestID: requestID)

        var edited = original
        edited.note = "Team lunch"
        edited.occurredAt = h.clock.now.addingTimeInterval(-3_600)
        try h.ledger.update(saved, with: edited)

        let retried = try h.ledger.record(original, requestID: requestID)
        XCTAssertEqual(retried.id, saved.id)
        XCTAssertEqual(retried.note, "Team lunch", "A late retry never overwrites the user's edit")
        XCTAssertEqual(retried.occurredAt, edited.occurredAt)
        XCTAssertEqual(try h.transactionCount(), 1)
        XCTAssertEqual(try h.balance(gcash), 750)
    }

    func testRetryAfterTheUserEditedTheAmountOrAccountIsAConflictNotADuplicate() throws {
        let h = try LedgerHarness()
        let gcash = try h.account("GCash", opening: 1_000, kind: .eWallet)
        let maya = try h.account("Maya", opening: 1_000, kind: .eWallet)
        let food = try h.expenseCategory("Food")
        let requestID = UUID()
        let original = TransactionDraft.expense(amount: 250, accountID: gcash.id, categoryID: food.id, occurredAt: h.clock.now)
        let saved = try h.ledger.record(original, requestID: requestID)

        var edited = original
        edited.amount = 300
        try h.ledger.update(saved, with: edited)
        assertThrowsLedgerError(.conflictingRequest) { try h.ledger.record(original, requestID: requestID) }

        edited.accountID = maya.id
        try h.ledger.update(saved, with: edited)
        assertThrowsLedgerError(.conflictingRequest) { try h.ledger.record(original, requestID: requestID) }

        XCTAssertEqual(try h.transactionCount(), 1)
        XCTAssertEqual(saved.amountMinor, 30_000)
        XCTAssertEqual(try h.balance(gcash), 1_000)
        XCTAssertEqual(try h.balance(maya), 700)
    }

    /// The key is stored on the record itself, so deleting the record releases it: a later
    /// submission with the same key is recorded as a new entry. Retries arrive within moments of
    /// the original, before a deletion is plausible; remembering keys of deleted records would need
    /// a schema change.
    func testRequestIDOfADeletedTransactionIsReleased() throws {
        let h = try LedgerHarness()
        let gcash = try h.account("GCash", opening: 1_000, kind: .eWallet)
        let food = try h.expenseCategory("Food")
        let requestID = UUID()
        let draft = TransactionDraft.expense(amount: 250, accountID: gcash.id, categoryID: food.id, occurredAt: h.clock.now)
        let first = try h.ledger.record(draft, requestID: requestID)
        let firstID = first.id
        try h.ledger.delete(first)

        let second = try h.ledger.record(draft, requestID: requestID)

        XCTAssertNotEqual(second.id, firstID)
        XCTAssertEqual(try h.ledger.transaction(requestID: requestID)?.id, second.id)
        XCTAssertEqual(try h.transactionCount(), 1)
        XCTAssertEqual(try h.balance(gcash), 750)
    }

    func testRequestIDOfAFailedSaveRecordsExactlyOnceOnRetry() throws {
        let h = try LedgerHarness()
        let pnb = try h.account("PNB", opening: 1_000)
        let gcash = try h.account("GCash", opening: 1_000, kind: .eWallet)
        let requestID = UUID()
        let draft = TransactionDraft.transfer(amount: 100, fromAccountID: pnb.id, toAccountID: gcash.id, occurredAt: h.clock.now)
        let failing = h.failingLedger()

        assertThrowsLedgerError(.persistenceFailed) { try failing.record(draft, requestID: requestID) }
        XCTAssertNil(try h.ledger.transaction(requestID: requestID), "A failed save must not claim the key")

        let saved = try h.ledger.record(draft, requestID: requestID)
        // Once saved, a retry is answered from the store without saving, so it succeeds even
        // while storage is failing.
        XCTAssertEqual(try failing.record(draft, requestID: requestID).id, saved.id)
        XCTAssertEqual(try h.ledger.record(draft, requestID: requestID).id, saved.id)
        XCTAssertEqual(try h.transactionCount(), 1)
        XCTAssertEqual(try h.balance(pnb), 900)
        XCTAssertEqual(try h.balance(gcash), 1_100)
    }

    func testRetryWithALaterTimestampOrAnotherEntryPointIsTheSameOperation() throws {
        let h = try LedgerHarness()
        let gcash = try h.account("GCash", opening: 1_000, kind: .eWallet)
        let food = try h.expenseCategory("Food")
        let requestID = UUID()
        let firstInstant = h.clock.now
        let first = try h.ledger.recordExpense(
            amount: 250, accountID: gcash.id, categoryID: food.id, occurredAt: firstInstant,
            origin: .appIntent, requestID: requestID
        )

        h.clock.advance(by: 5)
        let retry = try h.ledger.recordExpense(
            amount: dec("250.00"), accountID: gcash.id, categoryID: food.id, occurredAt: h.clock.now,
            origin: .app, requestID: requestID
        )

        XCTAssertEqual(retry.id, first.id)
        XCTAssertEqual(retry.occurredAt, firstInstant)
        XCTAssertEqual(retry.origin, .appIntent)
        XCTAssertEqual(try h.transactionCount(), 1)
    }

    func testReusingARequestIDForAnotherKindAccountOrCategoryIsAConflict() throws {
        let h = try LedgerHarness()
        let gcash = try h.account("GCash", opening: 1_000, kind: .eWallet)
        let pnb = try h.account("PNB", opening: 1_000)
        let food = try h.expenseCategory("Food")
        let transport = try h.expenseCategory("Transport")
        let refund = try h.incomeSource("Refund")
        let requestID = UUID()
        try h.ledger.recordExpense(amount: 250, accountID: gcash.id, categoryID: food.id, requestID: requestID)

        assertThrowsLedgerError(.conflictingRequest) {
            try h.ledger.recordIncome(amount: 250, accountID: gcash.id, sourceID: refund.id, requestID: requestID)
        }
        assertThrowsLedgerError(.conflictingRequest) {
            try h.ledger.recordTransfer(amount: 250, fromAccountID: gcash.id, toAccountID: pnb.id, requestID: requestID)
        }
        assertThrowsLedgerError(.conflictingRequest) {
            try h.ledger.recordExpense(amount: 250, accountID: pnb.id, categoryID: food.id, requestID: requestID)
        }
        assertThrowsLedgerError(.conflictingRequest) {
            try h.ledger.recordExpense(amount: 250, accountID: gcash.id, categoryID: transport.id, requestID: requestID)
        }
        XCTAssertEqual(try h.transactionCount(), 1)
        XCTAssertEqual(try h.balance(pnb), 1_000)
    }

    func testTransferRetryWithTheDirectionReversedIsAConflict() throws {
        let h = try LedgerHarness()
        let gcash = try h.account("GCash", opening: 1_000, kind: .eWallet)
        let pnb = try h.account("PNB", opening: 1_000)
        let requestID = UUID()
        try h.ledger.recordTransfer(amount: 100, fromAccountID: pnb.id, toAccountID: gcash.id, requestID: requestID)

        assertThrowsLedgerError(.conflictingRequest) {
            try h.ledger.recordTransfer(amount: 100, fromAccountID: gcash.id, toAccountID: pnb.id, requestID: requestID)
        }
        XCTAssertEqual(try h.balance(pnb), 900)
        XCTAssertEqual(try h.balance(gcash), 1_100)
    }

    // MARK: Possible duplicates

    func testDuplicateWindowIncludesAnEntryExactlyOneHundredTwentySecondsOld() throws {
        let h = try LedgerHarness()
        let gcash = try h.account("GCash", opening: 1_000, kind: .eWallet)
        let food = try h.expenseCategory("Food")
        let saved = try h.ledger.recordExpense(amount: 250, accountID: gcash.id, categoryID: food.id)
        let draft = TransactionDraft.expense(amount: 250, accountID: gcash.id, categoryID: food.id, occurredAt: h.clock.now)
        XCTAssertEqual(LedgerService.possibleDuplicateWindow, 120)

        h.clock.advance(by: LedgerService.possibleDuplicateWindow)
        XCTAssertEqual(try h.ledger.recentDuplicate(of: draft)?.id, saved.id, "The boundary is inclusive")

        h.clock.advance(by: 0.001)
        XCTAssertNil(try h.ledger.recentDuplicate(of: draft))
    }

    func testDuplicateWindowCanBeNarrowed() throws {
        let h = try LedgerHarness()
        let gcash = try h.account("GCash", opening: 1_000, kind: .eWallet)
        let food = try h.expenseCategory("Food")
        let saved = try h.ledger.recordExpense(amount: 250, accountID: gcash.id, categoryID: food.id)
        let draft = TransactionDraft.expense(amount: 250, accountID: gcash.id, categoryID: food.id, occurredAt: h.clock.now)

        h.clock.advance(by: 10)
        XCTAssertEqual(try h.ledger.recentDuplicate(of: draft, within: 10)?.id, saved.id)
        XCTAssertNil(try h.ledger.recentDuplicate(of: draft, within: 9.999))
    }

    func testDuplicateCheckComparesTheCurrentValuesOfEditedEntries() throws {
        let h = try LedgerHarness()
        let gcash = try h.account("GCash", opening: 1_000, kind: .eWallet)
        let food = try h.expenseCategory("Food")
        let saved = try h.ledger.recordExpense(amount: 250, accountID: gcash.id, categoryID: food.id)
        var draft = try XCTUnwrap(TransactionDraft(saved))
        draft.amount = 300
        try h.ledger.update(saved, with: draft)

        XCTAssertNil(try h.ledger.recentDuplicate(of: .expense(amount: 250, accountID: gcash.id, categoryID: food.id, occurredAt: h.clock.now)))
        XCTAssertEqual(try h.ledger.recentDuplicate(of: draft)?.id, saved.id)

        try h.ledger.delete(saved)
        XCTAssertNil(try h.ledger.recentDuplicate(of: draft), "Deleted entries are never flagged")
    }

    func testDuplicateCheckDistinguishesDirectionAndKindButNotNotes() throws {
        let h = try LedgerHarness()
        let pnb = try h.account("PNB", opening: 1_000)
        let gcash = try h.account("GCash", opening: 1_000, kind: .eWallet)
        let food = try h.expenseCategory("Food")
        let transfer = try h.ledger.recordTransfer(amount: 500, fromAccountID: pnb.id, toAccountID: gcash.id, note: "Top-up")
        let now = h.clock.now

        XCTAssertNil(try h.ledger.recentDuplicate(of: .transfer(amount: 500, fromAccountID: gcash.id, toAccountID: pnb.id, occurredAt: now)))
        XCTAssertNil(try h.ledger.recentDuplicate(of: .expense(amount: 500, accountID: pnb.id, categoryID: food.id, occurredAt: now)))
        XCTAssertEqual(
            try h.ledger.recentDuplicate(of: .transfer(amount: 500, fromAccountID: pnb.id, toAccountID: gcash.id, occurredAt: now, note: "Other"))?.id,
            transfer.id,
            "Notes aren't part of what makes an entry identical"
        )
    }

    func testDuplicateCheckOfAnUnresolvableDraftFindsNothing() throws {
        let h = try LedgerHarness()
        let gcash = try h.account("GCash", opening: 1_000, kind: .eWallet)
        let food = try h.expenseCategory("Food")
        try h.ledger.recordExpense(amount: 250, accountID: gcash.id, categoryID: food.id)
        let now = h.clock.now

        XCTAssertNil(try h.ledger.recentDuplicate(of: TransactionDraft(kind: .expense, amount: 250, occurredAt: now, categoryID: food.id)))
        XCTAssertNil(try h.ledger.recentDuplicate(of: .expense(amount: 250, accountID: UUID(), categoryID: food.id, occurredAt: now)))
        XCTAssertNil(try h.ledger.recentDuplicate(of: .expense(amount: dec("250.001"), accountID: gcash.id, categoryID: food.id, occurredAt: now)))
    }
}
