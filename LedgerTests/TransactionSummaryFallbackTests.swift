import Foundation
import SwiftData
import XCTest
@testable import Ledger

/// Display text for records whose account, category, or kind is missing or unknown, for example
/// records lost a reference outside the service or were written by a newer version. Such records
/// must still read clearly and never borrow another record's details.
@MainActor
final class TransactionSummaryFallbackTests: XCTestCase {
    private let formatter = fixedFormatter()

    func testExpenseAndIncomeWithoutCategoryOrAccount() throws {
        let h = try LedgerHarness()
        let gcash = try h.account("GCash", opening: 1_000, kind: .eWallet)
        let food = try h.expenseCategory("Food")
        let salary = try h.incomeSource("Salary")
        let expense = try h.ledger.recordExpense(amount: 250, accountID: gcash.id, categoryID: food.id)
        let income = try h.ledger.recordIncome(amount: 100, accountID: gcash.id, sourceID: salary.id)
        expense.category = nil
        income.category = nil
        income.account = nil
        try h.context.save()

        let expenseSummary = TransactionSummary(expense)
        XCTAssertEqual(expenseSummary.title, "Uncategorized")
        XCTAssertEqual(expenseSummary.symbolName, CategoryKind.expense.defaultSymbolName)
        XCTAssertEqual(expenseSummary.accountLine, "GCash")
        XCTAssertEqual(plainSpaces(expenseSummary.signedAmountText(formatter: formatter)), "-₱250.00")
        XCTAssertEqual(plainSpaces(expenseSummary.confirmationLine(formatter: formatter)), "₱250.00 · Uncategorized · GCash")
        XCTAssertTrue(
            plainSpaces(expenseSummary.accessibilityLabel(formatter: formatter)).hasPrefix("Expense, ₱250.00, Uncategorized, GCash, ")
        )

        let incomeSummary = TransactionSummary(income)
        XCTAssertEqual(incomeSummary.title, "Uncategorized")
        XCTAssertEqual(incomeSummary.symbolName, CategoryKind.income.defaultSymbolName)
        XCTAssertEqual(incomeSummary.accountLine, TransactionSummary.unknownAccount)
        XCTAssertEqual(plainSpaces(incomeSummary.signedAmountText(formatter: formatter)), "+₱100.00")
        XCTAssertTrue(
            plainSpaces(incomeSummary.accessibilityLabel(formatter: formatter)).hasPrefix("Income, ₱100.00, Uncategorized, Unknown account, ")
        )
    }

    func testTransferWithAMissingSideNamesTheUnknownAccount() throws {
        let h = try LedgerHarness()
        let pnb = try h.account("PNB", opening: 1_000)
        let gcash = try h.account("GCash", opening: 0, kind: .eWallet)
        let outgoing = try h.ledger.recordTransfer(amount: 500, fromAccountID: pnb.id, toAccountID: gcash.id)
        let incoming = try h.ledger.recordTransfer(amount: 200, fromAccountID: pnb.id, toAccountID: gcash.id)
        outgoing.destinationAccount = nil
        incoming.account = nil
        try h.context.save()

        let outgoingSummary = TransactionSummary(outgoing)
        XCTAssertEqual(outgoingSummary.title, "Transfer")
        XCTAssertEqual(outgoingSummary.accountLine, "PNB → Unknown account")
        XCTAssertEqual(plainSpaces(outgoingSummary.signedAmountText(formatter: formatter)), "₱500.00")
        XCTAssertEqual(plainSpaces(outgoingSummary.confirmationLine(formatter: formatter)), "₱500.00 · PNB → Unknown account")
        XCTAssertTrue(
            plainSpaces(outgoingSummary.accessibilityLabel(formatter: formatter)).hasPrefix("Transfer, ₱500.00, PNB to Unknown account, ")
        )
        XCTAssertEqual(TransactionSummary(incoming).accountLine, "Unknown account → GCash")
    }

    func testUnknownKindReadsAsUnsupportedWithoutASign() throws {
        let h = try LedgerHarness()
        let gcash = try h.account("GCash", opening: 1_000, kind: .eWallet)
        let food = try h.expenseCategory("Food")
        let future = try h.ledger.recordExpense(amount: 250, accountID: gcash.id, categoryID: food.id)
        future.kindRaw = "loanRepayment"
        try h.context.save()

        let summary = TransactionSummary(future)
        XCTAssertNil(summary.kind)
        XCTAssertEqual(summary.title, "Unsupported entry")
        XCTAssertEqual(summary.symbolName, "questionmark.circle")
        XCTAssertEqual(summary.accountLine, "GCash")
        XCTAssertEqual(plainSpaces(summary.signedAmountText(formatter: formatter)), "₱250.00")
        XCTAssertEqual(plainSpaces(summary.confirmationLine(formatter: formatter)), "₱250.00 · Unsupported entry · GCash")
        XCTAssertTrue(plainSpaces(summary.accessibilityLabel(formatter: formatter)).hasPrefix("Unsupported entry, ₱250.00, "))
    }

    func testSummaryShowsCurrentNamesAfterRenames() throws {
        let h = try LedgerHarness()
        let gcash = try h.account("GCash", opening: 1_000, kind: .eWallet)
        let food = try h.ledger.createCategory(name: "Food", kind: .expense, symbolName: "fork.knife")
        let expense = try h.ledger.recordExpense(amount: 250, accountID: gcash.id, categoryID: food.id)

        try h.ledger.updateAccount(gcash, name: "G-Cash", kind: .eWallet, openingBalance: 1_000)
        try h.ledger.updateCategory(food, name: "Meals", symbolName: "cup.and.saucer.fill")
        try h.ledger.archiveCategory(food)

        let summary = TransactionSummary(expense)
        XCTAssertEqual(summary.title, "Meals")
        XCTAssertEqual(summary.symbolName, "cup.and.saucer.fill")
        XCTAssertEqual(summary.accountLine, "G-Cash")
    }
}
