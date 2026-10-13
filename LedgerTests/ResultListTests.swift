import AppIntents
import Foundation
import XCTest
@testable import Ledger

private struct UnexpectedPrompt: Error {}

/// How a finished intent lists its result.
@MainActor
final class ResultListTests: XCTestCase {
    func testEachRowsValueLeadsItsSubtitle() throws {
        let h = try LedgerHarness()
        try h.account("GCash", opening: 4_230, kind: .eWallet)
        try h.account("Wallet", opening: nil, kind: .cash)
        let outcome = try IntentFlows.balances(in: h.ledger)

        let items = ResultList.items(for: outcome)

        XCTAssertEqual(items.map(\.title), ["GCash", "Wallet"])
        XCTAssertEqual(items[0].subtitle, "\(try XCTUnwrap(outcome.rows[0].value)) · E-wallet")
        XCTAssertEqual(items[1].subtitle, "Not Set · Cash", "An unset balance is never listed as zero")
        XCTAssertEqual(items[1].symbolName, AccountKind.cash.systemImage)
        XCTAssertEqual(items[0].id, outcome.rows[0].id.uuidString)
        XCTAssertTrue(outcome.heading.hasPrefix("Total liquid: "), outcome.heading)
        XCTAssertTrue(
            outcome.heading.hasSuffix(". Excludes Wallet until its opening balance is set."),
            "The note explaining the total is shown above the rows: \(outcome.heading)"
        )
    }

    func testASavedExpenseListsTheEntryThenTheNewBalance() async throws {
        let h = try LedgerHarness()
        let gcash = try h.account("GCash", opening: 1_000, kind: .eWallet)
        let food = try h.expenseCategory("Food")

        let outcome = try await IntentFlows.logExpense(
            in: h.ledger, amount: 250, category: ExpenseCategoryEntity(food), account: AccountEntity(gcash),
            askAmount: { _ in throw UnexpectedPrompt() },
            askCategory: { _ in throw UnexpectedPrompt() },
            askAccount: { _ in throw UnexpectedPrompt() },
            confirm: { _, _ in }
        )
        let items = ResultList.items(for: outcome)

        XCTAssertEqual(items.map(\.title), ["Food", "GCash"])
        XCTAssertTrue(items[0].subtitle.hasPrefix("-"), "Money out is signed: \(items[0].subtitle)")
        XCTAssertTrue(items[0].subtitle.hasSuffix("250.00 · Expense · GCash"), items[0].subtitle)
        XCTAssertTrue(items[1].subtitle.hasSuffix("750.00 · New balance"), items[1].subtitle)
    }

    func testTheOutcomeIsListedOnlyWhileShownAndClosingTheListIsNotAnError() async {
        let outcome = IntentOutcome(
            headline: "Expense saved",
            body: nil,
            rows: [ResultRow(id: UUID(), symbolName: "fork.knife", title: "Food", subtitle: nil, value: "-₱1.00")]
        )
        var listed: String?

        await ResultList.show(outcome) { _ in
            listed = ResultList.shown?.headline
            throw CancellationError()
        }

        XCTAssertEqual(listed, "Expense saved")
        XCTAssertNil(ResultList.shown, "Nothing is listed once the list closes")
    }
}
