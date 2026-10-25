import Foundation

/// Cashback on credit card purchases.
enum CashbackCalculator {
    /// Purchase × rate, rounded down to the minor unit, as banks credit it.
    static func cashbackMinor(forPurchaseMinor purchase: Int64, rate: Rate) -> Int64 {
        var exact = Decimal(purchase) * Decimal(rate.partsPerMillion) / 1_000_000
        var rounded = Decimal()
        NSDecimalRound(&rounded, &exact, 0, .down)
        return NSDecimalNumber(decimal: rounded).int64Value
    }
}
