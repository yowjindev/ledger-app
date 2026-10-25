import Foundation
import XCTest
@testable import Ledger

/// How cashback and plan fees read in transaction history.
@MainActor
final class CashbackHistoryTests: XCTestCase {
    private func cardWithPurchase() throws -> (LedgerHarness, LedgerTransaction, LedgerTransaction) {
        let h = try LedgerHarness(calendar: try fixedCalendar("Asia/Manila"))
        let card = try h.ledger.createOwedAccount(
            name: "Visa card", kind: .creditCard, terms: OwedTerms(statementDay: 5, dueDay: 25, cashbackPercent: 1),
            owedNow: 0, stillDue: 0
        )
        let food = try h.expenseCategory("Food")
        let purchase = try h.ledger.record(.expense(amount: 500, accountID: card.id, categoryID: food.id, occurredAt: h.clock.now))
        let cashback = try XCTUnwrap(try h.ledger.cashback(for: purchase))
        return (h, purchase, cashback)
    }

    func testCashbackJoinsItsPurchaseRow() throws {
        let (h, purchase, cashback) = try cardWithPurchase()

        let items = HistoryItem.items(from: try h.ledger.transactions())

        XCTAssertEqual(items.count, 1)
        guard case .transaction(let row, let joined) = try XCTUnwrap(items.first) else {
            return XCTFail("Expected a transaction row")
        }
        XCTAssertEqual(row.id, purchase.id)
        XCTAssertEqual(joined?.id, cashback.id)
    }

    func testCashbackWithoutItsPurchaseStaysARow() throws {
        let (h, _, cashback) = try cardWithPurchase()

        let items = HistoryItem.items(from: [cashback])

        XCTAssertEqual(items.count, 1)
        guard case .transaction(let row, let joined) = try XCTUnwrap(items.first) else {
            return XCTFail("Expected a transaction row")
        }
        XCTAssertEqual(row.id, cashback.id)
        XCTAssertNil(joined)
        XCTAssertEqual(TransactionSummary(cashback).title, "Cashback")
        XCTAssertEqual(TransactionSummary(cashback).symbolName, TransactionSummary.cashbackSymbolName)
        XCTAssertEqual(try h.transactionCount(), 2, "The harness stays alive while its models are read")
    }

    func testPlanFeesAreLabelled() throws {
        let h = try LedgerHarness(calendar: try fixedCalendar("Asia/Manila"))
        let payLater = try h.ledger.createOwedAccount(
            name: "PayLater", kind: .payLater, terms: OwedTerms(statementDay: 31, dueDay: 5), owedNow: 0, stillDue: nil
        )
        let shopping = try h.expenseCategory("Shopping")
        try h.ledger.recordSplitPurchase(SplitPurchase(
            amount: 3_000, accountID: payLater.id, categoryID: shopping.id, occurredAt: h.clock.now,
            note: nil, months: 3, monthly: 1_050, last: nil
        ))
        let fees = try XCTUnwrap(try h.ledger.transactions().first { $0.origin == .planFees })

        XCTAssertEqual(TransactionSummary(fees).title, "Fees and interest")
        XCTAssertEqual(TransactionSummary(fees).symbolName, TransactionSummary.planFeesSymbolName)
    }
}
