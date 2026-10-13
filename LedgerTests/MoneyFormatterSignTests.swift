import Foundation
import XCTest
@testable import Ledger

/// Signs, symbol styles, and centavo display for negative, zero, and very large amounts, plus how
/// stored display preferences are read back.
final class MoneyFormatterSignTests: XCTestCase {
    private let negative = Money(dec("-1234.5"))

    func testNegativeAmountsWithEverySignStyleAndSymbolStyle() {
        let symbol = fixedFormatter(.symbol)
        XCTAssertEqual(plainSpaces(symbol.string(negative)), "-₱1,234.50")
        XCTAssertEqual(plainSpaces(symbol.string(negative, sign: .always)), "-₱1,234.50")
        XCTAssertEqual(plainSpaces(symbol.string(negative, sign: .never)), "₱1,234.50")

        let code = fixedFormatter(.code)
        XCTAssertEqual(plainSpaces(code.string(negative)), "-PHP 1,234.50")
        XCTAssertEqual(plainSpaces(code.string(negative, sign: .always)), "-PHP 1,234.50")
        XCTAssertEqual(plainSpaces(code.string(negative, sign: .never)), "PHP 1,234.50")
    }

    func testNegativeAmountsWhenCentavosShowOnlyIfNeeded() {
        let whenNeeded = fixedFormatter(.symbol, .whenNeeded)
        XCTAssertEqual(plainSpaces(whenNeeded.string(Money(-250))), "-₱250")
        XCTAssertEqual(plainSpaces(whenNeeded.string(Money(-250), sign: .never)), "₱250")
        XCTAssertEqual(plainSpaces(whenNeeded.string(Money(-250), sign: .always, alwaysShowCentavos: true)), "-₱250.00")
        XCTAssertEqual(plainSpaces(whenNeeded.string(Money(dec("-0.5")), sign: .always)), "-₱0.50")
        XCTAssertEqual(plainSpaces(whenNeeded.string(Money(dec("-0.05")), sign: .never)), "₱0.05")
    }

    func testOnlyAlwaysAddsAPlusAndZeroNeverGetsASign() {
        let formatters = [fixedFormatter(.symbol), fixedFormatter(.code), fixedFormatter(.symbol, .whenNeeded)]
        let signs: [MoneyFormatter.SignStyle] = [.automatic, .always, .never]
        for formatter in formatters {
            XCTAssertFalse(formatter.string(Money(250)).contains("+"))
            XCTAssertFalse(formatter.string(Money(250), sign: .never).contains("+"))
            XCTAssertTrue(formatter.string(Money(250), sign: .always).hasPrefix("+"))
            for sign in signs {
                for zero in [Money.zero(), -Money.zero()] {
                    let text = formatter.string(zero, sign: sign)
                    XCTAssertFalse(text.contains { "+-\u{2212}".contains($0) }, "\(text) with \(sign)")
                }
            }
        }
    }

    func testLargestAmountsKeepEveryDigit() {
        let always = fixedFormatter()
        XCTAssertEqual(plainSpaces(always.string(Money(AmountRules.maximum))), "₱999,999,999,999.99")
        XCTAssertEqual(
            plainSpaces(always.string(-Money(AmountRules.maximum + AmountRules.maximum), sign: .always)),
            "-₱1,999,999,999,999.98"
        )
        let whenNeeded = fixedFormatter(.symbol, .whenNeeded)
        XCTAssertEqual(plainSpaces(whenNeeded.string(Money(dec("1999999999999.01")))), "₱1,999,999,999,999.01")
        XCTAssertEqual(plainSpaces(whenNeeded.string(Money(dec("1999999999999")))), "₱1,999,999,999,999")
    }

    func testFrenchNegativeUsesFrenchSeparatorsAndASingleSign() {
        let french = fixedFormatter(locale: "fr_FR")
        let text = plainSpaces(french.string(negative, sign: .always))

        XCTAssertTrue(text.contains("1 234,50"), text)
        XCTAssertTrue(text.contains("₱"), text)
        XCTAssertEqual(text.filter { "+-\u{2212}".contains($0) }.count, 1, text)
        XCTAssertEqual(plainSpaces(french.string(negative, sign: .never)).filter { "+-\u{2212}".contains($0) }.count, 0)
    }

    func testIndianEnglishGroupsLakhsAndCrores() {
        XCTAssertEqual(plainSpaces(fixedFormatter(locale: "en_IN").string(Money(dec("-12345678.9")))), "-₱1,23,45,678.90")
    }

    func testStoredPreferencesFallBackToDefaultsWhenMissingOrUnknown() throws {
        try withScratchDefaults { defaults in
            XCTAssertEqual(DisplayPreferences.load(from: defaults), DisplayPreferences(symbolStyle: .symbol, centavos: .always))
            XCTAssertTrue(AppPreferences.warnsAboutDuplicates(in: defaults))

            defaults.set("emoji", forKey: DisplayPreferences.Keys.symbolStyle)
            defaults.set(42, forKey: DisplayPreferences.Keys.centavos)
            defaults.set("sometimes", forKey: AppPreferences.Keys.warnsAboutDuplicates)
            XCTAssertEqual(DisplayPreferences.load(from: defaults), DisplayPreferences())
            XCTAssertTrue(AppPreferences.warnsAboutDuplicates(in: defaults))

            defaults.set(CurrencySymbolStyle.code.rawValue, forKey: DisplayPreferences.Keys.symbolStyle)
            defaults.set(CentavoDisplay.whenNeeded.rawValue, forKey: DisplayPreferences.Keys.centavos)
            defaults.set(false, forKey: AppPreferences.Keys.warnsAboutDuplicates)
            XCTAssertEqual(DisplayPreferences.load(from: defaults), DisplayPreferences(symbolStyle: .code, centavos: .whenNeeded))
            XCTAssertFalse(AppPreferences.warnsAboutDuplicates(in: defaults))
        }
    }
}
