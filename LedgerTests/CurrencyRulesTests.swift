import Foundation
import SwiftData
import XCTest
@testable import Ledger

/// Accounts in other currencies: transfers never mix currencies, entries take their account's
/// currency, and peso totals and summaries leave other currencies out instead of adding them.
@MainActor
final class CurrencyRulesTests: XCTestCase {
    private let dollars = CurrencyCode(rawValue: "USD")
    private let yen = CurrencyCode(rawValue: "JPY")

    func testTransfersBetweenCurrenciesAreRefusedInBothDirections() throws {
        let h = try LedgerHarness()
        let pnb = try h.account("PNB", opening: 10_000)
        let savings = try h.ledger.createAccount(name: "USD Savings", kind: .bank, openingBalance: 100, currency: dollars)

        assertThrowsLedgerError(.currencyMismatch) {
            try h.ledger.recordTransfer(amount: 50, fromAccountID: savings.id, toAccountID: pnb.id)
        }
        assertThrowsLedgerError(.currencyMismatch) {
            try h.ledger.recordTransfer(amount: 50, fromAccountID: pnb.id, toAccountID: savings.id)
        }
        XCTAssertEqual(try h.transactionCount(), 0)
        XCTAssertEqual(try h.balance(pnb), 10_000)
        XCTAssertEqual(try h.balance(savings), 100)
    }

    func testEditingATransferAcrossCurrenciesIsRefused() throws {
        let h = try LedgerHarness()
        let pnb = try h.account("PNB", opening: 10_000)
        let gcash = try h.account("GCash", opening: 0, kind: .eWallet)
        let savings = try h.ledger.createAccount(name: "USD Savings", kind: .bank, openingBalance: 100, currency: dollars)
        let transfer = try h.ledger.recordTransfer(amount: 500, fromAccountID: pnb.id, toAccountID: gcash.id)

        var draft = try XCTUnwrap(TransactionDraft(transfer))
        draft.destinationAccountID = savings.id
        assertThrowsLedgerError(.currencyMismatch) { try h.ledger.update(transfer, with: draft) }
        draft.accountID = savings.id
        draft.destinationAccountID = gcash.id
        assertThrowsLedgerError(.currencyMismatch) { try h.ledger.update(transfer, with: draft) }

        XCTAssertEqual(transfer.account?.id, pnb.id)
        XCTAssertEqual(transfer.destinationAccount?.id, gcash.id)
        XCTAssertEqual(transfer.currency, .php)
        XCTAssertFalse(h.context.hasChanges)
    }

    func testEntriesInAForeignCurrencyAccountUseThatCurrencyAndStayOutOfPesoTotals() throws {
        let h = try LedgerHarness()
        let savings = try h.ledger.createAccount(
            name: "USD Savings", kind: .bank, openingBalance: dec("100.50"), currency: CurrencyCode(rawValue: "usd")
        )
        let pnb = try h.account("PNB", opening: 1_000)
        let food = try h.expenseCategory("Food")
        XCTAssertEqual(savings.currencyCode, "USD", "Currency codes are stored uppercased")

        let expense = try h.ledger.recordExpense(amount: dec("12.34"), accountID: savings.id, categoryID: food.id)
        XCTAssertEqual(expense.amount, Money(dec("12.34"), currency: dollars))
        XCTAssertEqual(try XCTUnwrap(try h.ledger.balance(of: savings)).currentBalance, Money(dec("88.16"), currency: dollars))

        let pesoTotal = try h.liquidTotal()
        XCTAssertEqual(pesoTotal.total, Money(1_000))
        XCTAssertEqual(pesoTotal.includedAccountIDs, [pnb.id])
        XCTAssertEqual(try h.ledger.periodSummary(for: h.allTime).expenses, .zero())
        XCTAssertEqual(try h.ledger.periodSummary(for: h.allTime, currency: dollars).expenses, Money(dec("12.34"), currency: dollars))
        XCTAssertEqual(try h.ledger.balanceSheet(displayCurrency: dollars).liquidTotal.total, Money(dec("88.16"), currency: dollars))
    }

    func testMovingAnEntryToAnotherCurrencyRevalidatesTheAmountInThatCurrency() throws {
        let h = try LedgerHarness()
        let gcash = try h.account("GCash", opening: 1_000, kind: .eWallet)
        let yenWallet = try h.ledger.createAccount(name: "Yen", kind: .cash, openingBalance: 5_000, currency: yen)
        let food = try h.expenseCategory("Food")
        let expense = try h.ledger.recordExpense(amount: dec("10.50"), accountID: gcash.id, categoryID: food.id)

        var draft = try XCTUnwrap(TransactionDraft(expense))
        draft.accountID = yenWallet.id
        assertThrowsLedgerError(.amountTooPrecise) { try h.ledger.update(expense, with: draft) }
        XCTAssertEqual(expense.currency, .php)
        XCTAssertEqual(expense.amountMinor, 1_050)

        draft.amount = 300
        try h.ledger.update(expense, with: draft)
        XCTAssertEqual(expense.currency, yen)
        XCTAssertEqual(expense.amountMinor, 300, "Yen has no minor unit")
        XCTAssertEqual(try h.balance(yenWallet), 4_700)
        XCTAssertEqual(try h.balance(gcash), 1_000)
    }

    func testZeroDecimalCurrencyRefusesFractionsEverywhere() throws {
        let h = try LedgerHarness()
        let food = try h.expenseCategory("Food")

        assertThrowsLedgerError(.amountTooPrecise) {
            try h.ledger.createAccount(name: "Yen", kind: .cash, openingBalance: dec("0.5"), currency: yen)
        }
        let wallet = try h.ledger.createAccount(name: "Yen", kind: .cash, openingBalance: 1_000, currency: yen)
        XCTAssertEqual(wallet.openingBalanceMinor, 1_000)
        assertThrowsLedgerError(.amountTooPrecise) { try h.ledger.setOpeningBalance(dec("999.9"), for: wallet) }
        assertThrowsLedgerError(.amountTooPrecise) {
            try h.ledger.recordExpense(amount: dec("1.5"), accountID: wallet.id, categoryID: food.id)
        }
        XCTAssertNil(try h.ledger.recentDuplicate(of: .expense(amount: dec("1.5"), accountID: wallet.id, categoryID: food.id, occurredAt: h.clock.now)))
        XCTAssertEqual(try h.balance(wallet), 1_000)
    }

    func testRecordsWithAnUnknownStatusAreLeftOutOfCalculations() throws {
        let h = try LedgerHarness()
        let gcash = try h.account("GCash", opening: 1_000, kind: .eWallet)
        let food = try h.expenseCategory("Food")
        let future = try h.ledger.recordExpense(amount: 100, accountID: gcash.id, categoryID: food.id)
        future.statusRaw = "scheduled"
        try h.context.save()

        XCTAssertNil(Movement(future))
        XCTAssertEqual(try h.balance(gcash), 1_000)
        XCTAssertEqual(try h.ledger.periodSummary(for: h.allTime).expenseCount, 0)
        assertThrowsLedgerError(.accountHasTransactions(name: "GCash")) { try h.ledger.deleteAccount(gcash) }
    }
}

/// The pure balance arithmetic over snapshots, independent of persistence.
final class BalanceCalculatorTests: XCTestCase {
    private let dollars = CurrencyCode(rawValue: "USD")
    /// When every movement in these tests occurred: 2026-03-15 02:00:00 UTC.
    private let moment = Date(timeIntervalSince1970: 1_773_540_000)

    private func account(
        _ name: String,
        currency: CurrencyCode = .php,
        openingMinor: Int64? = 0,
        kind: AccountKind = .bank,
        isArchived: Bool = false,
        sortOrder: Int = 0
    ) -> AccountSnapshot {
        AccountSnapshot(
            id: UUID(), name: name, kind: kind, currency: currency,
            openingBalanceMinor: openingMinor, isArchived: isArchived, sortOrder: sortOrder
        )
    }

    private func movement(
        _ kind: TransactionKind,
        _ amountMinor: Int64,
        currency: CurrencyCode = .php,
        from accountID: UUID?,
        to destinationID: UUID? = nil
    ) -> Movement {
        Movement(
            kind: kind, status: .posted, amountMinor: amountMinor, currency: currency,
            accountID: accountID, destinationAccountID: destinationID, occurredAt: moment
        )
    }

    func testMovementsInAnotherCurrencyThanTheAccountAreIgnored() {
        let peso = account("PNB", openingMinor: 100_000)
        let dollar = account("USD Savings", currency: dollars, openingMinor: 10_000, sortOrder: 1)
        let movements = [
            movement(.expense, 5_000, currency: dollars, from: peso.id),
            movement(.income, 2_500, from: peso.id),
            movement(.transfer, 1_000, currency: dollars, from: peso.id, to: dollar.id),
            movement(.income, 700, from: dollar.id),
        ]

        let balances = BalanceCalculator.balances(accounts: [peso, dollar], movements: movements)

        XCTAssertEqual(balances.map(\.account.name), ["PNB", "USD Savings"])
        XCTAssertEqual(balances[0].expenses, .zero())
        XCTAssertEqual(balances[0].transfersOut, .zero())
        XCTAssertEqual(balances[0].currentBalance, Money(1_025))
        XCTAssertEqual(balances[1].transfersIn, Money(10, currency: dollars))
        XCTAssertEqual(balances[1].income, .zero(dollars))
        XCTAssertEqual(balances[1].currentBalance, Money(110, currency: dollars))
    }

    func testMovementsWithAMissingOrUnknownAccountOnlyAffectTheKnownSide() {
        let peso = account("PNB")
        let movements = [
            movement(.expense, 100, from: nil),
            movement(.income, 100, from: UUID()),
            movement(.transfer, 100, from: peso.id, to: nil),
            movement(.transfer, 200, from: nil, to: peso.id),
            movement(.transfer, 400, from: UUID(), to: peso.id),
        ]

        let balance = BalanceCalculator.balances(accounts: [peso], movements: movements)[0]

        XCTAssertEqual(balance.income, .zero())
        XCTAssertEqual(balance.expenses, .zero())
        XCTAssertEqual(balance.transfersOut, Money(1))
        XCTAssertEqual(balance.transfersIn, Money(6))
        XCTAssertEqual(balance.currentBalance, Money(5))
    }

    func testLiquidTotalCountsOnlyActiveAccountsWithKnownBalancesInItsCurrency() {
        let active = account("PNB", openingMinor: 100_000)
        let archived = account("Old Bank", openingMinor: 50_000, isArchived: true, sortOrder: 1)
        let unset = account("Maya", openingMinor: nil, kind: .eWallet, sortOrder: 2)
        let dollar = account("USD Savings", currency: dollars, openingMinor: 10_000, sortOrder: 3)
        let negative = account("Wallet", openingMinor: 0, kind: .cash, sortOrder: 4)
        let food = movement(.expense, 30_000, from: negative.id)

        let sheet = BalanceCalculator.balanceSheet(
            accounts: [dollar, negative, unset, archived, active], movements: [food], displayCurrency: .php
        )

        XCTAssertEqual(sheet.balances.map(\.account.name), ["PNB", "Old Bank", "Maya", "USD Savings", "Wallet"])
        XCTAssertEqual(sheet.activeBalances.map(\.account.name), ["PNB", "Maya", "USD Savings", "Wallet"])
        XCTAssertEqual(sheet.archivedBalances.map(\.account.name), ["Old Bank"])
        XCTAssertEqual(sheet.liquidTotal.total, Money(700), "An overdrawn account lowers the total")
        XCTAssertEqual(sheet.liquidTotal.includedAccountIDs, [active.id, negative.id])
        XCTAssertEqual(sheet.liquidTotal.accountsMissingOpeningBalance.map(\.name), ["Maya"])
        XCTAssertFalse(sheet.liquidTotal.isComplete)
        XCTAssertEqual(sheet.balance(for: archived.id)?.currentBalance, Money(500), "Archived accounts keep their balance")
    }

    func testPeriodSummaryCountsOnlyItsCurrencyAndNeverTransfers() {
        let peso = account("PNB")
        let dollar = account("USD Savings", currency: dollars)
        let movements = [
            movement(.income, 100_000, from: peso.id),
            movement(.income, 50_000, currency: dollars, from: dollar.id),
            movement(.expense, 25_050, from: peso.id),
            movement(.expense, 10_000, currency: dollars, from: dollar.id),
            movement(.transfer, 30_000, from: peso.id, to: UUID()),
        ]
        let interval = DateInterval(start: moment, duration: 1)

        let pesos = BalanceCalculator.periodSummary(movements: movements, in: interval, currency: .php)
        XCTAssertEqual(pesos.income, Money(1_000))
        XCTAssertEqual(pesos.expenses, Money(dec("250.50")))
        XCTAssertEqual(pesos.net, Money(dec("749.50")))
        XCTAssertEqual([pesos.incomeCount, pesos.expenseCount], [1, 1])

        let usd = BalanceCalculator.periodSummary(movements: movements, in: interval, currency: dollars)
        XCTAssertEqual(usd.income, Money(500, currency: dollars))
        XCTAssertEqual(usd.net, Money(400, currency: dollars))
    }

    func testEqualSortOrdersFallBackToNaturalNameOrder() {
        let ten = account("Account 10")
        let nine = account("Account 9")
        let two = account("account 2")

        let ordered = BalanceCalculator.balances(accounts: [ten, nine, two], movements: [])

        XCTAssertEqual(ordered.map(\.account.name), ["account 2", "Account 9", "Account 10"])
    }
}
