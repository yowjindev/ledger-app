import Foundation
import SwiftData
import XCTest
@testable import Ledger

/// The liquid total completeness note and first-run account setup.
@MainActor
final class AccountsFeatureTests: XCTestCase {
    // MARK: Completeness note

    func testCompleteTotalHasNoNote() throws {
        let h = try LedgerHarness()
        try h.account("GCash", opening: 100, kind: .eWallet)
        try h.account("PNB", opening: 0)

        XCTAssertNil(LiquidTotalCopy.note(for: try h.liquidTotal()))
    }

    func testPartialTotalNamesTheExcludedAccount() throws {
        let h = try LedgerHarness()
        try h.account("GCash", opening: 100, kind: .eWallet)
        try h.account("Maya", opening: nil, kind: .eWallet)

        XCTAssertEqual(LiquidTotalCopy.note(for: try h.liquidTotal()), "Excludes Maya until its opening balance is set.")
    }

    func testPartialTotalNamesEveryExcludedAccount() throws {
        let h = try LedgerHarness()
        try h.account("GCash", opening: 100, kind: .eWallet)
        try h.account("GoTyme", opening: nil)
        try h.account("Maya", opening: nil, kind: .eWallet)

        let note = try XCTUnwrap(LiquidTotalCopy.note(for: try h.liquidTotal()))
        XCTAssertTrue(note.hasPrefix("Excludes GoTyme"), note)
        XCTAssertTrue(note.contains("Maya"), note)
        XCTAssertTrue(note.hasSuffix("until their opening balances are set."), note)
    }

    func testTotalWithNothingIncludedAsksForOpeningBalances() throws {
        let h = try LedgerHarness()
        try h.account("Wallet", opening: nil, kind: .cash)

        XCTAssertEqual(LiquidTotalCopy.note(for: try h.liquidTotal()), "Set the opening balance of Wallet to see your total.")
    }

    func testArchivedAccountsAreNotNamed() throws {
        let h = try LedgerHarness()
        try h.account("GCash", opening: 100, kind: .eWallet)
        let old = try h.account("Old Bank", opening: nil)
        try h.ledger.archiveAccount(old)

        XCTAssertNil(LiquidTotalCopy.note(for: try h.liquidTotal()))
    }

    // MARK: First-run setup

    func testSavesEnteredBalancesAndLeavesEmptyOnesUnset() throws {
        let h = try LedgerHarness()
        let gcash = try h.account("GCash", opening: nil, kind: .eWallet)
        let maya = try h.account("Maya", opening: nil, kind: .eWallet)
        let wallet = try h.account("Wallet", opening: nil, kind: .cash)

        try h.ledger.applySetup([
            AccountSetupChoice(accountID: gcash.id, isUsed: true, currentBalance: dec("4230.50")),
            AccountSetupChoice(accountID: maya.id, isUsed: true, currentBalance: nil),
            AccountSetupChoice(accountID: wallet.id, isUsed: true, currentBalance: 0),
        ])

        XCTAssertEqual(gcash.openingBalanceMinor, 423_050)
        XCTAssertNil(maya.openingBalanceMinor, "An empty amount stays not set, never zero")
        XCTAssertEqual(wallet.openingBalanceMinor, 0, "Zero is a real opening balance")
    }

    func testEntriesLoggedBeforeSetupAreNotCountedTwice() throws {
        let h = try LedgerHarness()
        let gcash = try h.account("GCash", opening: nil, kind: .eWallet)
        let food = try h.expenseCategory("Food")
        // Logged from Shortcuts before onboarding.
        try h.ledger.recordExpense(amount: 250, accountID: gcash.id, categoryID: food.id, origin: .appIntent)

        try h.ledger.applySetup([AccountSetupChoice(accountID: gcash.id, isUsed: true, currentBalance: 4_000)])

        XCTAssertEqual(try h.balance(gcash), 4_000, "The balance shows exactly what the user entered")
        XCTAssertEqual(gcash.openingBalanceMinor, 425_000, "The opening balance is what it held before the expense")
    }

    func testBalanceSmallerThanLoggedIncomeIsRefused() throws {
        let h = try LedgerHarness()
        let pnb = try h.account("PNB", opening: nil)
        let salary = try h.incomeSource("Salary")
        try h.ledger.recordIncome(amount: 25_000, accountID: pnb.id, sourceID: salary.id)

        assertThrowsLedgerError(.balanceBelowRecordedActivity(name: "PNB")) {
            try h.ledger.applySetup([AccountSetupChoice(accountID: pnb.id, isUsed: true, currentBalance: 20_000)])
        }
        XCTAssertNil(pnb.openingBalanceMinor)
    }

    func testRemovesUnusedAccountsWithoutHistoryAndArchivesOnesWithHistory() throws {
        let h = try LedgerHarness()
        let gcash = try h.account("GCash", opening: 100, kind: .eWallet)
        let maya = try h.account("Maya", opening: nil, kind: .eWallet)
        let pnb = try h.account("PNB", opening: 500)
        let food = try h.expenseCategory("Food")
        try h.ledger.recordExpense(amount: 20, accountID: pnb.id, categoryID: food.id)

        try h.ledger.applySetup([
            AccountSetupChoice(accountID: gcash.id, isUsed: true, currentBalance: 100),
            AccountSetupChoice(accountID: maya.id, isUsed: false, currentBalance: nil),
            AccountSetupChoice(accountID: pnb.id, isUsed: false, currentBalance: nil),
        ])

        let remaining = try h.ledger.accounts(includeArchived: true)
        XCTAssertEqual(remaining.map(\.name), ["GCash", "PNB"])
        XCTAssertFalse(gcash.isArchived)
        XCTAssertTrue(pnb.isArchived, "An account with transactions is archived, not deleted")
        XCTAssertEqual(try h.transactionCount(), 1)
    }

    func testClearingASavedBalanceUnsetsIt() throws {
        let h = try LedgerHarness()
        let gcash = try h.account("GCash", opening: 100, kind: .eWallet)

        try h.ledger.applySetup([AccountSetupChoice(accountID: gcash.id, isUsed: true, currentBalance: nil)])

        XCTAssertNil(gcash.openingBalanceMinor)
    }

    func testUnchangedChoicesWriteNothing() throws {
        let h = try LedgerHarness()
        let gcash = try h.account("GCash", opening: 100, kind: .eWallet)
        let maya = try h.account("Maya", opening: nil, kind: .eWallet)

        // Every save fails, so this passes only if nothing needed saving.
        try h.failingLedger().applySetup([
            AccountSetupChoice(accountID: gcash.id, isUsed: true, currentBalance: 100),
            AccountSetupChoice(accountID: maya.id, isUsed: true, currentBalance: nil),
        ])

        XCTAssertEqual(gcash.openingBalanceMinor, 10_000)
        XCTAssertNil(maya.openingBalanceMinor)
    }

    func testInvalidAmountStopsBeforeAnythingChanges() throws {
        let h = try LedgerHarness()
        let gcash = try h.account("GCash", opening: nil, kind: .eWallet)
        let maya = try h.account("Maya", opening: nil, kind: .eWallet)
        let pnb = try h.account("PNB", opening: nil)

        assertThrowsLedgerError(.amountTooPrecise) {
            try h.ledger.applySetup([
                AccountSetupChoice(accountID: gcash.id, isUsed: true, currentBalance: 50),
                AccountSetupChoice(accountID: maya.id, isUsed: true, currentBalance: dec("1.005")),
                AccountSetupChoice(accountID: pnb.id, isUsed: false, currentBalance: nil),
            ])
        }

        XCTAssertNil(gcash.openingBalanceMinor, "No balance is saved when any amount is invalid")
        XCTAssertEqual(try h.ledger.accounts().count, 3, "No account is removed when any amount is invalid")
    }

    func testFailedSaveChangesNothingAtAll() throws {
        let h = try LedgerHarness()
        let gcash = try h.account("GCash", opening: nil, kind: .eWallet)
        let maya = try h.account("Maya", opening: nil, kind: .eWallet)
        let wallet = try h.account("Wallet", opening: nil, kind: .cash)
        let choices = [
            AccountSetupChoice(accountID: gcash.id, isUsed: true, currentBalance: 100),
            AccountSetupChoice(accountID: maya.id, isUsed: true, currentBalance: 200),
            AccountSetupChoice(accountID: wallet.id, isUsed: false, currentBalance: nil),
        ]

        assertThrowsLedgerError(.persistenceFailed) { try h.failingLedger().applySetup(choices) }
        XCTAssertNil(gcash.openingBalanceMinor, "Setup is all or nothing")
        XCTAssertNil(maya.openingBalanceMinor)
        XCTAssertEqual(try h.ledger.accounts().count, 3)
        XCTAssertFalse(h.context.hasChanges)

        try h.ledger.applySetup(choices)
        XCTAssertEqual(gcash.openingBalanceMinor, 10_000)
        XCTAssertEqual(maya.openingBalanceMinor, 20_000)
        XCTAssertEqual(try h.ledger.accounts().map(\.name), ["GCash", "Maya"])
    }
}
