import AppIntents
import Foundation
import XCTest
@testable import Ledger

private struct UnexpectedPrompt: Error {}
private struct Declined: Error {}

/// Reading payment notifications, and logging from them through the App Intent flow.
@MainActor
final class PaymentMessageTests: XCTestCase {
    // MARK: Parser

    func testReadsAnEWalletTextMessage() {
        let parsed = PaymentMessageParser.parse("You have sent PHP 250.00 to JUAN D. on 10-12-2026 09:41 AM. Ref. No. 1234 567 890123. Your new balance is PHP 3,980.00.")
        XCTAssertEqual(parsed.amount, dec("250.00"))
        XCTAssertEqual(parsed.direction, .moneyOut)
        XCTAssertEqual(parsed.reference, "1234567890123")
    }

    func testReadsAnHTMLBankEmailAndSkipsTheBalance() {
        let email = """
        <html><head><style>p { color: #333; } /* PHP 99.00 */</style></head><body>
        <p>Dear Customer,</p>
        <p>You have successfully transferred <b>&#8369;1,500.00</b> to SAVINGS ****1234.</p>
        <p>Reference Number: MB20261012ABC</p>
        <p>Available balance: PHP 12,345.67</p>
        </body></html>
        """
        let parsed = PaymentMessageParser.parse(email)
        XCTAssertEqual(parsed.amount, dec("1500.00"), "Styles and the balance are ignored")
        XCTAssertEqual(parsed.direction, .moneyOut)
        XCTAssertEqual(parsed.reference, "MB20261012ABC")
    }

    func testReadsAnIncomingCredit() {
        let parsed = PaymentMessageParser.parse("Your account has been credited with PHP 25,000.00. Ref: 778899")
        XCTAssertEqual(parsed.amount, dec("25000.00"))
        XCTAssertEqual(parsed.direction, .moneyIn)
        XCTAssertEqual(parsed.reference, "778899")
    }

    func testReadsACardPurchaseAndSkipsTheLimit() {
        let parsed = PaymentMessageParser.parse("Available limit: P50,000.00. Purchase of P1,234.50 at JOLLIBEE using card ending 1234.")
        XCTAssertEqual(parsed.amount, dec("1234.50"))
        XCTAssertEqual(parsed.direction, .moneyOut)
    }

    func testReadsAnUnmarkedAmountLabelledAsTheAmount() {
        XCTAssertEqual(PaymentMessageParser.parse("Payment confirmation. Amount: 899.00. Thank you!").amount, dec("899.00"))
    }

    func testFindsNothingWhereThereIsNothing() {
        let otp = PaymentMessageParser.parse("Your one-time PIN is 123456. Do not share it with anyone.")
        XCTAssertNil(otp.amount)
        XCTAssertNil(otp.direction)
        XCTAssertNil(otp.reference)

        let balanceOnly = PaymentMessageParser.parse("Your balance is PHP 5,000.00 as of today.")
        XCTAssertNil(balanceOnly.amount, "A balance is never taken as the transaction amount")

        XCTAssertNil(PaymentMessageParser.parse("Reference: required for all transfers").reference, "A reference needs a digit")
    }

    func testMixedDirectionsAreLeftForThePersonToChoose() {
        let parsed = PaymentMessageParser.parse("You received PHP 100.00 from ANA and you sent PHP 50.00 to BEN.")
        XCTAssertNil(parsed.direction)
    }

    func testDecodesEscapedEntitiesOnce() {
        XCTAssertEqual(PaymentMessageParser.plainText("A&amp;nbsp;B &amp; C"), "A&nbsp;B & C")
        XCTAssertEqual(PaymentMessageParser.plainText("Paid&nbsp;&#8369;20"), "Paid ₱20")
    }

    // MARK: Logging from a message

    func testLogsAnExpenseFromAMessageAfterConfirmation() async throws {
        let h = try LedgerHarness()
        let maribank = try h.account("MariBank", opening: 5_000, kind: .bank)
        let food = try h.expenseCategory("Food")
        var prompts: [String] = []
        var confirmations: [String] = []

        let outcome = try await IntentFlows.logFromMessage(
            in: h.ledger,
            message: "You have successfully transferred &#8369;1,500.00 to SAVINGS. Reference Number: MB20261012ABC",
            amount: nil,
            account: AccountEntity(maribank),
            expenseCategory: nil,
            incomeSource: nil,
            askAmount: { _ in throw UnexpectedPrompt() },
            chooseDirection: { _ in throw UnexpectedPrompt() },
            askCategory: { prompts.append($0); return ExpenseCategoryEntity(food) },
            askSource: { _ in throw UnexpectedPrompt() },
            askAccount: { _ in throw UnexpectedPrompt() },
            confirm: { message, _ in confirmations.append(message) }
        )

        XCTAssertEqual(prompts, ["What was it for?"])
        XCTAssertEqual(confirmations.count, 1, "Entries read from a message are always confirmed")
        XCTAssertTrue(confirmations[0].hasPrefix("Log"), confirmations[0])
        XCTAssertTrue(confirmations[0].hasSuffix("Food expense from MariBank?"), confirmations[0])
        XCTAssertEqual(try h.balance(maribank), 3_500)
        let saved = try XCTUnwrap(try h.ledger.transactions().first)
        XCTAssertEqual(saved.reference, "MB20261012ABC")
        XCTAssertEqual(saved.origin, .appIntent)
        XCTAssertEqual(outcome.headline, "Expense saved")
    }

    func testAsksForWhatTheMessageDoesntSay() async throws {
        let h = try LedgerHarness()
        let maribank = try h.account("MariBank", opening: 1_000, kind: .bank)
        let refund = try h.incomeSource("Refund")
        var prompts: [String] = []

        _ = try await IntentFlows.logFromMessage(
            in: h.ledger,
            message: "Hello! Here is an update on your account activity.",
            amount: nil,
            account: AccountEntity(maribank),
            expenseCategory: nil,
            incomeSource: nil,
            askAmount: { prompts.append($0); return 120 },
            chooseDirection: { prompts.append($0); return .moneyIn },
            askCategory: { _ in throw UnexpectedPrompt() },
            askSource: { prompts.append($0); return IncomeSourceEntity(refund) },
            askAccount: { _ in throw UnexpectedPrompt() },
            confirm: { _, _ in }
        )

        XCTAssertEqual(prompts, [
            "Ledger couldn't find the amount. How much was it?",
            "Was this money going out or coming in?",
            "Where is it from?",
        ])
        XCTAssertEqual(try h.balance(maribank), 1_120)
    }

    func testWarnsWhenTheSameReferenceWasAlreadyLogged() async throws {
        let h = try LedgerHarness()
        let maribank = try h.account("MariBank", opening: 5_000, kind: .bank)
        let food = try h.expenseCategory("Food")
        let message = "Purchase of PHP 300.00 at GROCER. Ref No. 55512345"
        func log(confirm: IntentFlows.Confirm) async throws {
            _ = try await IntentFlows.logFromMessage(
                in: h.ledger,
                message: message,
                amount: nil,
                account: AccountEntity(maribank),
                expenseCategory: ExpenseCategoryEntity(food),
                incomeSource: nil,
                askAmount: { _ in throw UnexpectedPrompt() },
                chooseDirection: { _ in throw UnexpectedPrompt() },
                askCategory: { _ in throw UnexpectedPrompt() },
                askSource: { _ in throw UnexpectedPrompt() },
                askAccount: { _ in throw UnexpectedPrompt() },
                confirm: confirm
            )
        }

        try await log { _, _ in }
        h.clock.advance(by: 3_600)

        var messages: [String] = []
        do {
            try await log { message, _ in
                messages.append(message)
                throw Declined()
            }
            XCTFail("Declining must stop the flow")
        } catch is Declined {
            // Expected.
        }
        XCTAssertTrue(messages.first?.hasPrefix("You already logged a transaction with reference 55512345.") ?? false, messages.first ?? "")
        XCTAssertEqual(try h.transactionCount(), 1, "The repeated email isn't logged again")
        XCTAssertEqual(try h.balance(maribank), 4_700)
    }
}
