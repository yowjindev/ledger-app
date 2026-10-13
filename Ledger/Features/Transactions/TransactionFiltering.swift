import Foundation

/// Transaction types the Activity list can be narrowed to.
enum TransactionTypeFilter: String, CaseIterable, Identifiable, Sendable {
    case all
    case expenses
    case income
    case transfers

    var id: String { rawValue }

    var title: String {
        switch self {
        case .all: "All"
        case .expenses: "Expenses"
        case .income: "Income"
        case .transfers: "Transfers"
        }
    }

    var systemImage: String {
        switch self {
        case .all: "list.bullet"
        case .expenses: TransactionKind.expense.systemImage
        case .income: TransactionKind.income.systemImage
        case .transfers: TransactionKind.transfer.systemImage
        }
    }

    /// The only kind kept, or `nil` to keep every kind.
    var kind: TransactionKind? {
        switch self {
        case .all: nil
        case .expenses: .expense
        case .income: .income
        case .transfers: .transfer
        }
    }
}

/// Narrows transaction history by type and account.
struct TransactionFilter: Equatable, Sendable {
    var type: TransactionTypeFilter = .all
    /// Keeps transactions that involve this account in any role (including either side of a
    /// transfer), or every account when `nil`.
    var accountID: UUID?

    var isActive: Bool { type != .all || accountID != nil }

    mutating func clear() {
        type = .all
        accountID = nil
    }

    @MainActor
    func includes(_ transaction: LedgerTransaction) -> Bool {
        if let kind = type.kind, transaction.kind != kind { return false }
        if let accountID,
           transaction.account?.id != accountID,
           transaction.destinationAccount?.id != accountID {
            return false
        }
        return true
    }
}

/// Free-text search over transaction history.
enum TransactionSearch {
    private static let posix = Locale(identifier: "en_US_POSIX")

    /// Whether `transaction` matches `query`. Matches the category or income source, both
    /// accounts of a transfer, the note, the reference, the type, and the amount (see
    /// `amount(_:matches:)`). An empty query matches everything.
    @MainActor
    static func matches(_ transaction: LedgerTransaction, query: String, locale: Locale = .autoupdatingCurrent) -> Bool {
        let query = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return true }

        let texts: [String?] = [
            transaction.category?.name,
            transaction.account?.name,
            transaction.destinationAccount?.name,
            transaction.note,
            transaction.reference,
            transaction.kind?.title,
        ]
        if texts.contains(where: { $0?.localizedStandardContains(query) == true }) {
            return true
        }
        guard let amountQuery = amountQuery(from: query, locale: locale) else { return false }
        return amount(transaction.amount, matches: amountQuery)
    }

    /// Compares a normalized amount query with the amount's plain decimal form. A whole number
    /// matches every amount with that many pesos ("250" finds ₱250.00 and ₱250.50, not ₱2,500);
    /// with decimals it must equal the amount ("250.5" and "250.50" find ₱250.50 only).
    static func amount(_ money: Money, matches query: String) -> Bool {
        let plain = plainAmount(money).split(separator: ".", omittingEmptySubsequences: false)
        let typed = query.split(separator: ".", omittingEmptySubsequences: false)
        guard let wholeUnits = plain.first, let typedWholeUnits = typed.first, wholeUnits == typedWholeUnits else {
            return false
        }
        guard typed.count > 1, !typed[1].isEmpty else { return true }
        let minorUnits = plain.count > 1 ? String(plain[1]) : ""
        let typedMinorUnits = String(typed[1])
        guard typedMinorUnits.count <= minorUnits.count else { return false }
        return typedMinorUnits.padding(toLength: minorUnits.count, withPad: "0", startingAt: 0) == minorUnits
    }

    /// The amount with "." as the decimal separator, no grouping, and every minor-unit digit,
    /// for example "250.50" or "1850.00".
    static func plainAmount(_ money: Money) -> String {
        money.amount.formatted(
            .number
                .locale(posix)
                .grouping(.never)
                .precision(.fractionLength(money.currency.minorUnitDigits))
        )
    }

    /// Typed amount text in plain decimal form ("₱1,850.5" → "1850.5", "07" → "7", ".5" → "0.5"),
    /// or `nil` when the text isn't an amount. Currency labels, spaces, and grouping separators
    /// are ignored.
    static func amountQuery(from text: String, locale: Locale) -> String? {
        let decimalSeparator = locale.decimalSeparator ?? "."
        let groupingSeparator = locale.groupingSeparator ?? ","

        var cleaned = text
            .replacingOccurrences(of: "₱", with: "")
            .replacingOccurrences(of: "PHP", with: "", options: .caseInsensitive)
        cleaned.removeAll { $0.isWhitespace }
        if !groupingSeparator.isEmpty, groupingSeparator != decimalSeparator {
            cleaned = cleaned.replacingOccurrences(of: groupingSeparator, with: "")
        }
        if decimalSeparator != "." {
            cleaned = cleaned.replacingOccurrences(of: decimalSeparator, with: ".")
        }

        let isDigit: (Character) -> Bool = { ("0"..."9").contains($0) }
        let parts = cleaned.split(separator: ".", omittingEmptySubsequences: false)
        guard
            cleaned.contains(where: isDigit),
            cleaned.allSatisfy({ isDigit($0) || $0 == "." }),
            parts.count <= 2,
            let typedWholeUnits = parts.first
        else { return nil }
        let wholeUnits = typedWholeUnits.drop { $0 == "0" }
        let normalizedWholeUnits = wholeUnits.isEmpty ? "0" : String(wholeUnits)
        return parts.count == 2 ? "\(normalizedWholeUnits).\(parts[1])" : normalizedWholeUnits
    }
}

/// Transactions that occurred on one local calendar day.
struct TransactionDay: Identifiable {
    /// Start of the day in the user's calendar and time zone.
    let date: Date
    /// The day's transactions, in the order they were given.
    let transactions: [LedgerTransaction]

    var id: Date { date }

    /// Groups transactions by the local day they occurred on, newest day first. Each day keeps
    /// the order of `transactions`.
    @MainActor
    static func group(_ transactions: [LedgerTransaction], calendar: Calendar = .current) -> [TransactionDay] {
        Dictionary(grouping: transactions) { calendar.startOfDay(for: $0.occurredAt) }
            .map { TransactionDay(date: $0.key, transactions: $0.value) }
            .sorted { $0.date > $1.date }
    }

    /// "Today", "Yesterday", "Mon, Oct 6" within the current year, or "Mon, Oct 6, 2025" otherwise.
    static func title(for day: Date, now: Date, calendar: Calendar = .current) -> String {
        if calendar.isDate(day, inSameDayAs: now) {
            return "Today"
        }
        if let yesterday = calendar.date(byAdding: .day, value: -1, to: now),
           calendar.isDate(day, inSameDayAs: yesterday) {
            return "Yesterday"
        }
        var style = Date.FormatStyle.dateTime.weekday(.abbreviated).month(.abbreviated).day()
        style.calendar = calendar
        style.timeZone = calendar.timeZone
        if !calendar.isDate(day, equalTo: now, toGranularity: .year) {
            style = style.year()
        }
        return day.formatted(style)
    }
}
