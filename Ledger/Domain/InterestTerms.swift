import Foundation

/// A percentage stored exactly as parts per million: 3.25% is 32_500 and 20% is 200_000.
struct Rate: Hashable, Sendable {
    let partsPerMillion: Int64

    /// The rate as a percentage, for example 3.25.
    var percent: Decimal { Decimal(partsPerMillion) / 10_000 }

    /// The rate as a fraction, for example 0.0325.
    var fraction: Decimal { Decimal(partsPerMillion) / 1_000_000 }

    /// The percentage as text for editing, with every decimal place a rate can have, so it
    /// reads back as the same rate.
    func editableText(locale: Locale = .autoupdatingCurrent) -> String {
        AmountParser.editableText(for: percent, locale: locale, maximumFractionDigits: RateRules.maximumFractionDigits)
    }

    /// Reads a typed percentage such as "3.25", "3,25" where the comma is the decimal separator,
    /// or "3.25%". Returns `nil` when the text isn't a number.
    static func parse(_ text: String, locale: Locale = .autoupdatingCurrent) -> Decimal? {
        AmountParser.parse(text.replacingOccurrences(of: "%", with: ""), locale: locale)
    }
}

/// Rate rules shared by every entry point.
enum RateRules {
    /// The most decimal places a rate may have when written as a percentage.
    static let maximumFractionDigits = 4

    /// An annual interest rate: above 0% and at most 100%.
    static func annualRate(percent: Decimal) throws -> Rate {
        guard !percent.isNaN, percent > .zero, percent <= 100 else { throw LedgerError.interestRateOutOfRange }
        return try rate(percent: percent)
    }

    /// A withholding tax rate: from 0% to 100%.
    static func taxRate(percent: Decimal) throws -> Rate {
        guard !percent.isNaN, percent >= .zero, percent <= 100 else { throw LedgerError.taxRateOutOfRange }
        return try rate(percent: percent)
    }

    /// Cashback on purchases: above 0% and at most 100%.
    static func cashbackRate(percent: Decimal) throws -> Rate {
        guard !percent.isNaN, percent > .zero, percent <= 100 else { throw LedgerError.cashbackRateOutOfRange }
        return try rate(percent: percent)
    }

    private static func rate(percent: Decimal) throws -> Rate {
        guard percent.hasAtMostFractionDigits(maximumFractionDigits) else { throw LedgerError.rateTooPrecise }
        return Rate(partsPerMillion: NSDecimalNumber(decimal: percent * 10_000).int64Value)
    }
}

/// How an account earns interest.
struct InterestTerms: Hashable, Sendable {
    let annualRate: Rate
    let taxRate: Rate

    /// The Philippine final withholding tax on peso deposit interest.
    static let defaultTaxRate = Rate(partsPerMillion: 200_000)
}
