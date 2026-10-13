import Foundation
import XCTest
@testable import Ledger

/// Reference safety and ordering for accounts and categories over their lifetime, and the
/// history queries built on them.
@MainActor
final class AccountLifecycleTests: XCTestCase {
    func testAnAccountUsedOnlyAsATransferDestinationCannotBeDeleted() throws {
        let h = try LedgerHarness()
        let pnb = try h.account("PNB", opening: 1_000)
        let maya = try h.account("Maya", opening: 0, kind: .eWallet)
        let transfer = try h.ledger.recordTransfer(amount: 100, fromAccountID: pnb.id, toAccountID: maya.id)

        XCTAssertEqual(try h.ledger.transactionCount(for: maya), 1)
        assertThrowsLedgerError(.accountHasTransactions(name: "Maya")) { try h.ledger.deleteAccount(maya) }

        XCTAssertEqual(transfer.destinationAccount?.id, maya.id, "History keeps both sides of the transfer")
        XCTAssertEqual(try h.ledger.transactions(involving: maya).map(\.id), [transfer.id])
        XCTAssertEqual(try h.balance(maya), 100)
        XCTAssertEqual(try h.balance(pnb), 900)
    }

    func testArchivingTwiceKeepsTheFirstArchiveDate() throws {
        let h = try LedgerHarness()
        let maya = try h.account("Maya", opening: 0, kind: .eWallet)
        let gym = try h.expenseCategory("Gym")
        let firstArchive = h.clock.now
        try h.ledger.archiveAccount(maya)
        try h.ledger.archiveCategory(gym)

        h.clock.advance(by: 86_400)
        try h.ledger.archiveAccount(maya)
        try h.ledger.archiveCategory(gym)
        XCTAssertEqual(maya.archivedAt, firstArchive)
        XCTAssertEqual(gym.archivedAt, firstArchive)

        try h.ledger.unarchiveAccount(maya)
        try h.ledger.unarchiveAccount(maya)
        try h.ledger.unarchiveCategory(gym)
        XCTAssertFalse(maya.isArchived)
        XCTAssertNil(maya.archivedAt)
        XCTAssertFalse(gym.isArchived)
        XCTAssertNil(gym.archivedAt)
    }

    func testNewAccountsAndCategoriesAreOrderedAfterArchivedOnes() throws {
        let h = try LedgerHarness()
        let a = try h.account("A", opening: nil)
        let b = try h.account("B", opening: nil)
        try h.ledger.archiveAccount(b)
        let food = try h.expenseCategory("Food")
        try h.ledger.archiveCategory(food)

        let c = try h.account("C", opening: nil)
        let bills = try h.expenseCategory("Bills")
        let salary = try h.incomeSource("Salary")

        XCTAssertEqual([a, b, c].map(\.sortOrder), [0, 1, 2], "A new account never shares an archived one's position")
        XCTAssertEqual(bills.sortOrder, 1)
        XCTAssertEqual(salary.sortOrder, 0, "Each category kind has its own order")
        try h.ledger.unarchiveAccount(b)
        XCTAssertEqual(try h.ledger.accounts().map(\.name), ["A", "B", "C"])
    }

    func testHistoryIsNewestFirstWithEntryTimeBreakingTies() throws {
        let h = try LedgerHarness()
        let gcash = try h.account("GCash", opening: 1_000, kind: .eWallet)
        let food = try h.expenseCategory("Food")
        let lunchTime = h.clock.now
        let first = try h.ledger.recordExpense(amount: 1, accountID: gcash.id, categoryID: food.id, occurredAt: lunchTime)
        h.clock.advance(by: 30)
        let second = try h.ledger.recordExpense(amount: 2, accountID: gcash.id, categoryID: food.id, occurredAt: lunchTime)
        let backdated = try h.ledger.recordExpense(amount: 3, accountID: gcash.id, categoryID: food.id, occurredAt: lunchTime.addingTimeInterval(-86_400))
        let latest = try h.ledger.recordExpense(amount: 4, accountID: gcash.id, categoryID: food.id, occurredAt: lunchTime.addingTimeInterval(1))

        let expected = [latest.id, second.id, first.id, backdated.id]
        XCTAssertEqual(try h.ledger.transactions().map(\.id), expected)
        XCTAssertEqual(try h.ledger.transactions(involving: gcash).map(\.id), expected)
        XCTAssertEqual(try h.ledger.recentTransactions(limit: 2).map(\.id), [latest.id, second.id])
    }

    func testAHistoryLimitOfZeroOrLessReturnsNoTransactions() throws {
        let h = try LedgerHarness()
        let gcash = try h.account("GCash", opening: 1_000, kind: .eWallet)
        let food = try h.expenseCategory("Food")
        for _ in 0..<3 {
            try h.ledger.recordExpense(amount: 1, accountID: gcash.id, categoryID: food.id)
        }

        XCTAssertEqual(try h.ledger.transactions(limit: 0).count, 0)
        XCTAssertEqual(try h.ledger.recentTransactions(limit: 0).count, 0)
        XCTAssertEqual(try h.ledger.transactions(limit: -1).count, 0)
        XCTAssertEqual(try h.ledger.transactions(limit: 2).count, 2)
        XCTAssertEqual(try h.ledger.transactions().count, 3)
    }
}
