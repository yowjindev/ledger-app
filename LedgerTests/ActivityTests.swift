import Foundation
import SwiftData
import XCTest
@testable import Ledger

/// Search, filtering, day grouping, and editor validation used by the Overview and Activity screens.
@MainActor
final class ActivityTests: XCTestCase {
    private let posix = Locale(identifier: "en_US_POSIX")

    // MARK: Amount search

    func testAmountQueryNormalizesTypedAmounts() {
        let us = Locale(identifier: "en_US")
        XCTAssertEqual(TransactionSearch.amountQuery(from: "250", locale: us), "250")
        XCTAssertEqual(TransactionSearch.amountQuery(from: "₱1,850.5", locale: us), "1850.5")
        XCTAssertEqual(TransactionSearch.amountQuery(from: "PHP 13", locale: us), "13")
        XCTAssertEqual(TransactionSearch.amountQuery(from: ".5", locale: us), "0.5")
        XCTAssertEqual(TransactionSearch.amountQuery(from: "007", locale: us), "7")
        XCTAssertEqual(TransactionSearch.amountQuery(from: "250.", locale: us), "250.")
        XCTAssertNil(TransactionSearch.amountQuery(from: "Food", locale: us))
        XCTAssertNil(TransactionSearch.amountQuery(from: "1.2.3", locale: us))
        XCTAssertNil(TransactionSearch.amountQuery(from: ".", locale: us))
    }

    func testAmountQueryUsesTheLocaleDecimalSeparator() {
        let german = Locale(identifier: "de_DE")
        XCTAssertEqual(TransactionSearch.amountQuery(from: "1.850,50", locale: german), "1850.50")
    }

    func testWholeNumberMatchesEveryAmountWithThosePesos() {
        XCTAssertTrue(TransactionSearch.amount(Money(250), matches: "250"))
        XCTAssertTrue(TransactionSearch.amount(Money(dec("250.50")), matches: "250"))
        XCTAssertTrue(TransactionSearch.amount(Money(250), matches: "250."))
        XCTAssertFalse(TransactionSearch.amount(Money(25_000), matches: "250"))
        XCTAssertFalse(TransactionSearch.amount(Money(1_250), matches: "250"))
        XCTAssertFalse(TransactionSearch.amount(Money(25), matches: "250"))
    }

    func testDecimalQueryMustEqualTheAmount() {
        XCTAssertTrue(TransactionSearch.amount(Money(dec("250.50")), matches: "250.50"))
        XCTAssertTrue(TransactionSearch.amount(Money(dec("250.50")), matches: "250.5"))
        XCTAssertTrue(TransactionSearch.amount(Money(250), matches: "250.00"))
        XCTAssertFalse(TransactionSearch.amount(Money(dec("250.55")), matches: "250.5"))
        XCTAssertFalse(TransactionSearch.amount(Money(dec("250.50")), matches: "250.505"))
        XCTAssertEqual(TransactionSearch.plainAmount(Money(dec("642.75"))), "642.75")
        XCTAssertEqual(TransactionSearch.plainAmount(Money(1_850)), "1850.00")
    }

    // MARK: Text search and filters

    func testSearchMatchesCategoryAccountsNoteReferenceAndAmount() throws {
        let h = try LedgerHarness()
        let gcash = try h.account("GCash", opening: 1_000, kind: .eWallet)
        let pnb = try h.account("PNB", opening: 5_000)
        let food = try h.expenseCategory("Food")
        let lunch = try h.ledger.record(
            TransactionDraft(kind: .expense, amount: dec("250.50"), occurredAt: h.clock.now, accountID: gcash.id, categoryID: food.id, note: "Lunch with Ana", reference: "OR-1234")
        )
        let transfer = try h.ledger.recordTransfer(amount: 500, fromAccountID: pnb.id, toAccountID: gcash.id)

        for query in ["food", "GCash", "lunch", "or-1234", "250", "250.5", "₱250.50", "  Expense "] {
            XCTAssertTrue(TransactionSearch.matches(lunch, query: query, locale: posix), "Expected “\(query)” to match")
        }
        XCTAssertTrue(TransactionSearch.matches(lunch, query: "", locale: posix))
        XCTAssertFalse(TransactionSearch.matches(lunch, query: "PNB", locale: posix))
        XCTAssertFalse(TransactionSearch.matches(lunch, query: "25", locale: posix))

        XCTAssertTrue(TransactionSearch.matches(transfer, query: "pnb", locale: posix), "Source account")
        XCTAssertTrue(TransactionSearch.matches(transfer, query: "gcash", locale: posix), "Destination account")
        XCTAssertTrue(TransactionSearch.matches(transfer, query: "transfer", locale: posix))
        XCTAssertFalse(TransactionSearch.matches(transfer, query: "food", locale: posix))
    }

    func testFilterByTypeAndAccountIncludesBothSidesOfTransfers() throws {
        let h = try LedgerHarness()
        let gcash = try h.account("GCash", opening: 1_000, kind: .eWallet)
        let pnb = try h.account("PNB", opening: 5_000)
        let maya = try h.account("Maya", opening: 300, kind: .eWallet)
        let food = try h.expenseCategory("Food")
        let salary = try h.incomeSource("Salary")
        let expense = try h.ledger.recordExpense(amount: 250, accountID: gcash.id, categoryID: food.id)
        let income = try h.ledger.recordIncome(amount: 25_000, accountID: pnb.id, sourceID: salary.id)
        let transfer = try h.ledger.recordTransfer(amount: 500, fromAccountID: pnb.id, toAccountID: gcash.id)

        var filter = TransactionFilter()
        XCTAssertFalse(filter.isActive)
        XCTAssertTrue([expense, income, transfer].allSatisfy { filter.includes($0) })

        filter.type = .expenses
        XCTAssertTrue(filter.isActive)
        XCTAssertEqual([expense, income, transfer].filter { filter.includes($0) }.map(\.id), [expense.id])

        filter.type = .all
        filter.accountID = gcash.id
        XCTAssertEqual(Set([expense, income, transfer].filter { filter.includes($0) }.map(\.id)), [expense.id, transfer.id])

        filter.accountID = pnb.id
        XCTAssertEqual(Set([expense, income, transfer].filter { filter.includes($0) }.map(\.id)), [income.id, transfer.id])

        filter.type = .transfers
        filter.accountID = maya.id
        XCTAssertTrue([expense, income, transfer].filter { filter.includes($0) }.isEmpty)

        filter.clear()
        XCTAssertFalse(filter.isActive)
    }

    // MARK: Day grouping

    func testGroupsByLocalDayNewestFirst() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Manila"))
        let h = try LedgerHarness()
        let wallet = try h.account("Wallet", opening: 1_000, kind: .cash)
        let jeep = try h.expenseCategory("Jeep")
        // 2026-03-15 10:00 in Manila.
        let morning = TestClock.referenceDate
        let lateSameDay = morning.addingTimeInterval(13 * 3_600)
        let nextDay = morning.addingTimeInterval(15 * 3_600)
        for date in [morning, lateSameDay, nextDay] {
            try h.ledger.recordExpense(amount: 13, accountID: wallet.id, categoryID: jeep.id, occurredAt: date)
        }

        let days = TransactionDay.group(try h.ledger.transactions(), calendar: calendar)

        XCTAssertEqual(days.map(\.transactions.count), [1, 2])
        XCTAssertEqual(days.first?.transactions.first?.occurredAt, nextDay)
        XCTAssertEqual(days.last?.transactions.map(\.occurredAt), [lateSameDay, morning], "Each day keeps the given order")
    }

    func testDayTitles() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "Asia/Manila"))
        let now = TestClock.referenceDate
        let day: TimeInterval = 86_400

        XCTAssertEqual(TransactionDay.title(for: now, now: now, calendar: calendar), "Today")
        XCTAssertEqual(TransactionDay.title(for: now.addingTimeInterval(-day), now: now, calendar: calendar), "Yesterday")
        XCTAssertFalse(TransactionDay.title(for: now.addingTimeInterval(-3 * day), now: now, calendar: calendar).contains("2026"))
        XCTAssertTrue(TransactionDay.title(for: now.addingTimeInterval(-200 * day), now: now, calendar: calendar).contains("2025"))
    }

    // MARK: Editor validation

    func testEditorDraftRequiresAmountAndKindSpecificSelections() {
        let account = UUID()
        let other = UUID()
        let category = UUID()
        var form = TransactionEditorForm(kind: .expense, occurredAt: TestClock.referenceDate, accountID: account)
        XCTAssertNil(form.draft, "No amount yet")

        form.amount = 0
        form.categoryID = category
        XCTAssertNil(form.draft, "Zero amount")

        form.amount = dec("250.50")
        XCTAssertEqual(form.draft?.categoryID, category)
        XCTAssertNil(form.draft?.destinationAccountID)

        form.kind = .transfer
        form.destinationAccountID = account
        XCTAssertNil(form.draft, "Same source and destination")

        form.destinationAccountID = other
        XCTAssertEqual(form.draft?.destinationAccountID, other)
        XCTAssertNil(form.draft?.categoryID, "Transfers never carry a category")

        form.accountID = nil
        XCTAssertNil(form.draft, "No source account")
    }

    func testEditorFormRoundTripsAnExistingDraft() {
        let draft = TransactionDraft(
            kind: .income,
            amount: 25_000,
            occurredAt: TestClock.referenceDate,
            accountID: UUID(),
            categoryID: UUID(),
            note: "October",
            reference: "PAY-10"
        )
        let form = TransactionEditorForm(draft)
        XCTAssertEqual(form.note, "October")
        XCTAssertEqual(form.draft, draft, "Editing without changes keeps every field, including the reference")
    }
}
