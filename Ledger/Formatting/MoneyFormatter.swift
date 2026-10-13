import Foundation

/// Formats money for display. Amounts are formatted only for display, never stored as strings.
struct MoneyFormatter: Sendable {
    enum SignStyle: Sendable {
        /// A minus sign for negative amounts only.
        case automatic
        /// A plus or minus sign for every non-zero amount.
        case always
        /// No sign; shows the magnitude.
        case never
    }

    var preferences: DisplayPreferences
    var locale: Locale

    init(preferences: DisplayPreferences = DisplayPreferences(), locale: Locale = .autoupdatingCurrent) {
        self.preferences = preferences
        self.locale = locale
    }

    /// A formatter using the preferences currently saved in `UserDefaults`.
    static func current(locale: Locale = .autoupdatingCurrent) -> MoneyFormatter {
        MoneyFormatter(preferences: .load(), locale: locale)
    }

    /// - Parameter alwaysShowCentavos: Shows centavos regardless of preferences, for
    ///   confirmations where the exact amount matters.
    func string(_ money: Money, sign: SignStyle = .automatic, alwaysShowCentavos: Bool = false) -> String {
        let value = sign == .never ? money.amount.magnitude : money.amount
        let showsFraction = alwaysShowCentavos || preferences.centavos == .always || !value.isWholeNumber
        var style = Decimal.FormatStyle.Currency(code: money.currency.rawValue, locale: locale)
            .presentation(preferences.symbolStyle == .symbol ? .narrow : .isoCode)
            .precision(.fractionLength(showsFraction ? money.currency.minorUnitDigits : 0))
        if sign == .always {
            style = style.sign(strategy: .always(showZero: false))
        }
        return value.formatted(style)
    }

    /// The currency's label alone, for example "₱" or "PHP".
    func currencyLabel(for currency: CurrencyCode) -> String {
        switch preferences.symbolStyle {
        case .symbol:
            currency == .php ? "₱" : currency.rawValue
        case .code:
            currency.rawValue
        }
    }
}
