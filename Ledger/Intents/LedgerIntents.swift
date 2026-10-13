import AppIntents
import Foundation

// Every Ledger intent runs in the background (the app doesn't open), asks only for missing
// values, and requires the device to be unlocked because it reads or changes financial data.
// Parameters are optional so a custom shortcut can supply any of them in advance; every
// parameter appears in its intent's summary, which value prompts rely on. Amounts use a number
// field, which opens with the decimal pad ready; `IntentFlows` converts the value to an exact
// `Decimal` before anything else touches it. Each intent ends by listing its result in the
// system's own list through `ResultList`, using its `resultRow` parameter.

/// Logs an expense: amount, category, account, then a confirmation.
struct LogExpenseIntent: AppIntent {
    static let title: LocalizedStringResource = "Log Expense"
    static let description = IntentDescription("Record money you spent from one of your accounts.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Amount", description: "In Philippine pesos.", controlStyle: .field)
    var amount: Double?

    @Parameter(title: "Category")
    var category: ExpenseCategoryEntity?

    @Parameter(title: "Account")
    var account: AccountEntity?

    @Parameter(title: "Result", description: "Ledger lists its result here when it finishes. Leave it empty.", optionsProvider: ResultListOptions())
    var resultRow: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Log \(\.$amount) for \(\.$category) from \(\.$account)") {
            \.$resultRow
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let outcome = try await IntentFlows.logExpense(
            in: try IntentLedger.service(),
            amount: amount,
            category: category,
            account: account,
            askAmount: { try await $amount.requestValue(.plain($0)) },
            askCategory: { try await $category.requestValue(.plain($0)) },
            askAccount: { try await $account.requestValue(.plain($0)) },
            confirm: { message, action in try await requestConfirmation(actionName: action, dialog: .plain(message)) }
        )
        await ResultList.show(outcome) { _ = try await $resultRow.requestValue($0) }
        return .result()
    }
}

/// Logs income: amount, income source, receiving account, then a confirmation.
struct LogIncomeIntent: AppIntent {
    static let title: LocalizedStringResource = "Log Income"
    static let description = IntentDescription("Record money you received into one of your accounts.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Amount", description: "In Philippine pesos.", controlStyle: .field)
    var amount: Double?

    @Parameter(title: "Income Source")
    var source: IncomeSourceEntity?

    @Parameter(title: "Account")
    var account: AccountEntity?

    @Parameter(title: "Result", description: "Ledger lists its result here when it finishes. Leave it empty.", optionsProvider: ResultListOptions())
    var resultRow: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Log \(\.$amount) from \(\.$source) into \(\.$account)") {
            \.$resultRow
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let outcome = try await IntentFlows.logIncome(
            in: try IntentLedger.service(),
            amount: amount,
            source: source,
            account: account,
            askAmount: { try await $amount.requestValue(.plain($0)) },
            askSource: { try await $source.requestValue(.plain($0)) },
            askAccount: { try await $account.requestValue(.plain($0)) },
            confirm: { message, action in try await requestConfirmation(actionName: action, dialog: .plain(message)) }
        )
        await ResultList.show(outcome) { _ = try await $resultRow.requestValue($0) }
        return .result()
    }
}

/// Moves money between two accounts: amount, source, destination, then a confirmation.
/// A transfer is neither income nor an expense, and both sides are saved together.
struct TransferMoneyIntent: AppIntent {
    static let title: LocalizedStringResource = "Transfer Money"
    static let description = IntentDescription("Move money between two of your accounts. Transfers don't count as income or expenses.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Amount", description: "In Philippine pesos.", controlStyle: .field)
    var amount: Double?

    @Parameter(title: "From Account")
    var fromAccount: AccountEntity?

    @Parameter(title: "To Account")
    var toAccount: AccountEntity?

    @Parameter(title: "Result", description: "Ledger lists its result here when it finishes. Leave it empty.", optionsProvider: ResultListOptions())
    var resultRow: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Transfer \(\.$amount) from \(\.$fromAccount) to \(\.$toAccount)") {
            \.$resultRow
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let outcome = try await IntentFlows.transfer(
            in: try IntentLedger.service(),
            amount: amount,
            from: fromAccount,
            to: toAccount,
            askAmount: { try await $amount.requestValue(.plain($0)) },
            askSource: { try await $fromAccount.requestValue(.plain($0)) },
            chooseDestination: { options, prompt in try await $toAccount.requestDisambiguation(among: options, dialog: .plain(prompt)) },
            confirm: { message, action in try await requestConfirmation(actionName: action, dialog: .plain(message)) }
        )
        await ResultList.show(outcome) { _ = try await $resultRow.requestValue($0) }
        return .result()
    }
}

/// Shows each active account's balance and the total liquid balance. Read-only.
struct CheckBalancesIntent: AppIntent {
    static let title: LocalizedStringResource = "Check Balances"
    static let description = IntentDescription("See the balance of each active account and your total liquid balance. Nothing is changed.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Result", description: "Ledger lists its result here when it finishes. Leave it empty.", optionsProvider: ResultListOptions())
    var resultRow: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Check balances") {
            \.$resultRow
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let outcome = try IntentFlows.balances(in: IntentLedger.service())
        await ResultList.show(outcome) { _ = try await $resultRow.requestValue($0) }
        return .result()
    }
}

/// Logs an expense or income from the text of a payment email or message, typically passed in by
/// a Shortcuts automation that runs when a bank notification arrives. It isn't an App Shortcut,
/// because it needs that text; it appears as an action in the Shortcuts library.
struct LogFromMessageIntent: AppIntent {
    static let title: LocalizedStringResource = "Log From Message"
    static let description = IntentDescription("Read a payment email or text, such as a bank notification, and log it after you confirm. Use it in an automation that runs when the email arrives.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Message", description: "The email or text to read.", inputOptions: String.IntentInputOptions(multiline: true))
    var message: String?

    @Parameter(title: "Account")
    var account: AccountEntity?

    @Parameter(title: "Category")
    var expenseCategory: ExpenseCategoryEntity?

    @Parameter(title: "Income Source")
    var incomeSource: IncomeSourceEntity?

    @Parameter(title: "Amount", description: "Asked for only when the message doesn't show one.", controlStyle: .field)
    var amount: Double?

    @Parameter(title: "Result", description: "Ledger lists its result here when it finishes. Leave it empty.", optionsProvider: ResultListOptions())
    var resultRow: String?

    static var parameterSummary: some ParameterSummary {
        Summary("Log from \(\.$message) using \(\.$account)") {
            \.$expenseCategory
            \.$incomeSource
            \.$amount
            \.$resultRow
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let text: String
        if let message, !message.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            text = message
        } else {
            text = try await $message.requestValue(.plain("Paste the payment message to read."))
        }
        let outcome = try await IntentFlows.logFromMessage(
            in: try IntentLedger.service(),
            message: text,
            amount: amount,
            account: account,
            expenseCategory: expenseCategory,
            incomeSource: incomeSource,
            askAmount: { try await $amount.requestValue(.plain($0)) },
            chooseDirection: { prompt in
                let moneyOut = IntentChoiceOption(title: "Money Out (Expense)")
                let moneyIn = IntentChoiceOption(title: "Money In (Income)")
                let choice = try await requestChoice(between: [moneyOut, moneyIn, .cancel], dialog: .plain(prompt))
                if choice == moneyOut { return .moneyOut }
                if choice == moneyIn { return .moneyIn }
                throw CancellationError()
            },
            askCategory: { try await $expenseCategory.requestValue(.plain($0)) },
            askSource: { try await $incomeSource.requestValue(.plain($0)) },
            askAccount: { try await $account.requestValue(.plain($0)) },
            confirm: { message, action in try await requestConfirmation(actionName: action, dialog: .plain(message)) }
        )
        await ResultList.show(outcome) { _ = try await $resultRow.requestValue($0) }
        return .result()
    }
}

/// One shortcut for the Action Button: choose Expense, Income, Transfer, or Check Balances,
/// then continue with that flow.
struct LedgerMenuIntent: AppIntent {
    static let title: LocalizedStringResource = "Ledger Menu"
    static let description = IntentDescription("Choose to log an expense, income, or a transfer, or check your balances.")
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresAuthentication

    @Parameter(title: "Action", requestValueDialog: "What would you like to do?")
    var action: LedgerAction

    @Parameter(title: "Amount", description: "In Philippine pesos.", controlStyle: .field)
    var amount: Double?

    @Parameter(title: "Category")
    var expenseCategory: ExpenseCategoryEntity?

    @Parameter(title: "Income Source")
    var incomeSource: IncomeSourceEntity?

    @Parameter(title: "Account")
    var account: AccountEntity?

    @Parameter(title: "To Account")
    var destinationAccount: AccountEntity?

    @Parameter(title: "Result", description: "Ledger lists its result here when it finishes. Leave it empty.", optionsProvider: ResultListOptions())
    var resultRow: String?

    static var parameterSummary: some ParameterSummary {
        Switch(\.$action) {
            Case(.expense) {
                Summary("Log \(\.$action) of \(\.$amount) for \(\.$expenseCategory) from \(\.$account)") {
                    \.$resultRow
                }
            }
            Case(.income) {
                Summary("Log \(\.$action) of \(\.$amount) from \(\.$incomeSource) into \(\.$account)") {
                    \.$resultRow
                }
            }
            Case(.transfer) {
                Summary("\(\.$action) \(\.$amount) from \(\.$account) to \(\.$destinationAccount)") {
                    \.$resultRow
                }
            }
            DefaultCase {
                // Runs start before an action is chosen, so this summary must list every
                // parameter the flows can ask for; value prompts fail for unlisted parameters.
                Summary("\(\.$action)") {
                    \.$amount
                    \.$expenseCategory
                    \.$incomeSource
                    \.$account
                    \.$destinationAccount
                    \.$resultRow
                }
            }
        }
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        let confirm: IntentFlows.Confirm = { message, action in
            try await requestConfirmation(actionName: action, dialog: .plain(message))
        }
        let ledger = try IntentLedger.service()
        let outcome: IntentOutcome
        switch action {
        case .expense:
            outcome = try await IntentFlows.logExpense(
                in: ledger,
                amount: amount,
                category: expenseCategory,
                account: account,
                askAmount: { try await $amount.requestValue(.plain($0)) },
                askCategory: { try await $expenseCategory.requestValue(.plain($0)) },
                askAccount: { try await $account.requestValue(.plain($0)) },
                confirm: confirm
            )
        case .income:
            outcome = try await IntentFlows.logIncome(
                in: ledger,
                amount: amount,
                source: incomeSource,
                account: account,
                askAmount: { try await $amount.requestValue(.plain($0)) },
                askSource: { try await $incomeSource.requestValue(.plain($0)) },
                askAccount: { try await $account.requestValue(.plain($0)) },
                confirm: confirm
            )
        case .transfer:
            outcome = try await IntentFlows.transfer(
                in: ledger,
                amount: amount,
                from: account,
                to: destinationAccount,
                askAmount: { try await $amount.requestValue(.plain($0)) },
                askSource: { try await $account.requestValue(.plain($0)) },
                chooseDestination: { options, prompt in
                    try await $destinationAccount.requestDisambiguation(among: options, dialog: .plain(prompt))
                },
                confirm: confirm
            )
        case .balances:
            outcome = try IntentFlows.balances(in: ledger)
        }
        await ResultList.show(outcome) { _ = try await $resultRow.requestValue($0) }
        return .result()
    }
}
