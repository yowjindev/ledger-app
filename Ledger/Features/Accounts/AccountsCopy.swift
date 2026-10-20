import Foundation

/// Copy shared by the account screens.
enum AccountsCopy {
    /// How a current balance is derived.
    static let balanceFormula = "Current balance = opening balance + income + transfers in − expenses − transfers out ± adjustments."

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
