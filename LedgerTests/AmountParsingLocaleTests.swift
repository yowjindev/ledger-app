import Foundation
import XCTest
@testable import Ledger

/// Typed-amount parsing and sanitizing across locales. Whatever text the parser accepts, and
/// whatever text the sanitizer leaves in the field, must mean exactly the amount it shows.
final class AmountParsingLocaleTests: XCTestCase {
    private let posix = Locale(identifier: "en_US_POSIX")
    private let usEnglish = Locale(identifier: "en_US")
    private let french = Locale(identifier: "fr_FR")
    private let indianEnglish = Locale(identifier: "en_IN")

    func testFrenchAmountsWithAnyKindOfSpaceForGrouping() {
        XCTAssertEqual(AmountParser.parse("1\u{202F}234,56", locale: french), dec("1234.56"), "Narrow no-break space")
        XCTAssertEqual(AmountParser.parse("1\u{00A0}234,56", locale: french), dec("1234.56"), "No-break space")
        XCTAssertEqual(AmountParser.parse("1 234,56", locale: french), dec("1234.56"))
        XCTAssertEqual(AmountParser.parse("₱\u{202F}12,5", locale: french), dec("12.5"))
        XCTAssertEqual(AmountParser.parse("12,50\u{00A0}PHP", locale: french), dec("12.5"))
        XCTAssertNil(AmountParser.parse("1.234,56", locale: french), "A period isn't French grouping, so this is ambiguous")
        XCTAssertNil(AmountParser.parse("1,2,3", locale: french))

        XCTAssertEqual(AmountParser.sanitize("1\u{202F}234,567", locale: french), "1234,56")
        XCTAssertEqual(AmountParser.sanitize(",5", locale: french), "0,5")
        XCTAssertEqual(AmountParser.sanitize("00,50", locale: french), "0,50")
    }

    func testIndianGroupingIsIgnoredWhereverItFalls() {
        XCTAssertEqual(AmountParser.parse("1,23,45,678.90", locale: indianEnglish), dec("12345678.9"))
        XCTAssertEqual(AmountParser.parse("₱99,99,999.99", locale: indianEnglish), dec("9999999.99"))
        XCTAssertEqual(AmountParser.sanitize("1,23,456.789", locale: indianEnglish), "123456.78")
    }

    func testNonASCIIDigitsAreRejectedRatherThanReinterpreted() {
        let saudiArabic = Locale(identifier: "ar_SA")
        for text in ["١٢٣", "١٢٣٫٤٥", "۱۲۳", "１２３", "12３"] {
            XCTAssertNil(AmountParser.parse(text, locale: usEnglish), text)
            XCTAssertNil(AmountParser.parse(text, locale: saudiArabic), text)
        }
        XCTAssertEqual(AmountParser.sanitize("١٢٣", locale: usEnglish), "")
        XCTAssertEqual(AmountParser.sanitize("4١2", locale: usEnglish), "42")
    }

    /// A keycap ("1️⃣") or a digit carrying a combining mark is one character that begins with an
    /// ASCII digit. Reading only that first digit would turn "1️⃣2️⃣" into 1.
    func testDigitLookalikesBuiltOnASCIIDigitsAreRejected() {
        for text in ["1\u{FE0F}\u{20E3}2\u{FE0F}\u{20E3}", "5\u{0301}0", "1\u{FE0F}\u{20E3}", "2\u{20E3}"] {
            XCTAssertNil(AmountParser.parse(text, locale: usEnglish), text.debugDescription)
        }
        XCTAssertEqual(AmountParser.sanitize("1\u{FE0F}\u{20E3}2", locale: usEnglish), "2")
        XCTAssertEqual(AmountParser.sanitize("5\u{0301}0", locale: usEnglish), "0")
        XCTAssertEqual(AmountParser.sanitize("9,5\u{0301}", locale: french), "9,")
    }

    func testSanitizedTextAlwaysParsesToTheAmountItShows() {
        let inputs = [
            "1\u{FE0F}\u{20E3}2", "5\u{0301}0.5", "１２.5", "0012.345", "..5", "1,234.5.6", "₱ 1 000", "\u{0661}9", "12.",
        ]
        for input in inputs {
            let text = AmountParser.sanitize(input, locale: usEnglish)
            XCTAssertTrue(
                text.unicodeScalars.allSatisfy { ("0"..."9").contains($0) || $0 == "." },
                "\(input.debugDescription) left \(text.debugDescription)"
            )
            XCTAssertEqual(AmountParser.parse(text, locale: usEnglish), Decimal(string: text, locale: posix), input.debugDescription)
        }
    }

    /// The editor shows an existing amount with `editableText`, then sanitizes and parses what it
    /// shows. In every locale that text must survive both steps unchanged, including locales whose
    /// own digits aren't ASCII.
    func testEditableTextSurvivesSanitizingAndParsingInEveryLocale() {
        let amounts = [dec("0.01"), dec("12.5"), dec("250"), dec("1234.56"), AmountRules.maximum]
        let locales = ["en_US", "en_PH", "fil_PH", "fr_FR", "de_DE", "de_CH", "en_IN", "ar_SA", "ar_EG", "fa_IR"]
        for identifier in locales {
            let locale = Locale(identifier: identifier)
            for amount in amounts {
                let text = AmountParser.editableText(for: amount, locale: locale)
                XCTAssertEqual(AmountParser.sanitize(text, locale: locale), text, "\(identifier) \(amount)")
                XCTAssertEqual(AmountParser.parse(text, locale: locale), amount, "\(identifier) \(amount)")
            }
        }
    }

    func testEditableTextUsesTheLocalesDecimalSeparatorWithoutGrouping() {
        XCTAssertEqual(AmountParser.editableText(for: dec("1234.5"), locale: french), "1234,5")
        XCTAssertEqual(AmountParser.editableText(for: dec("1234567.89"), locale: indianEnglish), "1234567.89")
        XCTAssertEqual(AmountParser.editableText(for: dec("12.50"), locale: usEnglish), "12.5")
        XCTAssertEqual(AmountParser.editableText(for: AmountRules.maximum, locale: Locale(identifier: "de_DE")), "999999999999,99")
    }
}
