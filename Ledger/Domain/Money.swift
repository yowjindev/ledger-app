import Foundation

/// An ISO 4217 currency code and the number of digits its minor unit uses.
struct CurrencyCode: RawRepresentable, Hashable, Codable, Sendable, CustomStringConvertible {
    let rawValue: String

    init(rawValue: String) {
        self.rawValue = rawValue.uppercased()
    }

    /// Philippine peso. Minor unit: centavo (two digits).
    static let php = CurrencyCode(rawValue: "PHP")

    /// Number of fractional digits in the currency's minor unit.
    var minorUnitDigits: Int {
        switch rawValue {
        case "BIF", "CLP", "DJF", "GNF", "ISK", "JPY", "KMF", "KRW", "PYG", "RWF", "UGX", "VND", "VUV", "XAF", "XOF", "XPF":
            0
        case "BHD", "IQD", "JOD", "KWD", "LYD", "OMR", "TND":
            3
        default:
            2
        }
    }

    /// `10^minorUnitDigits`, the number of minor units in one major unit.
    var minorUnitScale: Decimal {
        Decimal(sign: .plus, exponent: minorUnitDigits, significand: 1)
    }

    /// Converts an amount to exact integer minor units.
    ///
    /// Returns `nil` when the amount has more fractional digits than the currency allows
    /// or does not fit in a 64-bit integer. Never rounds.
    func exactMinorUnits(for amount: Decimal) -> Int64? {
        guard !amount.isNaN, amount.hasAtMostFractionDigits(minorUnitDigits) else { return nil }
        var scaled = amount * minorUnitScale
        var whole = Decimal()
        NSDecimalRound(&whole, &scaled, 0, .plain)
        return Int64(whole.description)
    }

    var description: String { rawValue }
}

/// A monetary amount in a specific currency.
///
/// Arithmetic uses `Decimal`, never binary floating point. Persistence stores exact
/// integer minor units (`minorUnits`), so no precision is lost between saves.
struct Money: Hashable, Sendable {
    let amount: Decimal
    let currency: CurrencyCode

    init(_ amount: Decimal, currency: CurrencyCode = .php) {
        self.amount = amount
        self.currency = currency
    }

    init(minorUnits: Int64, currency: CurrencyCode = .php) {
        self.init(Decimal(minorUnits) / currency.minorUnitScale, currency: currency)
    }

    static func zero(_ currency: CurrencyCode = .php) -> Money {
        Money(.zero, currency: currency)
    }

    /// The amount as exact integer minor units, or `nil` if it cannot be represented exactly.
    var minorUnits: Int64? { currency.exactMinorUnits(for: amount) }

    var isZero: Bool { amount.isZero }
    var isPositive: Bool { amount > .zero }
    var isNegative: Bool { amount < .zero }
    var magnitude: Money { Money(amount.magnitude, currency: currency) }

    static func + (lhs: Money, rhs: Money) -> Money {
        precondition(lhs.currency == rhs.currency, "Cannot combine amounts in different currencies")
        return Money(lhs.amount + rhs.amount, currency: lhs.currency)
    }

    static func - (lhs: Money, rhs: Money) -> Money {
        precondition(lhs.currency == rhs.currency, "Cannot combine amounts in different currencies")
        return Money(lhs.amount - rhs.amount, currency: lhs.currency)
    }

    static prefix func - (value: Money) -> Money {
        Money(-value.amount, currency: value.currency)
    }
}

extension Decimal {
    /// Whether the value has no more than `digits` fractional digits.
    func hasAtMostFractionDigits(_ digits: Int) -> Bool {
        var value = self
        var rounded = Decimal()
        NSDecimalRound(&rounded, &value, digits, .plain)
        return rounded == self
    }

    var isWholeNumber: Bool { hasAtMostFractionDigits(0) }
}

/// Amount rules shared by every entry point: the app UI and App Intents.
enum AmountRules {
    /// Largest magnitude accepted for a transaction amount or an opening balance (999,999,999,999.99).
    static let maximum = Decimal(sign: .plus, exponent: -2, significand: 99_999_999_999_999)

    /// Validates a transaction amount and returns it as exact minor units.
    /// Transaction amounts are always positive; the transaction kind sets the direction.
    static func transactionMinorUnits(_ amount: Decimal, currency: CurrencyCode) throws -> Int64 {
        guard !amount.isNaN, amount > .zero else { throw LedgerError.amountNotPositive }
        guard amount <= maximum else { throw LedgerError.amountTooLarge }
        guard let minorUnits = currency.exactMinorUnits(for: amount) else { throw LedgerError.amountTooPrecise }
        return minorUnits
    }

    /// Validates an opening balance, which may be zero but not negative.
    static func openingBalanceMinorUnits(_ amount: Decimal, currency: CurrencyCode) throws -> Int64 {
        guard !amount.isNaN, amount >= .zero else { throw LedgerError.openingBalanceNegative }
        guard amount <= maximum else { throw LedgerError.amountTooLarge }
        guard let minorUnits = currency.exactMinorUnits(for: amount) else { throw LedgerError.amountTooPrecise }
        return minorUnits
    }
}
