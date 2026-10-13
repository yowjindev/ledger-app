import Foundation
import XCTest
@testable import Ledger

final class MoneyAndFormattingTests: XCTestCase {
    private let usEnglish = Locale(identifier: "en_US")
    private let german = Locale(identifier: "de_DE")

    /// Foundation may use no-break spaces in formatted output; compare with plain spaces.
    private func plain(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{00A0}", with: " ").replacingOccurrences(of: "\u{202F}", with: " ")
    }

    func testMinorUnitConversionIsExact() {
        XCTAssertEqual(CurrencyCode.php.exactMinorUnits(for: dec("250.75")), 25_075)
        XCTAssertEqual(CurrencyCode.php.exactMinorUnits(for: dec("0.1")), 10)
        XCTAssertEqual(CurrencyCode.php.exactMinorUnits(for: dec("0.01")), 1)
        XCTAssertEqual(CurrencyCode.php.exactMinorUnits(for: dec("-42.50")), -4_250)
        XCTAssertEqual(CurrencyCode.php.exactMinorUnits(for: AmountRules.maximum), 99_999_999_999_999)
        XCTAssertNil(CurrencyCode.php.exactMinorUnits(for: dec("10.555")), "Never rounds")
        XCTAssertNil(CurrencyCode.php.exactMinorUnits(for: .nan))
        XCTAssertEqual(CurrencyCode(rawValue: "jpy").exactMinorUnits(for: 500), 500)
        XCTAssertNil(CurrencyCode(rawValue: "JPY").exactMinorUnits(for: dec("1.5")))
    }

    func testMoneyRoundTripsThroughMinorUnits() {
        for minor: Int64 in [0, 1, 99, 25_000, 1_234_567_89, 99_999_999_999_999] {
            let money = Money(minorUnits: minor)
            XCTAssertEqual(money.minorUnits, minor)
        }
        XCTAssertEqual(Money(minorUnits: 1_999).amount, dec("19.99"))
        XCTAssertEqual((Money(dec("0.10")) + Money(dec("0.20"))).amount, dec("0.30"))
        XCTAssertEqual((-Money(5)).amount, -5)
    }

    func testAmountRules() {
        XCTAssertEqual(try AmountRules.transactionMinorUnits(dec("0.01"), currency: .php), 1)
        XCTAssertThrowsError(try AmountRules.transactionMinorUnits(0, currency: .php))
        XCTAssertThrowsError(try AmountRules.transactionMinorUnits(.nan, currency: .php))
        XCTAssertEqual(try AmountRules.openingBalanceMinorUnits(0, currency: .php), 0)
        XCTAssertThrowsError(try AmountRules.openingBalanceMinorUnits(dec("-0.01"), currency: .php))
    }

    func testAmountParser() {
        XCTAssertEqual(AmountParser.parse("250", locale: usEnglish), 250)
        XCTAssertEqual(AmountParser.parse("1,234.50", locale: usEnglish), dec("1234.5"))
        XCTAssertEqual(AmountParser.parse(" ₱ 99.99 ", locale: usEnglish), dec("99.99"))
        XCTAssertEqual(AmountParser.parse("PHP 12", locale: usEnglish), 12)
        XCTAssertEqual(AmountParser.parse("1.234,50", locale: german), dec("1234.5"))
        XCTAssertEqual(AmountParser.parse("0.", locale: usEnglish), 0)
        for invalid in ["", ".", "-5", "1e5", "12.3.4", "abc", "١٢"] {
            XCTAssertNil(AmountParser.parse(invalid, locale: usEnglish), "\(invalid) should not parse")
        }
    }

    func testAmountSanitizer() {
        XCTAssertEqual(AmountParser.sanitize("12.345", locale: usEnglish), "12.34")
        XCTAssertEqual(AmountParser.sanitize("007", locale: usEnglish), "7")
        XCTAssertEqual(AmountParser.sanitize(".", locale: usEnglish), "0.")
        XCTAssertEqual(AmountParser.sanitize("1,234", locale: usEnglish), "1234")
        XCTAssertEqual(AmountParser.sanitize("12a3.4.5", locale: usEnglish), "123.45")
        XCTAssertEqual(AmountParser.sanitize("12,5", locale: german), "12,5")
        XCTAssertEqual(AmountParser.sanitize("1234567890123", locale: usEnglish), "123456789012")
        XCTAssertEqual(AmountParser.editableText(for: dec("1234.5"), locale: usEnglish), "1234.5")
        XCTAssertEqual(AmountParser.editableText(for: 250, locale: usEnglish), "250")
    }

    func testMoneyFormatterHonorsPreferences() {
        let always = MoneyFormatter(preferences: DisplayPreferences(symbolStyle: .symbol, centavos: .always), locale: usEnglish)
        XCTAssertEqual(plain(always.string(Money(250))), "₱250.00")
        XCTAssertEqual(plain(always.string(Money(dec("1234567.89")))), "₱1,234,567.89")
        XCTAssertEqual(plain(always.string(Money(250), sign: .always)), "+₱250.00")
        XCTAssertEqual(plain(always.string(Money(-250), sign: .always)), "-₱250.00")
        XCTAssertEqual(plain(always.string(Money(-250), sign: .never)), "₱250.00")
        XCTAssertEqual(plain(always.string(.zero(), sign: .always)), "₱0.00")

        let whenNeeded = MoneyFormatter(preferences: DisplayPreferences(symbolStyle: .symbol, centavos: .whenNeeded), locale: usEnglish)
        XCTAssertEqual(plain(whenNeeded.string(Money(4_230))), "₱4,230")
        XCTAssertEqual(plain(whenNeeded.string(Money(dec("250.5")))), "₱250.50", "Never shows one decimal or rounds")
        XCTAssertEqual(plain(whenNeeded.string(Money(4_230), alwaysShowCentavos: true)), "₱4,230.00")

        let code = MoneyFormatter(preferences: DisplayPreferences(symbolStyle: .code, centavos: .always), locale: usEnglish)
        XCTAssertEqual(plain(code.string(Money(250))), "PHP 250.00")
        XCTAssertEqual(code.currencyLabel(for: .php), "PHP")
        XCTAssertEqual(always.currencyLabel(for: .php), "₱")
    }

    @MainActor
    func testTransactionSummaryLines() throws {
        let h = try LedgerHarness()
        let gcash = try h.account("GCash", opening: 2_000, kind: .eWallet)
        let pnb = try h.account("PNB", opening: 10_000)
        let food = try h.expenseCategory("Food")
        let salary = try h.incomeSource("Salary")
        let formatter = MoneyFormatter(preferences: DisplayPreferences(symbolStyle: .symbol, centavos: .whenNeeded), locale: usEnglish)

        let expense = TransactionSummary(try h.ledger.recordExpense(amount: 250, accountID: gcash.id, categoryID: food.id))
        XCTAssertEqual(plain(expense.confirmationLine(formatter: formatter)), "₱250.00 · Food · GCash")
        XCTAssertEqual(plain(expense.signedAmountText(formatter: formatter)), "-₱250")

        let income = TransactionSummary(try h.ledger.recordIncome(amount: dec("100.5"), accountID: pnb.id, sourceID: salary.id))
        XCTAssertEqual(plain(income.signedAmountText(formatter: formatter)), "+₱100.50")

        let transfer = TransactionSummary(try h.ledger.recordTransfer(amount: 500, fromAccountID: pnb.id, toAccountID: gcash.id))
        XCTAssertEqual(transfer.title, "Transfer")
        XCTAssertEqual(transfer.accountLine, "PNB → GCash")
        XCTAssertEqual(plain(transfer.confirmationLine(formatter: formatter)), "₱500.00 · PNB → GCash")
    }
}
