import Foundation

/// Display-ready description of a transaction, shared by the app and App Intents.
struct TransactionSummary: Identifiable, Hashable, Sendable {
    static let unknownAccount = "Unknown account"
    static let adjustmentTitle = "Balance adjustment"
    static let interestTitle = "Interest"
    static let withholdingTaxTitle = "Withholding tax"
    static let interestSymbolName = "percent"
    static let cashbackTitle = "Cashback"
    static let cashbackSymbolName = "arrow.uturn.backward.circle"
    static let planFeesTitle = "Fees and interest"
    static let planFeesSymbolName = "receipt"

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
    /// For adjustments, whether the balance went up or down.
    let adjustmentDirection: AdjustmentDirection?

    @MainActor
    init(_ transaction: LedgerTransaction) {
        id = transaction.id
        kind = transaction.kind
        amount = transaction.amount
        occurredAt = transaction.occurredAt
        note = transaction.note
        adjustmentDirection = transaction.adjustmentDirection
        let sourceName = transaction.account?.name ?? Self.unknownAccount
        switch transaction.kind {
        case .transfer:
            title = TransactionKind.transfer.title
            symbolName = TransactionKind.transfer.systemImage
            accountLine = "\(sourceName) → \(transaction.destinationAccount?.name ?? Self.unknownAccount)"
        case .adjustment:
            title = Self.adjustmentTitle
            symbolName = TransactionKind.adjustment.systemImage
            accountLine = sourceName
        case .expense where transaction.origin == .interest, .income where transaction.origin == .interest:
            title = transaction.kind == .income ? Self.interestTitle : Self.withholdingTaxTitle
            symbolName = Self.interestSymbolName
            accountLine = sourceName
        case .income where transaction.origin == .cashback:
            title = Self.cashbackTitle
            symbolName = Self.cashbackSymbolName
            accountLine = sourceName
        case .expense where transaction.origin == .planFees:
            title = Self.planFeesTitle
            symbolName = Self.planFeesSymbolName
            accountLine = sourceName
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

    /// "₱250.00 · Food · GCash", "₱500.00 · PNB → GCash" for transfers, or
    /// "+₱4.00 · Balance adjustment · GCash" for adjustments. Always shows centavos.
    func confirmationLine(formatter: MoneyFormatter) -> String {
        switch kind {
        case .transfer:
            return "\(formatter.string(amount, alwaysShowCentavos: true)) · \(accountLine)"
        case .adjustment:
            return "\(signedAmountText(formatter: formatter, alwaysShowCentavos: true)) · \(title) · \(accountLine)"
        case .expense, .income, nil:
            return "\(formatter.string(amount, alwaysShowCentavos: true)) · \(title) · \(accountLine)"
        }
    }

    /// "-₱250.00" for expenses, "+₱250.00" for income, "₱500.00" for transfers, and "+" or "-"
    /// for adjustments by direction, so the direction is readable without relying on color.
    func signedAmountText(formatter: MoneyFormatter, alwaysShowCentavos: Bool = false) -> String {
        switch kind {
        case .expense:
            formatter.string(-amount, sign: .always, alwaysShowCentavos: alwaysShowCentavos)
        case .income:
            formatter.string(amount, sign: .always, alwaysShowCentavos: alwaysShowCentavos)
        case .adjustment:
            formatter.string(adjustmentDirection == .decrease ? -amount : amount, sign: .always, alwaysShowCentavos: alwaysShowCentavos)
        case .transfer, nil:
            formatter.string(amount, alwaysShowCentavos: alwaysShowCentavos)
        }
    }

    /// Spoken description, for example "Expense, ₱250.00, Food, GCash, October 12, 2026 at 9:41 AM".
    func accessibilityLabel(formatter: MoneyFormatter) -> String {
        let amountText = formatter.string(amount, alwaysShowCentavos: true)
        let date = occurredAt.formatted(date: .long, time: .shortened)
        switch kind {
        case .transfer:
            return "Transfer, \(amountText), \(accountLine.replacingOccurrences(of: " → ", with: " to ")), \(date)"
        case .adjustment:
            return "\(TransactionKind.adjustment.title), \(signedAmountText(formatter: formatter, alwaysShowCentavos: true)), \(title), \(accountLine), \(date)"
        case .expense, .income:
            return "\(kind?.title ?? ""), \(amountText), \(title), \(accountLine), \(date)"
        case nil:
            return "\(title), \(amountText), \(date)"
        }
    }
}
