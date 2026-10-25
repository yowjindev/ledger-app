import Foundation
import SwiftData
import XCTest
@testable import Ledger

/// Lists show each moment's automatic interest and tax entries as one row, placed where the
/// entries would have appeared, and break it down per account on tap.
@MainActor
final class InterestHistoryTests: XCTestCase {
    private let terms = InterestTerms(annualRate: Rate(partsPerMillion: 32_500), taxRate: InterestTerms.defaultTaxRate)

    private struct Fixture {
        let h: LedgerHarness
        let savings: Account
        let reserve: Account
        let wallet: Account
    }

    /// Savings (₱40,000) and Reserve (₱25,000) earn interest; Wallet doesn't. Wallet has an expense
    /// on March 16 at 09:00 and one on March 15 at 12:00 (Manila), and March 15's interest is posted.
    private func fixture() throws -> Fixture {
        let h = try LedgerHarness(calendar: try fixedCalendar("Asia/Manila"))
        let savings = try h.account("Savings", opening: 40_000)
        let reserve = try h.account("Reserve", opening: 25_000)
        let wallet = try h.account("Wallet", opening: 1_000, kind: .cash)
        let food = try h.expenseCategory("Food")
        try h.ledger.setInterest(terms, for: savings)
        try h.ledger.setInterest(terms, for: reserve)
        try h.ledger.recordExpense(amount: 50, accountID: wallet.id, categoryID: food.id, occurredAt: try instant("2026-03-16T01:00:00Z"))
        try h.ledger.recordExpense(amount: 20, accountID: wallet.id, categoryID: food.id, occurredAt: try instant("2026-03-15T04:00:00Z"))
        h.clock.now = try instant("2026-03-16T02:00:00Z")
        try h.ledger.postDueInterest()
        return Fixture(h: h, savings: savings, reserve: reserve, wallet: wallet)
    }

    private func shape(_ items: [HistoryItem]) -> [String] {
        items.map { item in
            switch item {
            case .transaction(let transaction, _): "transaction \(transaction.amountMinor)"
            case .interest(let posting): "interest \(posting.entries.count)"
            }
        }
    }

    private struct NotAnInterestItem: Error {}

    private func posting(_ item: HistoryItem?) throws -> InterestPosting {
        guard case .interest(let posting) = item else { throw NotAnInterestItem() }
        return posting
    }

    func testInterestAndTaxPostedTogetherFormOneItem() throws {
        let f = try fixture()

        let items = HistoryItem.items(from: try f.h.ledger.transactions())

        XCTAssertEqual(shape(items), ["transaction 5000", "interest 4", "transaction 2000"])
        let interest = try posting(items[1])
        XCTAssertEqual(interest.postedAt, try instant("2026-03-15T17:00:00Z"))
        XCTAssertEqual(interest.net, Money(dec("2.90") + dec("1.81")))
        XCTAssertEqual(interest.accountNames, ["Reserve", "Savings"])
        XCTAssertEqual(Set(items.map(\.id)).count, 3)
    }

    func testAccountHistoryGroupsOnlyThatAccount() throws {
        let f = try fixture()
        let history = try f.h.ledger.transactions(involving: f.savings)

        let items = HistoryItem.items(from: history)

        XCTAssertEqual(shape(items), ["interest 2"])
        let interest = try posting(items.first)
        XCTAssertEqual(interest.net, Money(dec("2.90")))
        XCTAssertEqual(interest.accountNames, ["Savings"])
    }

    func testFilteredTypesKeepTheirSign() throws {
        let f = try fixture()
        let expenses = try f.h.ledger.transactions().filter { $0.kind == .expense }

        let items = HistoryItem.items(from: expenses)

        XCTAssertEqual(shape(items), ["transaction 5000", "interest 2", "transaction 2000"])
        XCTAssertEqual(try posting(items[1]).net, Money(-(dec("0.72") + dec("0.45"))))
    }

    func testPartialPostingsAreLabelledByWhatTheyHold() throws {
        let f = try fixture()
        let formatter = fixedFormatter()
        let history = try f.h.ledger.transactions(involving: f.savings)

        let whole = try posting(HistoryItem.items(from: history).first)
        XCTAssertEqual(whole.title, "Interest")
        XCTAssertEqual(whole.caption, "After tax")

        let interestOnly = try posting(HistoryItem.items(from: history.filter { $0.kind == .income }).first)
        XCTAssertEqual(interestOnly.title, "Interest")
        XCTAssertEqual(interestOnly.caption, "Income", "Gross interest is never called after tax")
        XCTAssertTrue(plainSpaces(interestOnly.accessibilityLabel(formatter: formatter)).hasPrefix("Interest, +₱3.62, Savings, "))

        let taxOnly = try posting(HistoryItem.items(from: history.filter { $0.kind == .expense }).first)
        XCTAssertEqual(taxOnly.title, "Withholding tax")
        XCTAssertEqual(taxOnly.caption, "Expense")
        XCTAssertTrue(plainSpaces(taxOnly.accessibilityLabel(formatter: formatter)).hasPrefix("Withholding tax, -₱0.72, Savings, "))
    }

    func testDifferentDaysStaySeparate() throws {
        let f = try fixture()
        f.h.clock.now = try instant("2026-03-16T17:00:00Z")
        try f.h.ledger.postDueInterest()

        let items = HistoryItem.items(from: try f.h.ledger.transactions())

        XCTAssertEqual(shape(items), ["interest 4", "transaction 5000", "interest 4", "transaction 2000"])
        XCTAssertEqual(try posting(items[0]).postedAt, try instant("2026-03-16T17:00:00Z"))
    }

    func testBreakdownPerAccount() throws {
        let f = try fixture()
        let interest = try posting(HistoryItem.items(from: try f.h.ledger.transactions())[1])

        let breakdown = interest.breakdown

        XCTAssertEqual(breakdown.map(\.accountName), ["Savings", "Reserve"], "Accounts in display order")
        let savings = breakdown[0]
        XCTAssertEqual(savings.accountID, f.savings.id)
        XCTAssertEqual(savings.balance, Money(40_000))
        XCTAssertEqual(savings.annualRate, Rate(partsPerMillion: 32_500))
        XCTAssertEqual(savings.taxRate, InterestTerms.defaultTaxRate)
        XCTAssertEqual(savings.gross, Money(dec("3.62")))
        XCTAssertEqual(savings.tax, Money(dec("0.72")))
        XCTAssertEqual(savings.net, Money(dec("2.90")))
        XCTAssertEqual(breakdown[1].net, Money(dec("1.81")))
        XCTAssertEqual(interest.breakdown(for: f.reserve.id).map(\.accountName), ["Reserve"])
    }

    func testRowTextReadsWithoutColor() throws {
        let f = try fixture()
        let interest = try posting(HistoryItem.items(from: try f.h.ledger.transactions())[1])
        let single = try posting(HistoryItem.items(from: try f.h.ledger.transactions(involving: f.savings)).first)
        let formatter = fixedFormatter()

        XCTAssertEqual(interest.accountLine, "2 accounts")
        XCTAssertEqual(single.accountLine, "Savings")
        XCTAssertEqual(plainSpaces(single.signedNetText(formatter: formatter)), "+₱2.90")
        XCTAssertTrue(plainSpaces(single.accessibilityLabel(formatter: formatter)).hasPrefix("Interest after tax, +₱2.90, Savings, "))
    }
}
