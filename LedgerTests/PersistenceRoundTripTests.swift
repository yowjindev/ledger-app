import Foundation
import SwiftData
import XCTest
@testable import Ledger

/// What the service saves to an on-disk store reads back identically from a freshly opened
/// container: exact minor units, an unset opening balance that stays unset rather than becoming
/// zero, instants, references, and request IDs.
@MainActor
final class PersistenceRoundTripTests: XCTestCase {
    func testSavedRecordsReadBackExactlyFromAReopenedStore() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "LedgerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory
            .appending(path: "Nested", directoryHint: .isDirectory)
            .appending(path: "Ledger.store", directoryHint: .notDirectory)
        let clock = TestClock()
        let requestID = UUID()
        let occurredAt = clock.now.addingTimeInterval(-90.25)
        let ids: (gcash: UUID, maya: UUID, pnb: UUID, expense: UUID, transfer: UUID, food: UUID)
        let savedSheet: BalanceSheet

        do {
            let container = try LedgerStore.makeContainer(storage: .onDisk(url))
            XCTAssertFalse(container.mainContext.autosaveEnabled, "Only explicit, checked saves may write")
            let ledger = LedgerService(context: container.mainContext, clock: { clock.now })
            let gcash = try ledger.createAccount(name: "GCash", kind: .eWallet, openingBalance: nil)
            let maya = try ledger.createAccount(name: "Maya", kind: .eWallet, openingBalance: 0)
            let pnb = try ledger.createAccount(name: "PNB", kind: .bank, openingBalance: AmountRules.maximum)
            let food = try ledger.createCategory(name: "Food", kind: .expense, symbolName: "fork.knife")
            let expense = try ledger.recordExpense(
                amount: dec("0.01"), accountID: gcash.id, categoryID: food.id, occurredAt: occurredAt,
                note: "Candy", origin: .appIntent, requestID: requestID
            )
            var draft = try XCTUnwrap(TransactionDraft(expense))
            draft.reference = "OR-77"
            try ledger.update(expense, with: draft)
            let transfer = try ledger.recordTransfer(amount: dec("1234.56"), fromAccountID: pnb.id, toAccountID: maya.id)
            try ledger.archiveAccount(maya)
            ids = (gcash.id, maya.id, pnb.id, expense.id, transfer.id, food.id)
            savedSheet = try ledger.balanceSheet()
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path(percentEncoded: false)))

        let reopened = try LedgerStore.makeContainer(storage: .onDisk(url))
        let ledger = LedgerService(context: reopened.mainContext, clock: { clock.now })

        let gcash = try XCTUnwrap(try ledger.account(id: ids.gcash))
        let maya = try XCTUnwrap(try ledger.account(id: ids.maya))
        let pnb = try XCTUnwrap(try ledger.account(id: ids.pnb))
        XCTAssertNil(gcash.openingBalanceMinor, "Unset must stay unset, never zero")
        XCTAssertEqual(maya.openingBalanceMinor, 0)
        XCTAssertEqual(pnb.openingBalanceMinor, 99_999_999_999_999)
        XCTAssertTrue(maya.isArchived)
        XCTAssertEqual(maya.archivedAt, clock.now)
        XCTAssertEqual(try ledger.accounts().map(\.name), ["GCash", "PNB"])

        let expense = try XCTUnwrap(try ledger.transaction(id: ids.expense))
        XCTAssertEqual(expense.kind, .expense)
        XCTAssertEqual(expense.amountMinor, 1)
        XCTAssertEqual(expense.occurredAt, occurredAt)
        XCTAssertEqual(expense.note, "Candy")
        XCTAssertEqual(expense.reference, "OR-77")
        XCTAssertEqual(expense.origin, .appIntent)
        XCTAssertEqual(expense.category?.id, ids.food)
        XCTAssertEqual(try ledger.transaction(requestID: requestID)?.id, ids.expense, "Idempotency survives a relaunch")

        let transfer = try XCTUnwrap(try ledger.transaction(id: ids.transfer))
        XCTAssertEqual(transfer.amount, Money(dec("1234.56")))
        XCTAssertEqual(transfer.account?.id, ids.pnb)
        XCTAssertEqual(transfer.destinationAccount?.id, ids.maya)

        XCTAssertEqual(try ledger.balanceSheet(), savedSheet)
        XCTAssertEqual(
            try ledger.record(
                .expense(amount: dec("0.01"), accountID: ids.gcash, categoryID: ids.food, occurredAt: clock.now),
                requestID: requestID
            ).id,
            ids.expense
        )
        XCTAssertEqual(try reopened.mainContext.fetchCount(FetchDescriptor<LedgerTransaction>()), 2)
    }
}
