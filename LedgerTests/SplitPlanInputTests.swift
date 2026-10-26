import Foundation
import XCTest
@testable import Ledger

/// What the split and plan editors pass on: a one-month plan has no different last payment.
@MainActor
final class SplitPlanInputTests: XCTestCase {
    func testOneMonthSplitIgnoresADifferentLastPayment() {
        let split = SplitPlanInput(isOn: true, months: 1, monthly: 1_050, hasDifferentLast: true, last: nil)
        XCTAssertTrue(split.isComplete)
        let draft = TransactionDraft.expense(
            amount: 1_000, accountID: UUID(), categoryID: UUID(), occurredAt: TestClock.referenceDate, note: nil
        )
        XCTAssertEqual(split.purchase(from: draft)?.months, 1)
        XCTAssertNil(split.purchase(from: draft)?.last)
    }

    func testOneMonthPlanIgnoresADifferentLastPayment() {
        let nextDue = CalendarDay(year: 2026, month: 4, day: 5)
        var payments = PlanPaymentsInput(title: "Earbuds", monthly: 1_050, hasDifferentLast: true, last: 900, months: 1)
        XCTAssertNil(payments.terms(nextDue: nextDue)?.last)
        payments.months = 2
        XCTAssertEqual(payments.terms(nextDue: nextDue)?.last, 900)
    }

    // MARK: Filling in the payment

    private let english = Locale(identifier: "en_US")

    func testSplitPaymentIsThePriceSplitEvenlyPlusTheMonthlyFee() {
        let fivePercent = Rate(partsPerMillion: 50_000)
        XCTAssertEqual(LedgerService.splitPayment(price: 1_000, months: 3, feeRate: fivePercent), dec("383.33"))
        XCTAssertEqual(LedgerService.splitPayment(price: 1_000, months: 1, feeRate: fivePercent), 1_050)
        XCTAssertEqual(LedgerService.splitPayment(price: dec("250.30"), months: 1, feeRate: fivePercent), dec("262.82"))
        XCTAssertEqual(LedgerService.splitPayment(price: dec("200.05"), months: 2, feeRate: Rate(partsPerMillion: 0)), dec("100.03"))
    }

    func testPaymentFillsInFromPriceMonthsAndFee() {
        var split = SplitPlanInput(isOn: true, months: 3, feeText: "5")
        split.fillPayment(price: 1_000, locale: english)
        XCTAssertEqual(split.monthly, dec("383.33"))
        split.months = 1
        split.fillPayment(price: 1_000, locale: english)
        XCTAssertEqual(split.monthly, 1_050)
        split.feeText = "0"
        split.fillPayment(price: 1_000, locale: english)
        XCTAssertEqual(split.monthly, 1_000)
    }

    func testTypedPaymentIsKeptUntilCleared() {
        var split = SplitPlanInput(isOn: true, months: 1, feeText: "5")
        split.fillPayment(price: 1_000, locale: english)
        split.editPayment(1_050)
        split.fillPayment(price: 2_000, locale: english)
        XCTAssertEqual(split.monthly, 2_100, "the field echoing the filled-in amount isn't an edit")

        split.editPayment(2_090)
        split.fillPayment(price: 3_000, locale: english)
        XCTAssertEqual(split.monthly, 2_090)

        split.editPayment(nil)
        split.fillPayment(price: 3_000, locale: english)
        XCTAssertEqual(split.monthly, 3_150)
    }

    func testNoFeeOrPriceLeavesThePaymentAlone() {
        var split = SplitPlanInput(isOn: true, months: 2)
        split.fillPayment(price: 1_000, locale: english)
        XCTAssertNil(split.monthly)
        split.feeText = "5"
        split.fillPayment(price: nil, locale: english)
        XCTAssertNil(split.monthly)
        split.feeText = "150"
        split.fillPayment(price: 1_000, locale: english)
        XCTAssertNil(split.monthly)
    }

    func testFeeRateTextFromTheAccount() {
        var split = SplitPlanInput()
        split.setFeeRate(Rate(partsPerMillion: 50_000), locale: english)
        XCTAssertEqual(split.feeText, "5")
        split.setFeeRate(nil, locale: english)
        XCTAssertEqual(split.feeText, "")
    }
}
