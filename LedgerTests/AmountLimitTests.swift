import Foundation
import SwiftData
import XCTest
@testable import Ledger

/// Amount limits and unusual `Decimal` values: the largest accepted amounts, sums beyond a single
/// amount's limit, and representations that must be accepted exactly or rejected with the right error.
@MainActor
final class AmountLimitTests: XCTestCase {
    func testMaximumAmountIsAcceptedForEveryKindButOneCentavoMoreIsNot() throws {
        let h = try LedgerHarness()
        let pnb = try h.account("PNB", opening: 0)
        let gcash = try h.account("GCash", opening: 0, kind: .eWallet)
        let food = try h.expenseCategory("Food")
        let salary = try h.incomeSource("Salary")
        let maximum = AmountRules.maximum
        let tooLarge = maximum + dec("0.01")

        let income = try h.ledger.recordIncome(amount: maximum, accountID: pnb.id, sourceID: salary.id)
        try h.ledger.recordTransfer(amount: maximum, fromAccountID: pnb.id, toAccountID: gcash.id)
        try h.ledger.recordExpense(amount: maximum, accountID: gcash.id, categoryID: food.id)
        XCTAssertEqual(income.amountMinor, 99_999_999_999_999)
        XCTAssertEqual(income.amount.amount, maximum)

        assertThrowsLedgerError(.amountTooLarge) {
            try h.ledger.recordIncome(amount: tooLarge, accountID: pnb.id, sourceID: salary.id)
        }
        assertThrowsLedgerError(.amountTooLarge) {
            try h.ledger.recordTransfer(amount: tooLarge, fromAccountID: pnb.id, toAccountID: gcash.id)
        }
        assertThrowsLedgerError(.amountTooLarge) {
            try h.ledger.recordExpense(amount: tooLarge, accountID: gcash.id, categoryID: food.id)
        }
        XCTAssertEqual(try h.transactionCount(), 3)
        XCTAssertEqual(try h.balance(pnb), 0)
        XCTAssertEqual(try h.balance(gcash), 0)
    }

    func testEditingToMoreThanTheMaximumIsRefusedAndKeepsTheSavedAmount() throws {
        let h = try LedgerHarness()
        let gcash = try h.account("GCash", opening: 1_000, kind: .eWallet)
        let food = try h.expenseCategory("Food")
        let expense = try h.ledger.recordExpense(amount: 250, accountID: gcash.id, categoryID: food.id)

        var draft = try XCTUnwrap(TransactionDraft(expense))
        draft.amount = AmountRules.maximum + dec("0.01")
        assertThrowsLedgerError(.amountTooLarge) { try h.ledger.update(expense, with: draft) }

        XCTAssertEqual(expense.amountMinor, 25_000)
        XCTAssertFalse(h.context.hasChanges)
        XCTAssertEqual(try h.balance(gcash), 750)
    }

    func testOpeningBalanceLimitAppliesToEveryWayOfSettingIt() throws {
        let h = try LedgerHarness()
        let tooLarge = AmountRules.maximum + dec("0.01")

        assertThrowsLedgerError(.amountTooLarge) {
            try h.ledger.createAccount(name: "PNB", kind: .bank, openingBalance: tooLarge)
        }
        let pnb = try h.ledger.createAccount(name: "PNB", kind: .bank, openingBalance: AmountRules.maximum)
        XCTAssertEqual(pnb.openingBalanceMinor, 99_999_999_999_999)

        assertThrowsLedgerError(.amountTooLarge) { try h.ledger.setOpeningBalance(tooLarge, for: pnb) }
        assertThrowsLedgerError(.amountTooLarge) {
            try h.ledger.updateAccount(pnb, name: "PNB", kind: .bank, openingBalance: tooLarge)
        }
        XCTAssertEqual(pnb.openingBalanceMinor, 99_999_999_999_999)
        XCTAssertFalse(h.context.hasChanges)
    }

    func testBalancesAndTotalsBeyondASingleAmountsLimitStayExact() throws {
        let h = try LedgerHarness()
        let maximum = AmountRules.maximum
        let pnb = try h.account("PNB", opening: maximum)
        let gotyme = try h.account("GoTyme", opening: maximum)
        let salary = try h.incomeSource("Salary")
        try h.ledger.recordIncome(amount: maximum, accountID: pnb.id, sourceID: salary.id)
        try h.ledger.recordIncome(amount: maximum, accountID: gotyme.id, sourceID: salary.id)

        XCTAssertEqual(try h.balance(pnb), dec("1999999999999.98"))
        XCTAssertEqual(try h.balance(gotyme), dec("1999999999999.98"))
        let total = try h.liquidTotal()
        XCTAssertEqual(total.total.amount, dec("3999999999999.96"))
        XCTAssertEqual(total.total.minorUnits, 399_999_999_999_996)

        let formatter = fixedFormatter()
        XCTAssertEqual(plainSpaces(formatter.string(total.total)), "₱3,999,999,999,999.96")
        XCTAssertEqual(plainSpaces(formatter.string(-total.total, sign: .always)), "-₱3,999,999,999,999.96")
    }

    func testSummaryOfManyMaximumAmountsIsExactToTheCentavo() throws {
        let h = try LedgerHarness()
        let pnb = try h.account("PNB", opening: nil)
        let salary = try h.incomeSource("Salary")
        let food = try h.expenseCategory("Food")
        for _ in 0..<25 {
            try h.ledger.recordIncome(amount: AmountRules.maximum, accountID: pnb.id, sourceID: salary.id)
        }
        try h.ledger.recordExpense(amount: dec("0.01"), accountID: pnb.id, categoryID: food.id)

        let summary = try h.ledger.periodSummary(for: h.allTime)
        XCTAssertEqual(summary.income.amount, dec("24999999999999.75"))
        XCTAssertEqual(summary.expenses.amount, dec("0.01"))
        XCTAssertEqual(summary.net.amount, dec("24999999999999.74"))
        XCTAssertEqual(summary.incomeCount, 25)

        let balance = try XCTUnwrap(try h.ledger.balance(of: pnb))
        XCTAssertNil(balance.currentBalance, "Still unknown without an opening balance, however large the activity")
        XCTAssertEqual(balance.netActivity.amount, dec("24999999999999.74"))
    }

    func testEquivalentDecimalRepresentationsAreStoredExactly() throws {
        let h = try LedgerHarness()
        let gcash = try h.account("GCash", opening: 0, kind: .eWallet)
        let food = try h.expenseCategory("Food")
        func record(_ amount: Decimal) throws -> Int64 {
            try h.ledger.recordExpense(amount: amount, accountID: gcash.id, categoryID: food.id).amountMinor
        }

        XCTAssertEqual(try record(dec("250.000")), 25_000, "Trailing zeros are not extra precision")
        XCTAssertEqual(try record(Decimal(sign: .plus, exponent: -4, significand: 2_500)), 25)
        XCTAssertEqual(try record(Decimal(sign: .plus, exponent: 3, significand: 2)), 200_000)
        XCTAssertEqual(try record(dec("0.1") + dec("0.2")), 30)
        XCTAssertEqual(try h.balance(gcash), dec("-2250.55"))
    }

    func testDegenerateDecimalsAreRejectedWithTheMatchingError() throws {
        let h = try LedgerHarness()
        let gcash = try h.account("GCash", opening: 0, kind: .eWallet)
        let food = try h.expenseCategory("Food")
        func record(_ amount: Decimal) throws {
            try h.ledger.recordExpense(amount: amount, accountID: gcash.id, categoryID: food.id)
        }

        assertThrowsLedgerError(.amountTooPrecise) { try record(dec("0.001")) }
        assertThrowsLedgerError(.amountTooPrecise) { try record(Decimal(sign: .plus, exponent: -30, significand: 1)) }
        assertThrowsLedgerError(.amountTooLarge) { try record(Decimal(sign: .plus, exponent: 20, significand: 1)) }
        assertThrowsLedgerError(.amountTooLarge) { try record(.greatestFiniteMagnitude) }
        assertThrowsLedgerError(.amountNotPositive) { try record(Decimal(sign: .minus, exponent: 0, significand: 0)) }
        assertThrowsLedgerError(.amountNotPositive) { try record(-AmountRules.maximum) }
        assertThrowsLedgerError(.amountNotPositive) { try record(.nan) }
        assertThrowsLedgerError(.openingBalanceNegative) { try h.ledger.setOpeningBalance(.nan, for: gcash) }
        XCTAssertEqual(try h.transactionCount(), 0)
        XCTAssertEqual(gcash.openingBalanceMinor, 0)
    }
}
