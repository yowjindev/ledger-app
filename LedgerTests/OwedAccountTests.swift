import Foundation
import SwiftData
import XCTest
@testable import Ledger

/// Credit cards, pay later accounts, and loans: what they owe, how purchases and payments move
/// it, and how they stay apart from money the user has.
@MainActor
final class OwedAccountTests: XCTestCase {
    private func harness() throws -> LedgerHarness {
        try LedgerHarness(calendar: try fixedCalendar("Asia/Manila"))
    }

    @discardableResult
    private func card(
        _ h: LedgerHarness,
        owed: Decimal,
        statementDay: Int = 5,
        dueDay: Int = 25,
        stillDue: Decimal? = 0
    ) throws -> Account {
        try h.ledger.createOwedAccount(
            name: "Visa card",
            kind: .creditCard,
            terms: OwedTerms(statementDay: statementDay, dueDay: dueDay),
            owedNow: owed,
            stillDue: stillDue
        )
    }

    private func thisMonth(_ h: LedgerHarness) -> DateInterval {
        ReportingPeriod.thisMonth.interval(containing: h.clock.now, calendar: h.ledger.calendar)
    }

    func testOwedKindsStayOutOfTheLiquidTotal() throws {
        let h = try harness()
        let bank = try h.account("Bank", opening: 10_000)
        let visa = try card(h, owed: 2_500)

        let sheet = try h.ledger.balanceSheet()
        XCTAssertEqual(sheet.liquidTotal.total.amount, 10_000)
        XCTAssertEqual(sheet.liquidTotal.includedAccountIDs, [bank.id])
        XCTAssertEqual(sheet.moneyBalances.map(\.id), [bank.id])
        XCTAssertEqual(sheet.owedBalances.map(\.id), [visa.id])
        XCTAssertEqual(sheet.totalOwed.amount, 2_500)
        XCTAssertEqual(try h.balance(visa), -2_500)
        XCTAssertEqual(sheet.balance(for: visa.id)?.owed?.amount, 2_500)
        XCTAssertEqual(visa.statementDay, 5)
        XCTAssertEqual(visa.dueDay, 25)
    }

    func testCardPurchaseRaisesOwedAndPaymentIsNotSpending() throws {
        let h = try harness()
        let bank = try h.account("Bank", opening: 10_000)
        let visa = try card(h, owed: 1_000)
        let food = try h.expenseCategory("Food")

        try h.ledger.record(.expense(amount: 500, accountID: visa.id, categoryID: food.id, occurredAt: h.clock.now))
        XCTAssertEqual(try h.ledger.balance(of: visa)?.owed?.amount, 1_500)

        try h.ledger.record(.transfer(amount: 1_500, fromAccountID: bank.id, toAccountID: visa.id, occurredAt: h.clock.now))
        XCTAssertEqual(try h.ledger.balance(of: visa)?.owed?.amount, 0)
        XCTAssertEqual(try h.balance(bank), 8_500)
        XCTAssertEqual(try h.ledger.periodSummary(for: thisMonth(h)).expenses.amount, 500)
    }

    func testStillDueIsStoredForTheWaitingStatement() throws {
        let h = try harness()
        let schedule = DueSchedule(statementDay: 5, dueDay: 25)
        XCTAssertEqual(h.ledger.awaitingDue(for: schedule), CalendarDay(year: 2026, month: 3, day: 25))

        let visa = try card(h, owed: 4_000, stillDue: 1_200)

        let overrides = try h.context.fetch(FetchDescriptor<DueOverride>())
        XCTAssertEqual(overrides.count, 1)
        XCTAssertEqual(overrides.first?.ownerID, visa.id)
        XCTAssertEqual(overrides.first?.cycle, 202603)
        XCTAssertEqual(overrides.first?.amountMinor, 120_000)
        XCTAssertNil(overrides.first?.movedTo)
        XCTAssertEqual(try h.balance(visa), -4_000)
    }

    func testStillDueIsRefusedWhenNoStatementIsWaiting() throws {
        let h = try harness()
        XCTAssertNil(h.ledger.awaitingDue(for: DueSchedule(statementDay: 20, dueDay: 10)))

        assertThrowsLedgerError(.stillDueNotApplicable) {
            try card(h, owed: 4_000, statementDay: 20, dueDay: 10, stillDue: 100)
        }
        XCTAssertTrue(try h.ledger.accounts().isEmpty)
    }

    func testStillDueIsRequiredWhileAStatementIsWaiting() throws {
        let h = try harness()
        assertThrowsLedgerError(.stillDueRequired) {
            try h.ledger.createOwedAccount(
                name: "Visa card", kind: .creditCard, terms: OwedTerms(statementDay: 5, dueDay: 25), owedNow: 3_000, stillDue: nil
            )
        }
        XCTAssertTrue(try h.ledger.accounts().isEmpty)

        let paid = try h.ledger.createOwedAccount(
            name: "Visa card", kind: .creditCard, terms: OwedTerms(statementDay: 5, dueDay: 25), owedNow: 3_000, stillDue: 0
        )
        XCTAssertEqual(try h.ledger.dueStatus(for: paid)?.isPaid, true)
    }

    func testStillDueCantExceedWhatIsOwed() throws {
        let h = try harness()
        assertThrowsLedgerError(.stillDueAboveOwed) {
            try card(h, owed: 1_000, stillDue: 1_200)
        }
        XCTAssertTrue(try h.ledger.accounts().isEmpty)
    }

    func testOwedAmountCanBeZeroButNotNegative() throws {
        let h = try harness()
        let visa = try card(h, owed: 0)
        XCTAssertEqual(try h.balance(visa), 0)

        assertThrowsLedgerError(.owedNegative) {
            try h.ledger.createOwedAccount(
                name: "PayLater",
                kind: .payLater,
                terms: OwedTerms(statementDay: 31, dueDay: 5),
                owedNow: -1,
                stillDue: nil
            )
        }
    }

    func testUpdateWhatYouOweRecordsAnAdjustment() throws {
        let h = try harness()
        let visa = try card(h, owed: 2_000)

        XCTAssertEqual(try h.ledger.owedCorrection(toOwe: 2_150, for: visa), .adjustment(Money(-150)))
        XCTAssertEqual(try h.ledger.owedCorrection(toOwe: 2_000, for: visa), .alreadyMatches)

        try h.ledger.updateOwed(of: visa, to: 2_150)
        XCTAssertEqual(try h.ledger.balance(of: visa)?.owed?.amount, 2_150)
        let summary = try h.ledger.periodSummary(for: thisMonth(h))
        XCTAssertEqual(summary.expenses.amount, 0)
        XCTAssertEqual(summary.income.amount, 0)

        try h.ledger.updateOwed(of: visa, to: 0)
        XCTAssertEqual(try h.ledger.balance(of: visa)?.owed?.amount, 0)
    }

    func testOverpaymentLeavesACredit() throws {
        let h = try harness()
        let bank = try h.account("Bank", opening: 10_000)
        let visa = try card(h, owed: 100)

        try h.ledger.record(.transfer(amount: 150, fromAccountID: bank.id, toAccountID: visa.id, occurredAt: h.clock.now))

        XCTAssertEqual(try h.ledger.balance(of: visa)?.owed?.amount, -50)
        XCTAssertEqual(try h.balance(visa), 50)
        XCTAssertEqual(try h.ledger.balanceSheet().totalOwed.amount, -50)
    }

    func testMoneyAndOwedGroupsCantBeSwapped() throws {
        let h = try harness()
        let bank = try h.account("Bank", opening: 10_000)
        let visa = try card(h, owed: 500)

        assertThrowsLedgerError(.wrongAccountGroup) {
            try h.ledger.createAccount(name: "Other card", kind: .creditCard, openingBalance: 0)
        }
        assertThrowsLedgerError(.wrongAccountGroup) {
            try h.ledger.updateAccount(bank, name: "Bank", kind: .creditCard, openingBalance: 10_000)
        }
        assertThrowsLedgerError(.wrongAccountGroup) {
            try h.ledger.updateAccount(visa, name: "Visa card", kind: .bank, openingBalance: 0)
        }
        assertThrowsLedgerError(.wrongAccountGroup) {
            try h.ledger.balanceCorrection(toReach: 5, for: visa)
        }
        assertThrowsLedgerError(.wrongAccountGroup) {
            try h.ledger.owedCorrection(toOwe: 5, for: bank)
        }
        assertThrowsLedgerError(.wrongAccountGroup) {
            try h.ledger.setInterest(
                InterestTerms(annualRate: Rate(partsPerMillion: 32_500), taxRate: InterestTerms.defaultTaxRate),
                for: visa
            )
        }
        assertThrowsLedgerError(.wrongAccountGroup) {
            try h.ledger.createOwedAccount(
                name: "Phone loan",
                kind: .loan,
                terms: OwedTerms(statementDay: nil, dueDay: 8),
                owedNow: 1_000,
                stillDue: nil
            )
        }
        assertThrowsLedgerError(.wrongAccountGroup) {
            try h.ledger.createOwedAccount(
                name: "Wallet",
                kind: .cash,
                terms: OwedTerms(statementDay: 5, dueDay: 25),
                owedNow: 0,
                stillDue: nil
            )
        }
        assertThrowsLedgerError(.wrongAccountGroup) {
            try h.ledger.applySetup([AccountSetupChoice(accountID: visa.id, isUsed: true, currentBalance: 100)])
        }
        XCTAssertEqual(try h.balance(visa), -500)
        XCTAssertEqual(try h.balance(bank), 10_000)
    }

    func testTermsAreValidated() throws {
        let h = try harness()
        func make(_ terms: OwedTerms, kind: AccountKind = .creditCard) throws -> Account {
            try h.ledger.createOwedAccount(name: "Card \(UUID().uuidString.prefix(6))", kind: kind, terms: terms, owedNow: 0, stillDue: 0)
        }

        assertThrowsLedgerError(.dayOutOfRange) { try make(OwedTerms(statementDay: 5, dueDay: 0)) }
        assertThrowsLedgerError(.dayOutOfRange) { try make(OwedTerms(statementDay: 5, dueDay: 32)) }
        assertThrowsLedgerError(.dayOutOfRange) { try make(OwedTerms(statementDay: 0, dueDay: 25)) }
        assertThrowsLedgerError(.statementDayRequired) { try make(OwedTerms(statementDay: nil, dueDay: 25)) }
        assertThrowsLedgerError(.cashbackNotOffered) {
            try make(OwedTerms(statementDay: 31, dueDay: 5, cashbackPercent: 1), kind: .payLater)
        }
        assertThrowsLedgerError(.cashbackRateOutOfRange) {
            try make(OwedTerms(statementDay: 5, dueDay: 25, cashbackPercent: 0))
        }
        assertThrowsLedgerError(.rateTooPrecise) {
            try make(OwedTerms(statementDay: 5, dueDay: 25, cashbackPercent: dec("1.00001")))
        }
        assertThrowsLedgerError(.owedNegative) {
            try make(OwedTerms(statementDay: 5, dueDay: 25, creditLimit: -1))
        }
        XCTAssertTrue(try h.ledger.accounts().isEmpty)

        let visa = try make(OwedTerms(statementDay: 5, dueDay: 25, creditLimit: 20_000, cashbackPercent: dec("2.5")))
        XCTAssertEqual(visa.cashbackRatePPM, 25_000)
        XCTAssertEqual(visa.creditLimitMinor, 2_000_000)
        XCTAssertEqual(visa.dueSchedule, DueSchedule(statementDay: 5, dueDay: 25))

        try h.ledger.updateOwedAccount(visa, name: "Visa", terms: OwedTerms(statementDay: 10, dueDay: 30))
        XCTAssertEqual(visa.name, "Visa")
        XCTAssertEqual(visa.dueSchedule, DueSchedule(statementDay: 10, dueDay: 30))
        XCTAssertNil(visa.cashbackRatePPM)
        XCTAssertNil(visa.creditLimitMinor)
    }

    func testFailedSaveLeavesNoOwedAccount() throws {
        let h = try harness()
        assertThrowsLedgerError(.persistenceFailed) {
            try h.failingLedger().createOwedAccount(
                name: "Visa card",
                kind: .creditCard,
                terms: OwedTerms(statementDay: 5, dueDay: 25),
                owedNow: 4_000,
                stillDue: 1_200
            )
        }
        XCTAssertTrue(try h.ledger.accounts(includeArchived: true).isEmpty)
        XCTAssertEqual(try h.context.fetchCount(FetchDescriptor<DueOverride>()), 0)
    }

    func testOwedKindsDescribeThemselves() {
        XCTAssertEqual(AccountKind.moneyKinds, [.cash, .bank, .eWallet, .other])
        XCTAssertEqual(AccountKind.owedKinds, [.creditCard, .payLater, .loan])
        XCTAssertTrue(AccountKind.owedKinds.allSatisfy(\.isOwed))
        XCTAssertFalse(AccountKind.moneyKinds.contains(where: \.isOwed))
        XCTAssertFalse(AccountKind.creditCard.countsTowardLiquidTotal)
        XCTAssertEqual(AccountKind.creditCard.title, "Credit card")
        XCTAssertEqual(AccountKind.payLater.title, "Pay later")
        XCTAssertEqual(AccountKind.loan.title, "Loan")
    }

    func testFeesUseLimitIsSavedForPayLaterOnly() throws {
        let h = try harness()
        let payLater = try h.ledger.createOwedAccount(
            name: "PayLater",
            kind: .payLater,
            terms: OwedTerms(statementDay: 31, dueDay: 5, creditLimit: 10_000, feesUseLimit: true),
            owedNow: 0,
            stillDue: nil
        )
        XCTAssertTrue(payLater.feesUseLimit)

        try h.ledger.updateOwedAccount(payLater, name: "PayLater", terms: OwedTerms(statementDay: 31, dueDay: 5, creditLimit: 10_000))
        XCTAssertFalse(payLater.feesUseLimit)

        let card = try h.ledger.createOwedAccount(
            name: "Visa card",
            kind: .creditCard,
            terms: OwedTerms(statementDay: 5, dueDay: 25, feesUseLimit: true),
            owedNow: 0,
            stillDue: 0
        )
        XCTAssertFalse(card.feesUseLimit)
    }
}
