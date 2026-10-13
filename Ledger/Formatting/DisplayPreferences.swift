import Foundation

/// How the currency is labelled in amounts.
enum CurrencySymbolStyle: String, CaseIterable, Identifiable, Sendable {
    /// ₱1,234.50
    case symbol
    /// PHP 1,234.50
    case code

    var id: String { rawValue }

    var title: String {
        switch self {
        case .symbol: "Symbol (₱)"
        case .code: "Code (PHP)"
        }
    }
}

/// When centavos are shown.
enum CentavoDisplay: String, CaseIterable, Identifiable, Sendable {
    /// ₱250.00
    case always
    /// ₱250 for whole amounts, ₱250.50 otherwise.
    case whenNeeded

    var id: String { rawValue }

    var title: String {
        switch self {
        case .always: "Always"
        case .whenNeeded: "Only When Needed"
        }
    }
}

/// User display preferences, stored in `UserDefaults`. Display only; never affects stored values.
struct DisplayPreferences: Equatable, Sendable {
    enum Keys {
        static let symbolStyle = "display.currencySymbolStyle"
        static let centavos = "display.centavos"
    }

    var symbolStyle: CurrencySymbolStyle = .symbol
    var centavos: CentavoDisplay = .always

    static func load(from defaults: UserDefaults = .standard) -> DisplayPreferences {
        DisplayPreferences(
            symbolStyle: defaults.string(forKey: Keys.symbolStyle).flatMap(CurrencySymbolStyle.init(rawValue:)) ?? .symbol,
            centavos: defaults.string(forKey: Keys.centavos).flatMap(CentavoDisplay.init(rawValue:)) ?? .always
        )
    }
}
