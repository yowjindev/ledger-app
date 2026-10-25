import Foundation

/// Parses and sanitizes amounts typed by the user.
enum AmountParser {
    /// Parses a positive amount written with ASCII digits and the locale's decimal separator.
    /// Grouping separators, spaces, and a leading "₱" or "PHP" are ignored. Returns `nil` for
    /// anything else, including negative numbers, exponents, and other digit characters.
    static func parse(_ text: String, locale: Locale = .autoupdatingCurrent) -> Decimal? {
        let decimalSeparator = locale.decimalSeparator ?? "."
        let groupingSeparator = locale.groupingSeparator ?? ","

        var cleaned = text
            .replacingOccurrences(of: "₱", with: "")
            .replacingOccurrences(of: "PHP", with: "", options: .caseInsensitive)
        cleaned.removeAll { $0.isWhitespace }
        if !groupingSeparator.isEmpty, groupingSeparator != decimalSeparator {
            cleaned = cleaned.replacingOccurrences(of: groupingSeparator, with: "")
        }
        if decimalSeparator != "." {
            cleaned = cleaned.replacingOccurrences(of: decimalSeparator, with: ".")
        }

        guard
            !cleaned.isEmpty,
            cleaned != ".",
            cleaned.allSatisfy({ isASCIIDigit($0) || $0 == "." }),
            cleaned.filter({ $0 == "." }).count <= 1
        else { return nil }
        return Decimal(string: cleaned, locale: Locale(identifier: "en_US_POSIX"))
    }

    /// Restricts live input to ASCII digits and the locale's decimal separator, with at most
    /// `maximumFractionDigits` decimals and `maximumIntegerDigits` whole digits. Grouping
    /// separators and any other characters are dropped.
    static func sanitize(
        _ text: String,
        locale: Locale = .autoupdatingCurrent,
        maximumFractionDigits: Int = 2,
        maximumIntegerDigits: Int = 12
    ) -> String {
        let decimalSeparator = locale.decimalSeparator?.first ?? "."
        var integerPart = ""
        var fractionPart = ""
        var hasSeparator = false
        for character in text {
            if isASCIIDigit(character) {
                if hasSeparator {
                    if fractionPart.count < maximumFractionDigits { fractionPart.append(character) }
                } else if integerPart.count < maximumIntegerDigits {
                    integerPart.append(character)
                }
            } else if character == decimalSeparator, !hasSeparator, maximumFractionDigits > 0 {
                hasSeparator = true
            }
        }
        if integerPart.count > 1 {
            let withoutLeadingZeros = integerPart.drop { $0 == "0" }
            integerPart = withoutLeadingZeros.isEmpty ? "0" : String(withoutLeadingZeros)
        }
        guard hasSeparator else { return integerPart }
        return (integerPart.isEmpty ? "0" : integerPart) + String(decimalSeparator) + fractionPart
    }

    /// Text for editing an existing amount: ASCII digits, no grouping, the locale's decimal
    /// separator, and no trailing zeros beyond what the amount needs, so `sanitize` keeps it as is
    /// and `parse` reads it back.
    static func editableText(for amount: Decimal, locale: Locale = .autoupdatingCurrent, maximumFractionDigits: Int = 2) -> String {
        let text = amount.formatted(
            .number
                .locale(Locale(identifier: "en_US_POSIX"))
                .grouping(.never)
                .precision(.fractionLength(0...maximumFractionDigits))
        )
        let decimalSeparator = locale.decimalSeparator ?? "."
        return decimalSeparator == "." ? text : text.replacingOccurrences(of: ".", with: decimalSeparator)
    }

    /// Whether `character` is exactly one of the ASCII digits 0–9. A keycap such as "1️⃣" or a
    /// digit followed by a combining mark is a different character, although it starts with one.
    private static func isASCIIDigit(_ character: Character) -> Bool {
        character.isASCII && character.isWholeNumber
    }
}
