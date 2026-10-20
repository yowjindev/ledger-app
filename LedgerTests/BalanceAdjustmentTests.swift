import Foundation
import SwiftData
import XCTest
@testable import Ledger

/// Bringing an account to its real balance: one adjustment entry for the difference, which moves
/// the balance but is never income or spending.
@MainActor
final class BalanceAdjustmentTests: XCTestCase {
    private let formatter = fixedFormatter()

    func testHigherRealBalanceAddsAnIncreaseAdjustment() throws {
        let h = try LedgerHarness()
        let gcash = try h.account("GCash", opening: 117, kind: .eWallet)

        let correction = try h.ledger.updateBalance(of: gcash, to: 121)

        XCTAssertEqual(correction, .adjustment(Money(4)))
        XCTAssertEqual(try h.transactionCount(), 1)
        let adjustment = try XCTUnwrap(try h.ledger.transactions().first)
        XCTAssertEqual(adjustment.kind, .adjustment)
        XCTAssertEqual(adjustment.adjustmentDirection, .increase)
        XCTAssertEqual(adjustment.amountMinor, 400)
        XCTAssertEqual(adjustment.origin, .app)
        XCTAssertEqual(adjustment.account?.id, gcash.id)
        XCTAssertNil(adjustment.category)
        XCTAssertEqual(adjustment.occurredAt, h.clock.now)
        XCTAssertEqual(try h.balance(gcash), 121)
    }

    func testLowerRealBalanceAddsADecreaseAdjustment() throws {
        let h = try LedgerHarness()
        let gcash = try h.account("GCash", opening: 117, kind: .eWallet)

        let correction = try h.ledger.updateBalance(of: gcash, to: 110)

        XCTAssertEqual(correction, .adjustment(Money(-7)))
        let adjustment = try XCTUnwrap(try h.ledger.transactions().first)
        XCTAssertEqual(adjustment.adjustmentDirection, .decrease)
        XCTAssertEqual(adjustment.amountMinor, 700)
        XCTAssertEqual(try h.balance(gcash), 110)
    }

    func testMatchingBalanceRecordsNothing() throws {
        let h = try LedgerHarness()
        let gcash = try h.account("GCash", opening: dec("117.50"), kind: .eWallet)

        XCTAssertEqual(try h.ledger.updateBalance(of: gcash, to: dec("117.50")), .alreadyMatches)
        XCTAssertEqual(try h.transactionCount(), 0)
        XCTAssertEqual(try h.balance(gcash), dec("117.50"))
    }

    func testUnsetOpeningBalanceIsSetInstead() throws {
        let h = try LedgerHarness()
        let gcash = try h.account("GCash", opening: nil, kind: .eWallet)
        let salary = try h.incomeSource("Salary")
        try h.ledger.recordIncome(amount: 50, accountID: gcash.id, sourceID: salary.id)

        let correction = try h.ledger.updateBalance(of: gcash, to: 121)

        XCTAssertEqual(correction, .setOpeningBalance(Money(71)))
        XCTAssertEqual(gcash.openingBalanceMinor, 7_100)
        XCTAssertEqual(try h.transactionCount(), 1, "Only the income; no adjustment entry")
        XCTAssertEqual(try h.balance(gcash), 121)
    }

    func testUnsetOpeningBelowActivityIsRefused() throws {
        let h = try LedgerHarness()
        let gcash = try h.account("GCash", opening: nil, kind: .eWallet)
        let salary = try h.incomeSource("Salary")
        try h.ledger.recordIncome(amount: 50, accountID: gcash.id, sourceID: salary.id)

        assertThrowsLedgerError(.balanceBelowRecordedActivity(name: "GCash")) {
            try h.ledger.updateBalance(of: gcash, to: 20)
        }
        XCTAssertNil(gcash.openingBalanceMinor)
    }

    func testInvalidRealBalancesAreRefused() throws {
        let h = try LedgerHarness()
        let gcash = try h.account("GCash", opening: 117, kind: .eWallet)

        assertThrowsLedgerError(.balanceNegative) { try h.ledger.updateBalance(of: gcash, to: -1) }
        assertThrowsLedgerError(.amountTooPrecise) { try h.ledger.updateBalance(of: gcash, to: dec("1.005")) }
        assertThrowsLedgerError(.amountTooLarge) { try h.ledger.updateBalance(of: gcash, to: AmountRules.maximum + 1) }
        XCTAssertEqual(try h.transactionCount(), 0)
        XCTAssertEqual(try h.balance(gcash), 117)
    }

    func testArchivedAccountIsRefused() throws {
        let h = try LedgerHarness()
        let gcash = try h.account("GCash", opening: 117, kind: .eWallet)
        try h.ledger.archiveAccount(gcash)

        assertThrowsLedgerError(.accountArchived(name: "GCash")) { try h.ledger.updateBalance(of: gcash, to: 121) }
        XCTAssertEqual(try h.transactionCount(), 0)
    }

    func testAdjustmentsAreNeitherIncomeNorExpenses() throws {
        let h = try LedgerHarness()
        let gcash = try h.account("GCash", opening: 117, kind: .eWallet)
        let pnb = try h.account("PNB", opening: 1_000)

        try h.ledger.updateBalance(of: gcash, to: 121)
        try h.ledger.updateBalance(of: gcash, to: 114)

        let summary = try h.ledger.periodSummary(for: h.allTime)
        XCTAssertEqual(summary.income, Money.zero())
        XCTAssertEqual(summary.expenses, Money.zero())
        XCTAssertEqual(summary.incomeCount, 0)
        XCTAssertEqual(summary.expenseCount, 0)
        let balance = try XCTUnwrap(try h.ledger.balance(of: gcash))
        XCTAssertEqual(balance.adjustments, Money(-3))
        XCTAssertEqual(balance.income, Money.zero())
        XCTAssertEqual(balance.expenses, Money.zero())
        XCTAssertEqual(balance.netActivity, Money(-3))
        XCTAssertEqual(balance.currentBalance, Money(114))
        XCTAssertEqual(try h.balance(pnb), 1_000, "Other accounts are untouched")
        XCTAssertEqual(try h.liquidTotal().total.amount, 1_114)
    }

    func testDeletingAnAdjustmentRestoresTheBalance() throws {
        let h = try LedgerHarness()
        let gcash = try h.account("GCash", opening: 117, kind: .eWallet)
        try h.ledger.updateBalance(of: gcash, to: 121)

        try h.ledger.delete(try XCTUnwrap(try h.ledger.transactions().first))

        XCTAssertEqual(try h.balance(gcash), 117)
    }

    func testAdjustmentsCantBeEditedThroughDrafts() throws {
        let h = try LedgerHarness()
        let gcash = try h.account("GCash", opening: 117, kind: .eWallet)
        try h.ledger.updateBalance(of: gcash, to: 121)
        let adjustment = try XCTUnwrap(try h.ledger.transactions().first)

        XCTAssertNil(TransactionDraft(adjustment))
        XCTAssertFalse(adjustment.isEditable)
        let draft = TransactionDraft(kind: .adjustment, amount: 4, occurredAt: h.clock.now, accountID: gcash.id)
        assertThrowsLedgerError(.entryNotEditable) { try h.ledger.resolve(draft, editing: nil) }
        assertThrowsLedgerError(.entryNotEditable) { try h.ledger.update(adjustment, with: draft) }
        XCTAssertEqual(try h.balance(gcash), 121)
    }

    func testFailedAdjustmentLeavesNoTrace() throws {
        let h = try LedgerHarness()
        let gcash = try h.account("GCash", opening: 117, kind: .eWallet)
        let maya = try h.account("Maya", opening: nil, kind: .eWallet)

        h.assertSaveFails { try $0.updateBalance(of: gcash, to: 121) }
        h.assertSaveFails { try $0.updateBalance(of: maya, to: 50) }

        XCTAssertEqual(try h.transactionCount(), 0)
        XCTAssertEqual(try h.balance(gcash), 117)
        XCTAssertNil(maya.openingBalanceMinor, "A failed save never makes an unknown balance look known")
    }

    func testPreviewDoesNotWrite() throws {
        let h = try LedgerHarness()
        let gcash = try h.account("GCash", opening: 117, kind: .eWallet)
        let maya = try h.account("Maya", opening: nil, kind: .eWallet)

        XCTAssertEqual(try h.ledger.balanceCorrection(toReach: 121, for: gcash), .adjustment(Money(4)))
        XCTAssertEqual(try h.ledger.balanceCorrection(toReach: 117, for: gcash), .alreadyMatches)
        XCTAssertEqual(try h.ledger.balanceCorrection(toReach: 50, for: maya), .setOpeningBalance(Money(50)))
        assertThrowsLedgerError(.balanceNegative) { try h.ledger.balanceCorrection(toReach: -1, for: gcash) }

        XCTAssertEqual(try h.transactionCount(), 0)
        XCTAssertNil(maya.openingBalanceMinor)
        XCTAssertFalse(h.context.hasChanges)
    }

    func testAdjustmentSummaryShowsDirection() throws {
        let h = try LedgerHarness()
        let gcash = try h.account("GCash", opening: 117, kind: .eWallet)
        try h.ledger.updateBalance(of: gcash, to: 121)
        h.clock.advance(by: 60)
        try h.ledger.updateBalance(of: gcash, to: 114)
        let entries = try h.ledger.transactions()

        let decrease = TransactionSummary(entries[0])
        XCTAssertEqual(decrease.kind, .adjustment)
        XCTAssertEqual(decrease.title, "Balance adjustment")
        XCTAssertEqual(decrease.symbolName, "plus.forwardslash.minus")
        XCTAssertEqual(decrease.accountLine, "GCash")
        XCTAssertEqual(plainSpaces(decrease.signedAmountText(formatter: formatter)), "-₱7.00")
        XCTAssertEqual(plainSpaces(decrease.confirmationLine(formatter: formatter)), "-₱7.00 · Balance adjustment · GCash")

        let increase = TransactionSummary(entries[1])
        XCTAssertEqual(plainSpaces(increase.signedAmountText(formatter: formatter)), "+₱4.00")
        XCTAssertTrue(plainSpaces(increase.accessibilityLabel(formatter: formatter)).hasPrefix("Adjustment, +₱4.00, Balance adjustment, GCash, "))
    }

    func testAdjustmentsAreNotOfferedForLogging() {
        XCTAssertEqual(TransactionKind.loggable, [.expense, .income, .transfer])
        XCTAssertFalse(TransactionLogging.canLog(.adjustment, activeAccountCount: 5))
    }
}
