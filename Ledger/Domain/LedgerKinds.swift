import Foundation

/// What a transaction does to account balances.
enum TransactionKind: String, CaseIterable, Codable, Sendable, Identifiable {
    /// Money leaving an account for a purchase or bill.
    case expense
    /// Money arriving in an account from an income source.
    case income
    /// Money moving between two of the user's accounts. Neither income nor expense.
    case transfer
    /// A correction that brings an account to its real balance. Neither income nor expense.
    case adjustment

    /// The kinds a person logs; adjustments are made through Update Balance instead.
    static let loggable: [TransactionKind] = [.expense, .income, .transfer]

    var id: String { rawValue }

    var title: String {
        switch self {
        case .expense: "Expense"
        case .income: "Income"
        case .transfer: "Transfer"
        case .adjustment: "Adjustment"
        }
    }

    var systemImage: String {
        switch self {
        case .expense: "arrow.up.right"
        case .income: "arrow.down.left"
        case .transfer: "arrow.left.arrow.right"
        case .adjustment: "plus.forwardslash.minus"
        }
    }

    /// The category kind this transaction must reference, or `nil` for transfers and adjustments.
    var requiredCategoryKind: CategoryKind? {
        switch self {
        case .expense: .expense
        case .income: .income
        case .transfer, .adjustment: nil
        }
    }
}

/// Whether a balance adjustment raised or lowered the account's balance.
enum AdjustmentDirection: String, Codable, Sendable {
    case increase
    case decrease
}

/// Which transactions a category can classify.
enum CategoryKind: String, CaseIterable, Codable, Sendable, Identifiable {
    /// Expense categories such as Food or Transport.
    case expense
    /// Income sources such as Salary or Refund.
    case income

    var id: String { rawValue }

    var title: String {
        switch self {
        case .expense: "Expense Category"
        case .income: "Income Source"
        }
    }

    var pluralTitle: String {
        switch self {
        case .expense: "Expense Categories"
        case .income: "Income Sources"
        }
    }

    /// Symbol used when the user hasn't picked one.
    var defaultSymbolName: String {
        switch self {
        case .expense: "tag.fill"
        case .income: "banknote.fill"
        }
    }
}

/// The type of place money is kept. Stored as its raw value so new kinds can be added
/// without a schema migration.
enum AccountKind: String, CaseIterable, Codable, Sendable, Identifiable {
    case cash
    case bank
    case eWallet
    case other

    /// Decodes a stored raw value, falling back to `.other` for values written by a newer version.
    init(storedValue: String) {
        self = AccountKind(rawValue: storedValue) ?? .other
    }

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cash: "Cash"
        case .bank: "Bank"
        case .eWallet: "E-wallet"
        case .other: "Other"
        }
    }

    var systemImage: String {
        switch self {
        case .cash: "banknote.fill"
        case .bank: "building.columns"
        case .eWallet: "iphone"
        case .other: "creditcard"
        }
    }

    /// Whether balances of this kind count toward the total liquid balance.
    /// Future non-liquid kinds (investments, credit cards) return `false` here.
    var countsTowardLiquidTotal: Bool {
        switch self {
        case .cash, .bank, .eWallet, .other: true
        }
    }
}

/// Settlement state of a transaction. Only posted transactions affect balances.
/// Additional states (scheduled, pending) can be introduced for recurring obligations later.
enum TransactionStatus: String, Codable, Sendable {
    case posted
}

/// Where a transaction was entered.
enum EntryOrigin: String, Codable, Sendable {
    /// Entered in the Ledger app.
    case app
    /// Entered through an App Intent: Shortcuts, Siri, Spotlight, or the Action Button.
    case appIntent
    /// Posted by Ledger: daily interest and its withholding tax.
    case interest
}
