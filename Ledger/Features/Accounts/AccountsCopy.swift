import Foundation

/// Copy shared by the account screens.
enum AccountsCopy {
    /// How a current balance is derived.
    static let balanceFormula = "Current balance = opening balance + income + transfers in − expenses − transfers out ± adjustments."

    /// How daily interest is calculated and when it's added.
    static let interestFooter = "Ledger adds each day's interest at 1:00 AM the next day: the day's ending balance × rate ÷ 360, rounded up, minus withholding tax."

    /// "3.25% a year, 20% tax", "3.25% a year, no tax", or "Off".
    static func interestSummary(_ terms: InterestTerms?, locale: Locale = .autoupdatingCurrent) -> String {
        guard let terms else { return "Off" }
        let rate = "\(percentText(terms.annualRate, locale: locale)) a year"
        guard terms.taxRate.partsPerMillion > 0 else { return "\(rate), no tax" }
        return "\(rate), \(percentText(terms.taxRate, locale: locale)) tax"
    }

    /// "3.25%" or "4%": only the decimal places the rate needs.
    static func percentText(_ rate: Rate, locale: Locale = .autoupdatingCurrent) -> String {
        let number = rate.percent.formatted(
            .number
                .locale(locale)
                .grouping(.never)
                .precision(.fractionLength(0...RateRules.maximumFractionDigits))
        )
        return "\(number)%"
    }

    /// What Update Balance will record for the real balance typed so far.
    static func correctionPreview(_ correction: BalanceCorrection, accountName: String, formatter: MoneyFormatter) -> String {
        switch correction {
        case .alreadyMatches:
            "This matches Ledger's balance. Nothing will change."
        case .setOpeningBalance(let opening):
            "Ledger will set \(accountName)'s opening balance to \(formatter.string(opening, alwaysShowCentavos: true))."
        case .adjustment(let difference):
            "Ledger will add a balance adjustment of \(formatter.string(difference, sign: .always, alwaysShowCentavos: true))."
        }
    }
}
