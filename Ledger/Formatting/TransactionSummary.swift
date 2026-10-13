import Foundation

/// Display-ready description of a transaction, shared by the app and App Intents.
struct TransactionSummary: Identifiable, Hashable, Sendable {
    static let unknownAccount = "Unknown account"

    let id: UUID
    /// `nil` for records whose kind this app version doesn't know.
    let kind: TransactionKind?
    let amount: Money
    /// Category or income source name; "Transfer" for transfers.
    let title: String
    let symbolName: String
    /// "GCash" for expenses and income; "PNB → GCash" for transfers.
    let accountLine: String
    let occurredAt: Date
    let note: String?

    @MainActor
    init(_ transaction: LedgerTransaction) {
        id = transaction.id
        kind = transaction.kind
        amount = transaction.amount
        occurredAt = transaction.occurredAt
        note = transaction.note
        let sourceName = transaction.account?.name ?? Self.unknownAccount
        switch transaction.kind {
        case .transfer:
            title = TransactionKind.transfer.title
            symbolName = TransactionKind.transfer.systemImage
            accountLine = "\(sourceName) → \(transaction.destinationAccount?.name ?? Self.unknownAccount)"
        case .expense, .income:
            let categoryKind = transaction.category?.kind ?? (transaction.kind == .income ? .income : .expense)
            title = transaction.category?.name ?? "Uncategorized"
            symbolName = transaction.category?.symbolName ?? categoryKind.defaultSymbolName
            accountLine = sourceName
        case nil:
            title = "Unsupported entry"
            symbolName = "questionmark.circle"
            accountLine = sourceName
        }
    }

    /// "₱250.00 · Food · GCash", or "₱500.00 · PNB → GCash" for transfers. Always shows centavos.
    func confirmationLine(formatter: MoneyFormatter) -> String {
        let amountText = formatter.string(amount, alwaysShowCentavos: true)
        if kind == .transfer {
            return "\(amountText) · \(accountLine)"
        }
        return "\(amountText) · \(title) · \(accountLine)"
    }

    /// "-₱250.00" for expenses, "+₱250.00" for income, "₱500.00" for transfers, so the
    /// direction is readable without relying on color.
    func signedAmountText(formatter: MoneyFormatter) -> String {
        switch kind {
        case .expense: formatter.string(-amount, sign: .always)
        case .income: formatter.string(amount, sign: .always)
        case .transfer, nil: formatter.string(amount)
        }
    }

    /// Spoken description, for example "Expense, ₱250.00, Food, GCash, October 12, 2026 at 9:41 AM".
    func accessibilityLabel(formatter: MoneyFormatter) -> String {
        let amountText = formatter.string(amount, alwaysShowCentavos: true)
        let date = occurredAt.formatted(date: .long, time: .shortened)
        switch kind {
        case .transfer:
            return "Transfer, \(amountText), \(accountLine.replacingOccurrences(of: " → ", with: " to ")), \(date)"
        case .expense, .income:
            return "\(kind?.title ?? ""), \(amountText), \(title), \(accountLine), \(date)"
        case nil:
            return "\(title), \(amountText), \(date)"
        }
    }
}
