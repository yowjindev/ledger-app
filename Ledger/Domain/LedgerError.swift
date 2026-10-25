import Foundation

/// Errors raised by `LedgerService`. Messages are user-facing and never include balances.
enum LedgerError: Error, Equatable, Sendable {
    case amountNotPositive
    case amountTooLarge
    case amountTooPrecise
    case openingBalanceNegative
    case balanceNegative
    case balanceBelowRecordedActivity(name: String)
    case missingAccount
    case missingDestinationAccount
    case missingCategory
    case sameSourceAndDestination
    case accountNotFound
    case categoryNotFound
    case transactionNotFound
    case accountArchived(name: String)
    case categoryArchived(name: String)
    case categoryKindMismatch(expected: CategoryKind)
    case currencyMismatch
    case emptyName
    case nameTooLong(limit: Int)
    case duplicateName(String)
    case textTooLong(limit: Int)
    case accountHasTransactions(name: String)
    case categoryInUse(name: String)
    case conflictingRequest
    case entryNotEditable
    case interestRateOutOfRange
    case taxRateOutOfRange
    case rateTooPrecise
    case owedNegative
    case wrongAccountGroup
    case dayOutOfRange
    case statementDayRequired
    case cashbackNotOffered
    case cashbackRateOutOfRange
    case stillDueNotApplicable
    case stillDueAboveOwed
    case persistenceFailed
}

extension LedgerError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .amountNotPositive:
            "Enter an amount greater than zero."
        case .amountTooLarge:
            "That amount is too large."
        case .amountTooPrecise:
            "Amounts can have at most two decimal places."
        case .openingBalanceNegative:
            "An opening balance can't be negative."
        case .balanceNegative:
            "A balance can't be negative."
        case .balanceBelowRecordedActivity(let name):
            "The entries already logged for \(name) don't fit that balance. Check the amount, or review \(name)'s entries in Activity."
        case .missingAccount:
            "Choose an account."
        case .missingDestinationAccount:
            "Choose the account receiving the transfer."
        case .missingCategory:
            "Choose a category."
        case .sameSourceAndDestination:
            "Choose two different accounts for a transfer."
        case .accountNotFound:
            "That account no longer exists."
        case .categoryNotFound:
            "That category no longer exists."
        case .transactionNotFound:
            "That transaction no longer exists."
        case .accountArchived(let name):
            "\(name) is archived. Unarchive it in Settings to use it again."
        case .categoryArchived(let name):
            "\(name) is archived. Unarchive it in Settings to use it again."
        case .categoryKindMismatch(let expected):
            expected == .expense ? "Choose an expense category." : "Choose an income source."
        case .currencyMismatch:
            "These accounts use different currencies."
        case .emptyName:
            "Enter a name."
        case .nameTooLong(let limit):
            "Names can be at most \(limit) characters."
        case .duplicateName(let name):
            "“\(name)” is already in use."
        case .textTooLong(let limit):
            "Keep this under \(limit) characters."
        case .accountHasTransactions(let name):
            "\(name) has transactions, so it can't be deleted. Archive it instead."
        case .categoryInUse(let name):
            "\(name) is used by transactions, so it can't be deleted. Archive it instead."
        case .conflictingRequest:
            "This entry conflicts with one that was already saved."
        case .entryNotEditable:
            "Ledger keeps this entry as it is. Use Update Balance to correct a balance."
        case .interestRateOutOfRange:
            "Enter an interest rate above 0% and up to 100%."
        case .taxRateOutOfRange:
            "Enter a tax rate from 0% to 100%."
        case .rateTooPrecise:
            "Rates can have at most four decimal places."
        case .owedNegative:
            "What you owe can't be negative."
        case .wrongAccountGroup:
            "Money you have and money you owe are kept apart, so this can't be changed."
        case .dayOutOfRange:
            "Choose a day from 1 to 31."
        case .statementDayRequired:
            "Choose the day the statement closes."
        case .cashbackNotOffered:
            "Only credit cards can have cashback."
        case .cashbackRateOutOfRange:
            "Enter a cashback rate above 0% and up to 100%."
        case .stillDueNotApplicable:
            "No bill is waiting for payment right now. Leave this empty."
        case .stillDueAboveOwed:
            "What's still due can't be more than the total you owe."
        case .persistenceFailed:
            "Ledger couldn't save. No changes were made."
        }
    }
}
