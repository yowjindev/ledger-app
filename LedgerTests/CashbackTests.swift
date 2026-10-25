import Foundation
import SwiftData
import XCTest
@testable import Ledger

/// Cashback on credit card purchases: added with the purchase, kept in step when it changes,
/// and removed with it.
@MainActor
final class CashbackTests: XCTestCase {
    private struct Fixture {
        let h: LedgerHarness
        let card: Account
        let bank: Account
        let food: LedgerCategory
    }

    private func fixture(cashback: Decimal? = 1) throws -> Fixture {
        let h = try LedgerHarness(calendar: try fixedCalendar("Asia/Manila"))
        let card = try h.ledger.createOwedAccount(
            name: "Visa card",
            kind: .creditCard,
            terms: OwedTerms(statementDay: 5, dueDay: 25, cashbackPercent: cashback),
            owedNow: 0,
            stillDue: nil
        )
        return Fixture(h: h, card: card, bank: try h.account("Bank", opening: 10_000), food: try h.expenseCategory("Food"))
    }

    @discardableResult
    private func purchase(_ amount: Decimal, on account: Account, _ f: Fixture, origin: EntryOrigin = .app) throws -> LedgerTransaction {
        try f.h.ledger.record(.expense(amount: amount, accountID: account.id, categoryID: f.food.id, occurredAt: f.h.clock.now), origin: origin)
    }

    private func cashbackEntries(_ f: Fixture) throws -> [LedgerTransaction] {
        try f.h.ledger.transactions().filter { $0.origin == .cashback }
    }

    func testCashbackRoundsDown() {
        XCTAssertEqual(CashbackCalculator.cashbackMinor(forPurchaseMinor: 12_345, rate: Rate(partsPerMillion: 10_000)), 123)
        XCTAssertEqual(CashbackCalculator.cashbackMinor(forPurchaseMinor: 49, rate: Rate(partsPerMillion: 20_000)), 0)
        XCTAssertEqual(CashbackCalculator.cashbackMinor(forPurchaseMinor: 9_999_999_999_999_999, rate: Rate(partsPerMillion: 1_000_000)), 9_999_999_999_999_999)
    }

    func testPurchaseRecordsCashbackInTheSameSave() throws {
        let f = try fixture()
        let bought = try purchase(500, on: f.card, f)

        XCTAssertEqual(try f.h.transactionCount(), 2)
        let cashback = try XCTUnwrap(try f.h.ledger.cashback(for: bought))
        XCTAssertEqual(cashback.kind, .income)
        XCTAssertEqual(cashback.origin, .cashback)
        XCTAssertEqual(cashback.amountMinor, 500)
        XCTAssertEqual(cashback.basisMinor, 50_000)
        XCTAssertEqual(cashback.basisRatePPM, 10_000)
        XCTAssertEqual(cashback.sourceTransactionID, bought.id)
        XCTAssertEqual(cashback.occurredAt, bought.occurredAt)
        XCTAssertEqual(cashback.account?.id, f.card.id)
        XCTAssertNil(cashback.category)
        XCTAssertEqual(try f.h.ledger.balance(of: f.card)?.owed?.amount, 495)
    }

    func testEditRecalculatesAtTheRateItWasLoggedAt() throws {
        let f = try fixture()
        let bought = try purchase(500, on: f.card, f)
        try f.h.ledger.updateOwedAccount(f.card, name: "Visa card", terms: OwedTerms(statementDay: 5, dueDay: 25, cashbackPercent: 2))

        try f.h.ledger.update(bought, with: .expense(amount: 800, accountID: f.card.id, categoryID: f.food.id, occurredAt: f.h.clock.now))

        let cashback = try XCTUnwrap(try f.h.ledger.cashback(for: bought))
        XCTAssertEqual(cashback.amountMinor, 800)
        XCTAssertEqual(cashback.basisMinor, 80_000)
        XCTAssertEqual(cashback.basisRatePPM, 10_000)
        XCTAssertEqual(try cashbackEntries(f).count, 1)
    }

    func testMovingThePurchaseOffTheCardRemovesCashback() throws {
        let f = try fixture()
        let bought = try purchase(500, on: f.card, f)

        try f.h.ledger.update(bought, with: .expense(amount: 500, accountID: f.bank.id, categoryID: f.food.id, occurredAt: f.h.clock.now))

        XCTAssertTrue(try cashbackEntries(f).isEmpty)
        XCTAssertEqual(try f.h.ledger.balance(of: f.card)?.owed?.amount, 0)
    }

    func testMovingThePurchaseOntoACashbackCardAddsIt() throws {
        let f = try fixture()
        try f.h.ledger.updateOwedAccount(f.card, name: "Visa card", terms: OwedTerms(statementDay: 5, dueDay: 25, cashbackPercent: 2))
        let bought = try purchase(500, on: f.bank, f)
        XCTAssertTrue(try cashbackEntries(f).isEmpty)

        try f.h.ledger.update(bought, with: .expense(amount: 500, accountID: f.card.id, categoryID: f.food.id, occurredAt: f.h.clock.now))

        let cashback = try XCTUnwrap(try f.h.ledger.cashback(for: bought))
        XCTAssertEqual(cashback.amountMinor, 1_000)
        XCTAssertEqual(cashback.basisRatePPM, 20_000)
    }

    func testChangingThePurchaseToATransferRemovesCashback() throws {
        let f = try fixture()
        let bought = try purchase(500, on: f.card, f)

        try f.h.ledger.update(bought, with: .transfer(amount: 500, fromAccountID: f.card.id, toAccountID: f.bank.id, occurredAt: f.h.clock.now))

        XCTAssertTrue(try cashbackEntries(f).isEmpty)
    }

    func testDeletingThePurchaseDeletesItsCashback() throws {
        let f = try fixture()
        let bought = try purchase(500, on: f.card, f)

        try f.h.ledger.delete(bought)

        XCTAssertEqual(try f.h.transactionCount(), 0)
        XCTAssertEqual(try f.h.ledger.balance(of: f.card)?.owed?.amount, 0)
    }

    func testDeletingTheCashbackAloneKeepsThePurchase() throws {
        let f = try fixture()
        let bought = try purchase(500, on: f.card, f)
        let cashback = try XCTUnwrap(try f.h.ledger.cashback(for: bought))

        try f.h.ledger.delete(cashback)

        XCTAssertEqual(try f.h.ledger.transactions().map(\.id), [bought.id])
        XCTAssertEqual(try f.h.ledger.balance(of: f.card)?.owed?.amount, 500)
    }

    func testNoCashbackOnTransfersIncomeOrTinyPurchases() throws {
        let f = try fixture()
        let refund = try f.h.incomeSource("Refund")

        try f.h.ledger.record(.transfer(amount: 300, fromAccountID: f.bank.id, toAccountID: f.card.id, occurredAt: f.h.clock.now))
        try f.h.ledger.record(.income(amount: 200, accountID: f.card.id, sourceID: refund.id, occurredAt: f.h.clock.now))
        try purchase(dec("0.49"), on: f.card, f)

        XCTAssertTrue(try cashbackEntries(f).isEmpty)
        XCTAssertEqual(try f.h.transactionCount(), 3)
    }

    func testNoCashbackWithoutARateOrOffTheCard() throws {
        let f = try fixture(cashback: nil)
        try purchase(500, on: f.card, f)
        try purchase(500, on: f.bank, f)

        XCTAssertTrue(try cashbackEntries(f).isEmpty)
    }

    func testCashbackIsNotEditable() throws {
        let f = try fixture()
        let bought = try purchase(500, on: f.card, f)
        let cashback = try XCTUnwrap(try f.h.ledger.cashback(for: bought))

        XCTAssertFalse(cashback.isEditable)
        XCTAssertTrue(bought.isEditable)
    }

    func testIntentPurchasesGetCashbackToo() throws {
        let f = try fixture()
        let bought = try purchase(500, on: f.card, f, origin: .appIntent)

        XCTAssertEqual(try f.h.ledger.cashback(for: bought)?.amountMinor, 500)
    }

    func testFailedSaveKeepsPurchaseAndCashbackTogether() throws {
        let f = try fixture()
        assertThrowsLedgerError(.persistenceFailed) {
            try f.h.failingLedger().record(.expense(amount: 500, accountID: f.card.id, categoryID: f.food.id, occurredAt: f.h.clock.now))
        }
        XCTAssertEqual(try f.h.transactionCount(), 0)

        let bought = try purchase(500, on: f.card, f)
        assertThrowsLedgerError(.persistenceFailed) {
            try f.h.failingLedger().update(bought, with: .expense(amount: 800, accountID: f.card.id, categoryID: f.food.id, occurredAt: f.h.clock.now))
        }
        XCTAssertEqual(bought.amountMinor, 50_000)
        XCTAssertEqual(try f.h.ledger.cashback(for: bought)?.amountMinor, 500)
        XCTAssertEqual(try f.h.transactionCount(), 2)
    }
}
