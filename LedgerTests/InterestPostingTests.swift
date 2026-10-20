import Foundation
import SwiftData
import XCTest
@testable import Ledger

/// Posting daily interest: each completed day's interest and withholding tax, dated 1:00 the next
/// day, caught up in one save whenever Ledger runs, never twice.
///
/// Every test uses Manila time. The harness clock starts at 2026-03-15 10:00 Manila, when interest
/// is turned on, so March 15 is the first day that earns.
@MainActor
final class InterestPostingTests: XCTestCase {
    private let terms = InterestTerms(annualRate: Rate(partsPerMillion: 32_500), taxRate: InterestTerms.defaultTaxRate)
    private let fourPercent = InterestTerms(annualRate: Rate(partsPerMillion: 40_000), taxRate: InterestTerms.defaultTaxRate)
    private let formatter = fixedFormatter()

    /// A Manila harness with "Savings" holding ₱40,000 and earning 3.25% with 20% tax.
    private func savingsHarness() throws -> (LedgerHarness, Account) {
        let h = try LedgerHarness(calendar: try fixedCalendar("Asia/Manila"))
        let savings = try h.account("Savings", opening: 40_000)
        try h.ledger.setInterest(terms, for: savings)
        return (h, savings)
    }

    private func setNow(_ h: LedgerHarness, _ text: String) throws {
        h.clock.now = try instant(text)
    }

    /// Automatic entries, oldest first, interest before its tax.
    private func interestEntries(_ h: LedgerHarness, for account: Account? = nil) throws -> [LedgerTransaction] {
        try h.ledger.transactions()
            .filter { $0.origin == .interest && (account == nil || $0.account?.id == account?.id) }
            .sorted { ($0.occurredAt, $0.kind == .income ? 0 : 1) < ($1.occurredAt, $1.kind == .income ? 0 : 1) }
    }

    // MARK: Posting

    func testNothingPostsBeforeOneAM() throws {
        let (h, savings) = try savingsHarness()
        try setNow(h, "2026-03-15T16:59:00Z")

        XCTAssertEqual(try h.ledger.postDueInterest(), 0)
        XCTAssertEqual(try h.transactionCount(), 0)
        XCTAssertEqual(savings.interestPaidThrough, 20_260_314)
    }

    func testFirstDayPostsInterestAndTaxAtOneAM() throws {
        let (h, savings) = try savingsHarness()
        try setNow(h, "2026-03-15T17:00:00Z")

        XCTAssertEqual(try h.ledger.postDueInterest(), 2)

        let entries = try interestEntries(h)
        XCTAssertEqual(entries.count, 2)
        let interest = entries[0]
        XCTAssertEqual(interest.kind, .income)
        XCTAssertEqual(interest.amountMinor, 362)
        XCTAssertEqual(interest.occurredAt, try instant("2026-03-15T17:00:00Z"))
        XCTAssertEqual(interest.basisMinor, 4_000_000)
        XCTAssertEqual(interest.basisRatePPM, 32_500)
        XCTAssertNil(interest.category)
        XCTAssertEqual(interest.account?.id, savings.id)
        let tax = entries[1]
        XCTAssertEqual(tax.kind, .expense)
        XCTAssertEqual(tax.amountMinor, 72)
        XCTAssertEqual(tax.occurredAt, interest.occurredAt)
        XCTAssertEqual(tax.basisMinor, 362)
        XCTAssertEqual(tax.basisRatePPM, 200_000)
        XCTAssertEqual(try h.balance(savings), dec("40002.90"))
        XCTAssertEqual(savings.interestPaidThrough, 20_260_315)
        let summary = try h.ledger.periodSummary(for: h.allTime)
        XCTAssertEqual(summary.income, Money(dec("3.62")), "Interest counts as income")
        XCTAssertEqual(summary.expenses, Money(dec("0.72")), "Tax counts as an expense")
    }

    func testCatchUpPostsEveryMissedDayCompounding() throws {
        let (h, savings) = try savingsHarness()
        try setNow(h, "2026-03-18T17:00:00Z")

        XCTAssertEqual(try h.ledger.postDueInterest(), 8)

        let interest = try interestEntries(h).filter { $0.kind == .income }
        XCTAssertEqual(interest.map(\.basisMinor), [4_000_000, 4_000_290, 4_000_580, 4_000_870])
        XCTAssertEqual(try h.balance(savings), dec("40011.60"))
        XCTAssertEqual(savings.interestPaidThrough, 20_260_318)
    }

    func testRunningTwiceNeverPostsTwice() throws {
        let (h, _) = try savingsHarness()
        try setNow(h, "2026-03-16T17:00:00Z")

        XCTAssertEqual(try h.ledger.postDueInterest(), 4)
        XCTAssertEqual(try h.ledger.postDueInterest(), 0)
        XCTAssertEqual(try h.transactionCount(), 4)
    }

    func testUnknownZeroAndNegativeBalancesEarnNothingButCountAsDone() throws {
        let h = try LedgerHarness(calendar: try fixedCalendar("Asia/Manila"))
        let unknown = try h.account("Unknown", opening: nil)
        let empty = try h.account("Empty", opening: 0)
        let overdrawn = try h.account("Overdrawn", opening: 100)
        let food = try h.expenseCategory("Food")
        try h.ledger.recordExpense(amount: 150, accountID: overdrawn.id, categoryID: food.id, occurredAt: try instant("2026-03-15T03:00:00Z"))
        for account in [unknown, empty, overdrawn] {
            try h.ledger.setInterest(terms, for: account)
        }
        try setNow(h, "2026-03-15T17:00:00Z")

        XCTAssertEqual(try h.ledger.postDueInterest(), 0)
        XCTAssertEqual([unknown, empty, overdrawn].map(\.interestPaidThrough), [20_260_315, 20_260_315, 20_260_315])

        try h.ledger.setOpeningBalance(1_000, for: unknown)
        try setNow(h, "2026-03-16T17:00:00Z")
        XCTAssertEqual(try h.ledger.postDueInterest(), 2, "Only March 16 for the account whose balance is now known")
        let entries = try interestEntries(h)
        XCTAssertEqual(entries.map(\.account?.id), [unknown.id, unknown.id])
        XCTAssertEqual(entries.map(\.amountMinor), [10, 2])
        XCTAssertEqual(entries.first?.occurredAt, try instant("2026-03-16T17:00:00Z"))
    }

    func testZeroTaxPostsOnlyInterest() throws {
        let h = try LedgerHarness(calendar: try fixedCalendar("Asia/Manila"))
        let savings = try h.account("Savings", opening: 40_000)
        try h.ledger.setInterest(InterestTerms(annualRate: terms.annualRate, taxRate: Rate(partsPerMillion: 0)), for: savings)
        try setNow(h, "2026-03-15T17:00:00Z")

        XCTAssertEqual(try h.ledger.postDueInterest(), 1)
        let entries = try interestEntries(h)
        XCTAssertEqual(entries.map(\.kind), [.income])
        XCTAssertEqual(entries.map(\.amountMinor), [362])
    }

    func testBackdatedEntriesDontChangePostedInterest() throws {
        let (h, savings) = try savingsHarness()
        let food = try h.expenseCategory("Food")
        try setNow(h, "2026-03-15T17:00:00Z")
        try h.ledger.postDueInterest()

        try h.ledger.recordExpense(amount: 10_000, accountID: savings.id, categoryID: food.id, occurredAt: try instant("2026-03-15T08:00:00Z"))

        XCTAssertEqual(try h.ledger.postDueInterest(), 0)
        XCTAssertEqual(try interestEntries(h).map(\.amountMinor), [362, 72])
        XCTAssertEqual(try h.balance(savings), dec("30002.90"))
    }

    func testSixtyDaysAwayPostEveryDayInOneSave() throws {
        let (h, savings) = try savingsHarness()
        try setNow(h, "2026-05-13T17:00:00Z")
        var saves = 0
        let counting = LedgerService(
            context: h.context,
            clock: { [clock = h.clock] in clock.now },
            calendar: try fixedCalendar("Asia/Manila"),
            persist: { saves += 1; try $0.save() }
        )

        XCTAssertEqual(try counting.postDueInterest(), 120)
        XCTAssertEqual(saves, 1)
        XCTAssertEqual(savings.interestPaidThrough, 20_260_513)
        let interest = try interestEntries(h).filter { $0.kind == .income }
        XCTAssertEqual(interest.count, 60)
        XCTAssertEqual(interest.last?.occurredAt, try instant("2026-05-13T17:00:00Z"))
        XCTAssertEqual(Set(interest.map(\.occurredAt)).count, 60, "One posting per day")
    }

    func testChangingTimeZoneNeverPostsADayTwice() throws {
        let (h, savings) = try savingsHarness()
        try setNow(h, "2026-03-15T17:00:00Z")
        try h.ledger.postDueInterest()
        let utc = LedgerService(context: h.context, clock: { [clock = h.clock] in clock.now }, calendar: try fixedCalendar("UTC"))
        try setNow(h, "2026-03-17T02:00:00Z")

        XCTAssertEqual(try utc.postDueInterest(), 2, "Only March 16; March 15 was already posted")
        let interest = try interestEntries(h).filter { $0.kind == .income }
        XCTAssertEqual(interest.map(\.occurredAt), [try instant("2026-03-15T17:00:00Z"), try instant("2026-03-17T01:00:00Z")])
        XCTAssertEqual(savings.interestPaidThrough, 20_260_316)
    }

    // MARK: Changing settings

    func testTurningOnStartsWithToday() throws {
        let (h, savings) = try savingsHarness()

        XCTAssertEqual(savings.interestTerms, terms)
        XCTAssertEqual(savings.interestRatePPM, 32_500)
        XCTAssertEqual(savings.interestTaxRatePPM, 200_000)
        XCTAssertEqual(savings.interestPaidThrough, 20_260_314)
        XCTAssertEqual(try h.transactionCount(), 0)
    }

    func testRateChangePostsEarlierDaysAtTheOldRate() throws {
        let (h, savings) = try savingsHarness()
        try setNow(h, "2026-03-17T01:00:00Z")

        try h.ledger.setInterest(fourPercent, for: savings)

        XCTAssertEqual(try interestEntries(h).filter { $0.kind == .income }.map(\.basisRatePPM), [32_500, 32_500])
        XCTAssertEqual(savings.interestRatePPM, 40_000)
        XCTAssertEqual(savings.interestPaidThrough, 20_260_316)
        try setNow(h, "2026-03-17T17:00:00Z")
        XCTAssertEqual(try h.ledger.postDueInterest(), 2)
        XCTAssertEqual(try interestEntries(h).filter { $0.kind == .income }.last?.basisRatePPM, 40_000)
    }

    func testRateChangeBeforeOneAMAppliesToTheDayThatJustEnded() throws {
        let (h, savings) = try savingsHarness()
        try setNow(h, "2026-03-15T16:30:00Z")

        try h.ledger.setInterest(fourPercent, for: savings)
        XCTAssertEqual(try h.transactionCount(), 0)

        try setNow(h, "2026-03-15T17:00:00Z")
        XCTAssertEqual(try h.ledger.postDueInterest(), 2)
        XCTAssertEqual(try interestEntries(h).first?.basisRatePPM, 40_000)
    }

    func testTurningOffPostsDueDaysThenStops() throws {
        let (h, savings) = try savingsHarness()
        try setNow(h, "2026-03-17T01:00:00Z")

        try h.ledger.setInterest(nil, for: savings)

        XCTAssertEqual(try interestEntries(h).count, 4)
        XCTAssertNil(savings.interestTerms)
        XCTAssertNil(savings.interestRatePPM)
        XCTAssertNil(savings.interestPaidThrough)
        try setNow(h, "2026-03-20T17:00:00Z")
        XCTAssertEqual(try h.ledger.postDueInterest(), 0)
    }

    func testTurningBackOnNeverFillsSkippedDays() throws {
        let (h, savings) = try savingsHarness()
        try setNow(h, "2026-03-17T01:00:00Z")
        try h.ledger.setInterest(nil, for: savings)
        try setNow(h, "2026-03-20T01:00:00Z")

        try h.ledger.setInterest(terms, for: savings)
        XCTAssertEqual(savings.interestPaidThrough, 20_260_319)

        try setNow(h, "2026-03-20T17:00:00Z")
        XCTAssertEqual(try h.ledger.postDueInterest(), 2)
        XCTAssertEqual(try interestEntries(h).last?.occurredAt, try instant("2026-03-20T17:00:00Z"))
    }

    func testArchivingTurnsInterestOffAndUnarchivingLeavesItOff() throws {
        let (h, savings) = try savingsHarness()
        try setNow(h, "2026-03-17T01:00:00Z")

        try h.ledger.archiveAccount(savings)

        XCTAssertTrue(savings.isArchived)
        XCTAssertEqual(try interestEntries(h).count, 4, "Days due before archiving are posted")
        XCTAssertNil(savings.interestTerms)
        try h.ledger.unarchiveAccount(savings)
        XCTAssertNil(savings.interestTerms)
        try setNow(h, "2026-03-20T17:00:00Z")
        XCTAssertEqual(try h.ledger.postDueInterest(), 0)
    }

    func testArchivedAccountsCantStartEarning() throws {
        let h = try LedgerHarness(calendar: try fixedCalendar("Asia/Manila"))
        let savings = try h.account("Savings", opening: 40_000)
        try h.ledger.archiveAccount(savings)

        assertThrowsLedgerError(.accountArchived(name: "Savings")) { try h.ledger.setInterest(terms, for: savings) }
        XCTAssertNil(savings.interestTerms)
    }

    // MARK: Failures

    func testFailedCatchUpLeavesNoTraceAndRetries() throws {
        let (h, savings) = try savingsHarness()
        try setNow(h, "2026-03-15T17:00:00Z")

        h.assertSaveFails { try $0.postDueInterest() }

        XCTAssertEqual(try h.transactionCount(), 0)
        XCTAssertEqual(savings.interestPaidThrough, 20_260_314)
        XCTAssertEqual(try h.ledger.postDueInterest(), 2)
    }

    func testFailedInterestChangeKeepsTheOldTerms() throws {
        let (h, savings) = try savingsHarness()

        h.assertSaveFails { try $0.setInterest(nil, for: savings) }
        h.assertSaveFails { try $0.setInterest(fourPercent, for: savings) }

        XCTAssertEqual(savings.interestTerms, terms)
        XCTAssertEqual(savings.interestPaidThrough, 20_260_314)
    }

    // MARK: Other entry points

    func testUpdateBalancePostsDueInterestBeforeMeasuring() throws {
        let (h, savings) = try savingsHarness()
        try setNow(h, "2026-03-15T17:00:00Z")

        XCTAssertEqual(try h.ledger.updateBalance(of: savings, to: dec("40010")), .adjustment(Money(dec("7.10"))))
        XCTAssertEqual(try h.balance(savings), dec("40010"))
        XCTAssertEqual(try h.transactionCount(), 3)
    }

    func testInterestEntriesAreNotEditableAndNamed() throws {
        let (h, _) = try savingsHarness()
        try setNow(h, "2026-03-15T17:00:00Z")
        try h.ledger.postDueInterest()
        let entries = try interestEntries(h)
        let interest = entries[0], tax = entries[1]

        XCTAssertFalse(interest.isEditable)
        XCTAssertFalse(tax.isEditable)
        XCTAssertNil(TransactionDraft(interest))
        let draft = TransactionDraft(kind: .income, amount: 1, occurredAt: h.clock.now, accountID: interest.account?.id)
        assertThrowsLedgerError(.entryNotEditable) { try h.ledger.update(interest, with: draft) }

        let interestSummary = TransactionSummary(interest)
        XCTAssertEqual(interestSummary.title, "Interest")
        XCTAssertEqual(interestSummary.symbolName, "percent")
        XCTAssertEqual(plainSpaces(interestSummary.signedAmountText(formatter: formatter)), "+₱3.62")
        let taxSummary = TransactionSummary(tax)
        XCTAssertEqual(taxSummary.title, "Withholding tax")
        XCTAssertEqual(taxSummary.symbolName, "percent")
        XCTAssertEqual(plainSpaces(taxSummary.signedAmountText(formatter: formatter)), "-₱0.72")
        XCTAssertTrue(TransactionSearch.matches(interest, query: "interest"))
        XCTAssertTrue(TransactionSearch.matches(tax, query: "withholding"))
    }
}
