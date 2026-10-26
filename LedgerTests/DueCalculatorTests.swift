import Foundation
import XCTest
@testable import Ledger

/// What's left to pay on each due of a credit card, pay later account, or loan, worked out from
/// its balance, entries, and plans alone.
final class DueCalculatorTests: XCTestCase {
    private let accountID = UUID()
    private let bankID = UUID()
    private var calendar = Calendar(identifier: .gregorian)

    override func setUpWithError() throws {
        calendar = try fixedCalendar("Asia/Manila")
    }

    // MARK: Fixtures

    private func day(_ year: Int, _ month: Int, _ day: Int) -> CalendarDay {
        CalendarDay(year: year, month: month, day: day)
    }

    private func month(_ year: Int, _ month: Int) -> CalendarMonth {
        CalendarMonth(year: year, month: month)
    }

    /// A Manila wall-clock time on a 2026 date, such as `at(3, 2)` for March 2 at 10:00.
    private func at(_ month: Int, _ day: Int, _ time: String = "10:00") throws -> Date {
        try instant(String(format: "2026-%02d-%02dT%@:00+08:00", month, day, time))
    }

    private func minor(_ amount: Decimal) -> Int64 {
        NSDecimalNumber(decimal: amount * 100).int64Value
    }

    private func expense(_ amount: Decimal, at date: Date, planID: UUID? = nil, origin: EntryOrigin = .app) -> Movement {
        Movement(
            kind: .expense, status: .posted, amountMinor: minor(amount), currency: .php,
            accountID: accountID, destinationAccountID: nil, occurredAt: date, origin: origin, planID: planID
        )
    }

    private func cashback(_ amount: Decimal, at date: Date) -> Movement {
        Movement(
            kind: .income, status: .posted, amountMinor: minor(amount), currency: .php,
            accountID: accountID, destinationAccountID: nil, occurredAt: date, origin: .cashback
        )
    }

    private func payment(_ amount: Decimal, at date: Date) -> Movement {
        Movement(
            kind: .transfer, status: .posted, amountMinor: minor(amount), currency: .php,
            accountID: bankID, destinationAccountID: accountID, occurredAt: date
        )
    }

    private func plan(
        monthly: Decimal,
        last: Decimal? = nil,
        months: Int,
        paidAtStart: Int = 0,
        firstDue: CalendarDay,
        feesMinor fees: Decimal = 0
    ) -> PlanSnapshot {
        PlanSnapshot(
            id: UUID(),
            accountID: accountID,
            monthlyMinor: minor(monthly),
            lastMinor: minor(last ?? monthly),
            months: months,
            paidAtStart: paidAtStart,
            firstDue: firstDue,
            feesMinor: minor(fees)
        )
    }

    private func input(
        _ kind: AccountKind,
        _ schedule: DueSchedule,
        opening: Decimal?,
        started: Date,
        movements: [Movement] = [],
        plans: [PlanSnapshot] = [],
        overrides: [DueOverrideSnapshot] = []
    ) -> OwedDueInput {
        let snapshot = AccountSnapshot(
            id: accountID, name: "Owed", kind: kind, currency: .php,
            openingBalanceMinor: opening.map(minor), isArchived: false, sortOrder: 0
        )
        let balance = BalanceCalculator.balances(accounts: [snapshot], movements: movements)[0]
        return OwedDueInput(
            balance: balance, schedule: schedule, startedAt: started,
            plans: plans, movements: movements, overrides: overrides
        )
    }

    private func left(_ cycle: CalendarMonth, _ input: OwedDueInput) -> Decimal? {
        DueCalculator.left(in: cycle, input, calendar: calendar)?.amount
    }

    private var card: DueSchedule { DueSchedule(statementDay: 5, dueDay: 25) }
    private var payLater: DueSchedule { DueSchedule(statementDay: 31, dueDay: 5) }

    // MARK: Loans

    private func partwayLoan(movements: [Movement] = []) throws -> OwedDueInput {
        input(
            .loan, DueSchedule(statementDay: nil, dueDay: 8),
            opening: -14_400, started: try at(3, 15), movements: movements,
            plans: [plan(monthly: 2_400, months: 12, paidAtStart: 6, firstDue: day(2026, 4, 8))]
        )
    }

    func testLoanLeftIsThisMonthsSlice() throws {
        let loan = try partwayLoan()
        XCTAssertEqual(left(month(2026, 4), loan), 2_400)

        let status = DueCalculator.status(loan, today: day(2026, 3, 15), calendar: calendar)
        XCTAssertEqual(status.owner, .account(accountID))
        XCTAssertEqual(status.cycle, month(2026, 4))
        XCTAssertEqual(status.dueDate, day(2026, 4, 8))
        XCTAssertEqual(status.originalDueDate, day(2026, 4, 8))
        XCTAssertEqual(status.left?.amount, 2_400)
        XCTAssertFalse(status.isOverdue)
        XCTAssertTrue(status.isStatementClosed)
        XCTAssertFalse(status.isPaid)
    }

    func testEarlyAndOverPaymentCount() throws {
        let loan = try partwayLoan(movements: [payment(3_000, at: try at(3, 20))])
        XCTAssertEqual(left(month(2026, 4), loan), 0)
        XCTAssertEqual(left(month(2026, 5), loan), 1_800)
        XCTAssertTrue(DueCalculator.status(loan, today: day(2026, 3, 21), calendar: calendar).isPaid)
    }

    // MARK: Credit cards

    func testCardLeftExcludesNextCycleCharges() throws {
        let visa = input(
            .creditCard, card, opening: 0, started: try at(2, 1),
            movements: [expense(1_000, at: try at(3, 2)), expense(400, at: try at(3, 10))]
        )
        XCTAssertEqual(left(month(2026, 3), visa), 1_000)

        let beforeClose = DueCalculator.status(visa, today: day(2026, 3, 3), calendar: calendar)
        XCTAssertEqual(beforeClose.cycle, month(2026, 3))
        XCTAssertFalse(beforeClose.isStatementClosed)
        let afterClose = DueCalculator.status(visa, today: day(2026, 3, 15), calendar: calendar)
        XCTAssertEqual(afterClose.cycle, month(2026, 3))
        XCTAssertTrue(afterClose.isStatementClosed)
        XCTAssertEqual(afterClose.left?.amount, 1_000)
    }

    func testCashbackOnNextCycleChargesIsNetted() throws {
        let visa = input(
            .creditCard, card, opening: 0, started: try at(2, 1),
            movements: [
                expense(1_000, at: try at(3, 2)),
                expense(400, at: try at(3, 10)),
                cashback(4, at: try at(3, 10)),
            ]
        )
        XCTAssertEqual(visa.balance.owed?.amount, 1_396)
        XCTAssertEqual(left(month(2026, 3), visa), 1_000)
    }

    func testCashAdvanceAfterCloseBelongsToNextCycle() throws {
        let advance = Movement(
            kind: .transfer, status: .posted, amountMinor: minor(5_000), currency: .php,
            accountID: accountID, destinationAccountID: bankID, occurredAt: try at(3, 10)
        )
        let raised = Movement(
            kind: .adjustment, status: .posted, amountMinor: minor(200), currency: .php,
            accountID: accountID, destinationAccountID: nil, occurredAt: try at(3, 11), direction: .decrease
        )
        let visa = input(
            .creditCard, card, opening: 0, started: try at(2, 20),
            movements: [expense(1_000, at: try at(3, 2)), advance, raised]
        )

        XCTAssertEqual(visa.balance.owed?.amount, 6_200)
        XCTAssertEqual(left(month(2026, 3), visa), 1_000)
        let status = DueCalculator.status(visa, today: day(2026, 3, 15), calendar: calendar)
        XCTAssertEqual(status.cycle, month(2026, 3))
        XCTAssertFalse(status.isOverdue)
        XCTAssertEqual(status.left?.amount, 1_000)
    }

    func testUnpaidDueBecomesOverdueAndCarries() throws {
        let visa = input(
            .creditCard, card, opening: 0, started: try at(2, 1),
            movements: [expense(1_000, at: try at(3, 2)), expense(400, at: try at(3, 10)), cashback(4, at: try at(3, 10))]
        )
        let status = DueCalculator.status(visa, today: day(2026, 3, 26), calendar: calendar)
        XCTAssertEqual(status.cycle, month(2026, 3))
        XCTAssertTrue(status.isOverdue)
        XCTAssertEqual(status.left?.amount, 1_000)
        XCTAssertEqual(left(month(2026, 4), visa), 1_396)
    }

    func testDuesBeforeTheStartAreIgnored() throws {
        let visa = input(.creditCard, card, opening: -1_000, started: try at(3, 26))
        let status = DueCalculator.status(visa, today: day(2026, 3, 26), calendar: calendar)
        XCTAssertEqual(status.cycle, month(2026, 4))
        XCTAssertFalse(status.isOverdue)
    }

    func testStillDueCoversTheFirstDue() throws {
        let override = DueOverrideSnapshot(ownerID: accountID, cycle: month(2026, 3), movedTo: nil, amountMinor: 120_000)
        let unpaid = input(.creditCard, card, opening: -5_000, started: try at(3, 10), overrides: [override])
        XCTAssertEqual(left(month(2026, 3), unpaid), 1_200)

        let paid = input(
            .creditCard, card, opening: -5_000, started: try at(3, 10),
            movements: [payment(1_200, at: try at(3, 12))], overrides: [override]
        )
        XCTAssertEqual(left(month(2026, 3), paid), 0)
        XCTAssertEqual(left(month(2026, 4), paid), 3_800)
    }

    func testMovedDueIsNotOverdueUntilTheNewDate() throws {
        let moved = DueOverrideSnapshot(ownerID: accountID, cycle: month(2026, 3), movedTo: day(2026, 3, 30), amountMinor: nil)
        let visa = input(
            .creditCard, card, opening: 0, started: try at(2, 1),
            movements: [expense(1_000, at: try at(3, 2))], overrides: [moved]
        )
        let status = DueCalculator.status(visa, today: day(2026, 3, 27), calendar: calendar)
        XCTAssertEqual(status.cycle, month(2026, 3))
        XCTAssertFalse(status.isOverdue)
        XCTAssertEqual(status.dueDate, day(2026, 3, 30))
        XCTAssertEqual(status.originalDueDate, day(2026, 3, 25))

        let afterMove = DueCalculator.status(visa, today: day(2026, 3, 31), calendar: calendar)
        XCTAssertEqual(afterMove.cycle, month(2026, 3))
        XCTAssertTrue(afterMove.isOverdue)
    }

    func testPurchaseLateOnStatementDayInLocalTimeBelongsToClosingCycle() throws {
        let visa = input(
            .creditCard, card, opening: 0, started: try at(2, 1),
            movements: [
                expense(300, at: try at(3, 5, "23:30")),
                expense(200, at: try at(3, 6, "00:30")),
            ]
        )
        XCTAssertEqual(left(month(2026, 3), visa), 300)
    }

    // MARK: Pay later

    func testPayLaterSplitSlicesStayOutOfTheCurrentDue() throws {
        let split = plan(monthly: 1_050, months: 3, firstDue: day(2026, 4, 5))
        let entries = [
            expense(3_000, at: try at(3, 10), planID: split.id),
            expense(150, at: try at(3, 10), planID: split.id, origin: .planFees),
            expense(500, at: try at(3, 12)),
        ]
        let unpaid = input(.payLater, payLater, opening: 0, started: try at(2, 1), movements: entries, plans: [split])
        XCTAssertEqual(unpaid.balance.owed?.amount, 3_650)
        XCTAssertEqual(left(month(2026, 4), unpaid), 1_550)

        let paid = input(
            .payLater, payLater, opening: 0, started: try at(2, 1),
            movements: entries + [payment(1_550, at: try at(4, 1))], plans: [split]
        )
        XCTAssertEqual(left(month(2026, 4), paid), 0)
        XCTAssertEqual(left(month(2026, 5), paid), 1_050)
    }

    func testMonthsPaidDoesNotShareOnePaymentBetweenPlans() throws {
        let first = plan(monthly: 500, months: 2, firstDue: day(2026, 4, 5))
        let second = plan(monthly: 500, months: 2, firstDue: day(2026, 4, 5))
        let pay = input(
            .payLater, payLater, opening: 0, started: try at(2, 1),
            movements: [
                expense(1_000, at: try at(3, 10), planID: first.id),
                expense(1_000, at: try at(3, 10), planID: second.id),
                payment(1_000, at: try at(4, 1)),
            ],
            plans: [first, second]
        )
        let today = day(2026, 4, 2)
        XCTAssertEqual(DueCalculator.monthsPaid(first, pay, today: today, calendar: calendar), 1)
        XCTAssertEqual(DueCalculator.monthsPaid(second, pay, today: today, calendar: calendar), 1)
    }

    func testSlicesEndWithTheLastPayment() {
        let uneven = plan(monthly: dec("333.33"), last: dec("333.34"), months: 3, firstDue: day(2026, 12, 5))
        XCTAssertEqual(uneven.slices.map(\.amountMinor), [33_333, 33_333, 33_334])
        XCTAssertEqual(uneven.slices.map(\.cycle), [month(2026, 12), month(2027, 1), month(2027, 2)])

        let partway = plan(monthly: 2_400, months: 12, paidAtStart: 6, firstDue: day(2026, 4, 8))
        XCTAssertEqual(partway.slices.count, 6)
        XCTAssertEqual(partway.slices.last?.cycle, month(2026, 9))
    }

    // MARK: Unknowns

    func testUnsetOpeningHasNoAmount() throws {
        let unknown = input(.creditCard, card, opening: nil, started: try at(2, 1))
        XCTAssertNil(left(month(2026, 3), unknown))
        XCTAssertNil(DueCalculator.status(unknown, today: day(2026, 3, 15), calendar: calendar).left)
    }

    // MARK: Limits

    private func limit(_ input: OwedDueInput, feesUseLimit: Bool = false, today: CalendarDay) -> LimitStatus? {
        DueCalculator.limitStatus(
            limitMinor: minor(10_000), balance: input.balance, input: input,
            feesUseLimit: feesUseLimit, today: today, calendar: calendar
        )
    }

    /// A ₱3,000 purchase split into 3 payments of ₱1,050, with ₱150 of fees.
    private func splitEntries(_ split: PlanSnapshot) throws -> [Movement] {
        [
            expense(3_000, at: try at(3, 10), planID: split.id),
            expense(150, at: try at(3, 10), planID: split.id, origin: .planFees),
        ]
    }

    func testUnpaidFeesShareRoundsThePaidPartDown() {
        XCTAssertEqual((0...3).map { DueCalculator.unpaidFees(feesMinor: 10_000, months: 3, monthsPaid: $0) }, [10_000, 6_667, 3_334, 0])
        XCTAssertEqual(DueCalculator.unpaidFees(feesMinor: 5_000, months: 1, monthsPaid: 0), 5_000)
        XCTAssertEqual(DueCalculator.unpaidFees(feesMinor: 5_000, months: 1, monthsPaid: 1), 0)
        XCTAssertEqual(DueCalculator.unpaidFees(feesMinor: 5_000, months: 1, monthsPaid: 2), 0)
    }

    func testLimitStatusLeavesUnpaidSplitFeesOut() throws {
        let split = plan(monthly: 1_050, months: 3, firstDue: day(2026, 4, 5))
        let entries = try splitEntries(split)

        let unpaid = try XCTUnwrap(limit(
            input(.payLater, payLater, opening: 0, started: try at(2, 1), movements: entries, plans: [split]),
            today: day(2026, 3, 20)
        ))
        XCTAssertEqual(unpaid.limit.amount, 10_000)
        XCTAssertEqual(unpaid.available?.amount, 7_000)
        XCTAssertEqual(unpaid.feesOffLimit.amount, 150)

        let onePaid = try XCTUnwrap(limit(
            input(
                .payLater, payLater, opening: 0, started: try at(2, 1),
                movements: entries + [payment(1_050, at: try at(4, 1))], plans: [split]
            ),
            today: day(2026, 4, 2)
        ))
        XCTAssertEqual(onePaid.available?.amount, 8_000)
        XCTAssertEqual(onePaid.feesOffLimit.amount, 100)

        let allPaid = try XCTUnwrap(limit(
            input(
                .payLater, payLater, opening: 0, started: try at(2, 1),
                movements: entries + [
                    payment(1_050, at: try at(4, 1)), payment(1_050, at: try at(5, 1)), payment(1_050, at: try at(6, 1)),
                ],
                plans: [split]
            ),
            today: day(2026, 6, 2)
        ))
        XCTAssertEqual(allPaid.available?.amount, 10_000)
        XCTAssertEqual(allPaid.feesOffLimit.amount, 0)
    }

    func testPartPaymentKeepsFeesOffUntilTheDueIsPaid() throws {
        let split = plan(monthly: 1_050, months: 3, firstDue: day(2026, 4, 5))
        let status = try XCTUnwrap(limit(
            input(
                .payLater, payLater, opening: 0, started: try at(2, 1),
                movements: try splitEntries(split) + [payment(500, at: try at(4, 1))], plans: [split]
            ),
            today: day(2026, 4, 2)
        ))
        XCTAssertEqual(status.available?.amount, 7_500)
        XCTAssertEqual(status.feesOffLimit.amount, 150)
    }

    func testFeesUseTheLimitKeepsLimitLessOwed() throws {
        let split = plan(monthly: 1_050, months: 3, firstDue: day(2026, 4, 5))
        let status = try XCTUnwrap(limit(
            input(.payLater, payLater, opening: 0, started: try at(2, 1), movements: try splitEntries(split), plans: [split]),
            feesUseLimit: true,
            today: day(2026, 3, 20)
        ))
        XCTAssertEqual(status.available?.amount, 6_850)
        XCTAssertEqual(status.feesOffLimit.amount, 0)
    }

    func testTwoSplitsAddTheirUnpaidFees() throws {
        let first = plan(monthly: 1_050, months: 3, firstDue: day(2026, 4, 5))
        let second = plan(monthly: 530, months: 2, firstDue: day(2026, 4, 5))
        let entries = try splitEntries(first) + [
            expense(1_000, at: try at(3, 12), planID: second.id),
            expense(60, at: try at(3, 12), planID: second.id, origin: .planFees),
        ]
        let status = try XCTUnwrap(limit(
            input(.payLater, payLater, opening: 0, started: try at(2, 1), movements: entries, plans: [first, second]),
            today: day(2026, 3, 20)
        ))
        XCTAssertEqual(status.feesOffLimit.amount, 210)
        XCTAssertEqual(status.available?.amount, 6_000)
    }

    func testStoredFeesOfAPlanUnderWay() throws {
        let underWay = plan(monthly: 500, months: 6, paidAtStart: 3, firstDue: day(2026, 4, 5), feesMinor: 300)
        let status = try XCTUnwrap(limit(
            input(.payLater, payLater, opening: -1_500, started: try at(2, 1), plans: [underWay]),
            today: day(2026, 3, 20)
        ))
        XCTAssertEqual(status.feesOffLimit.amount, 150)
        XCTAssertEqual(status.available?.amount, 8_650)
    }

    func testFeesTakenOffNeverExceedWhatsOwed() throws {
        let underWay = plan(monthly: 500, months: 3, firstDue: day(2026, 4, 5), feesMinor: 300)
        let lowered = try XCTUnwrap(limit(
            input(.payLater, payLater, opening: -100, started: try at(2, 1), plans: [underWay]),
            today: day(2026, 3, 20)
        ))
        XCTAssertEqual(lowered.available?.amount, 10_000)
        XCTAssertEqual(lowered.feesOffLimit.amount, 100)

        let credit = try XCTUnwrap(limit(
            input(.payLater, payLater, opening: 50, started: try at(2, 1), plans: [underWay]),
            today: day(2026, 3, 20)
        ))
        XCTAssertEqual(credit.available?.amount, 10_050)
        XCTAssertEqual(credit.feesOffLimit.amount, 0)
    }

    func testCardLimitStatusIsLimitLessOwed() throws {
        let fees = plan(monthly: 500, months: 3, firstDue: day(2026, 4, 25), feesMinor: 300)
        let owing = input(.creditCard, card, opening: -2_500, started: try at(2, 1), plans: [fees])
        let status = try XCTUnwrap(limit(owing, today: day(2026, 3, 20)))
        XCTAssertEqual(status.available?.amount, 7_500)
        XCTAssertEqual(status.feesOffLimit.amount, 0)
        XCTAssertNil(DueCalculator.limitStatus(
            limitMinor: nil, balance: owing.balance, input: owing, feesUseLimit: false, today: day(2026, 3, 20), calendar: calendar
        ))

        let unknown = try XCTUnwrap(limit(input(.creditCard, card, opening: nil, started: try at(2, 1)), today: day(2026, 3, 20)))
        XCTAssertEqual(unknown.limit.amount, 10_000)
        XCTAssertNil(unknown.available)
        XCTAssertEqual(unknown.feesOffLimit.amount, 0)
    }
}
