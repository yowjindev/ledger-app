import Foundation

/// Wording shared by the Bills tab and the screens for money owed.
enum BillsCopy {
    /// A day of the month as offered in day pickers: "Day 5", or "Last day of the month" for 31.
    static func dayTitle(_ day: Int) -> String {
        day == 31 ? "Last day of the month" : "Day \(day)"
    }

    /// A day of the month inside a sentence: "day 19", or "the last day of the month" for 31.
    static func dayPhrase(_ day: Int) -> String {
        day == 31 ? "the last day of the month" : "day \(day)"
    }

    /// An owed kind as used in titles and buttons: "Credit Card", "Pay Later", "Loan".
    static func kindTitle(_ kind: AccountKind) -> String {
        switch kind {
        case .creditCard: "Credit Card"
        case .payLater: "Pay Later"
        default: kind.title
        }
    }

    static func limitTitle(for kind: AccountKind) -> String {
        kind == .payLater ? "Spending Limit" : "Credit Limit"
    }

    /// What an owed account owes, or the credit it holds, for a row or header.
    static func owedCaption(_ owed: Money) -> String {
        owed.isNegative ? "Credit" : "You Owe"
    }

    static let totalOwedFooter = "What your credit cards, pay later accounts, and loans owe now. Regular bills aren't included until you pay them."

    static let stillDueFooter = "Still due is the part of your last statement you haven't paid yet. Enter 0 if it's paid."

    static let owedFooter = "What the app or statement shows as your total balance, including purchases not billed yet."

    static let paymentFooter = "A payment is a transfer from one of your accounts, so it isn't counted as spending."

    /// What Update What You Owe will record.
    static func owedCorrectionPreview(_ correction: BalanceCorrection, accountName: String, formatter: MoneyFormatter) -> String {
        switch correction {
        case .alreadyMatches:
            return "This matches what Ledger has. Nothing will change."
        case .setOpeningBalance(let opening):
            return "Ledger will start \(accountName) owing \(formatter.string(-opening, alwaysShowCentavos: true))."
        case .adjustment(let difference):
            let amount = formatter.string(difference.magnitude, alwaysShowCentavos: true)
            return difference.isNegative
                ? "Ledger will add a balance adjustment: you'll owe \(amount) more."
                : "Ledger will add a balance adjustment: you'll owe \(amount) less."
        }
    }
}
