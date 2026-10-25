import SwiftUI

/// Semantic colors. Color is never the only cue: amounts also carry a sign, and rows show the
/// transaction type.
enum LedgerTheme {
    /// Green dark enough for text on white in light mode; system green in dark mode.
    static let income = Color(.income)
    static let transfer = Color.blue

    /// Color for a transaction amount.
    static func amountColor(for kind: TransactionKind?) -> Color {
        switch kind {
        case .income: income
        case .expense: .primary
        case .transfer, .adjustment, nil: .secondary
        }
    }

    /// Tint for a transaction's symbol badge.
    static func badgeTint(for kind: TransactionKind?) -> Color {
        switch kind {
        case .income: income
        case .transfer: transfer
        case .adjustment: .secondary
        // The asset color, not `.accentColor`: snippets drawn outside the app don't inherit
        // the app's accent and would fall back to blue.
        case .expense, nil: Color(.accent)
        }
    }
}
