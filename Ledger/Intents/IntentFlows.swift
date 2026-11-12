import AppIntents
import Foundation
import os

/// What an intent shows and says when it finishes: a headline above a list of rows, both drawn by
/// the system, and the full text, which Siri speaks.
struct IntentOutcome {
    /// What happened, for example "Expense saved".
    let headline: String
    /// The specifics, for example "₱250.00 · Food · GCash. GCash balance: ₱3,980.00".
    let body: String?
    /// Whether `body` is a complete sentence, joined to the headline with a period rather than a dash.
    var bodyIsSentence = false
    /// Rows listed under the headline: the saved entry and updated balances, or every balance.
    var rows: [ResultRow] = []
    /// A short note shown with the headline above the rows.
    var note: String?

    /// One line of text: the system shows dialogs as a single paragraph, without line breaks.
    var text: String {
        guard let body else { return headline }
        return bodyIsSentence ? "\(headline). \(body)" : "\(headline) — \(body)"
    }

    /// What's shown above the rows: the headline, then the note when there is one.
    var heading: String {
        guard let note else { return headline }
        return "\(headline). \(note)"
    }

    /// With rows, only the heading is shown above them; the full text is still spoken.
    var dialog: IntentDialog {
        rows.isEmpty ? IntentDialog("\(text)") : IntentDialog(full: "\(text)", supporting: "\(heading)")
    }
}

/// One row of an intent result.
struct ResultRow: Identifiable, Sendable {
    let id: UUID
    let symbolName: String
    let title: String
    let subtitle: String?
    /// The row's figure, such as an amount, shown before the subtitle. `nil` reads "Not Set".
    let value: String?
}

/// The logging and balance flows shared by the individual intents and the Ledger Menu intent.
///
/// A flow asks only for inputs that weren't supplied, in a fixed order (amount, then category or
/// source, then account), validates through `LedgerService`, asks for confirmation where needed,
/// records, and describes the result. Cancelling any prompt ends the flow before anything is saved.
@MainActor
enum IntentFlows {
    /// Asks for a parameter value with the given prompt.
    typealias Ask<Value> = (String) async throws -> Value
    /// Asks the person to pick one of the options, with the given prompt.
    typealias Choose<Value> = ([Value], String) async throws -> Value
    /// Asks the person to confirm the given message; throws if they decline.
    typealias Confirm = (String, ConfirmationActionName) async throws -> Void

    // MARK: Flows

    static func logExpense(
        in ledger: LedgerService,
        amount: Double?,
        category: ExpenseCategoryEntity?,
        account: AccountEntity?,
        askAmount: Ask<Double>,
        askCategory: Ask<ExpenseCategoryEntity>,
        askAccount: Ask<AccountEntity>,
        confirm: Confirm
    ) async throws -> IntentOutcome {
        try requireCategories(.expense, in: ledger)
        try requireAccounts(1, in: ledger)
        let value = try await resolveAmount(amount, prompt: "How much did you spend?", ask: askAmount)
        let categoryID = try await resolve(category?.id) { try await askCategory("What was it for?").id }
        let accountID = try await resolve(account?.id) { try await askAccount("Which account did you pay from?").id }
        let draft = TransactionDraft.expense(amount: value, accountID: accountID, categoryID: categoryID, occurredAt: ledger.now)
        let transaction = try await record(draft, in: ledger, confirm: confirm)
        return savedOutcome(for: transaction, in: ledger)
    }

    static func logIncome(
        in ledger: LedgerService,
        amount: Double?,
        source: IncomeSourceEntity?,
        account: AccountEntity?,
        askAmount: Ask<Double>,
        askSource: Ask<IncomeSourceEntity>,
        askAccount: Ask<AccountEntity>,
        confirm: Confirm
    ) async throws -> IntentOutcome {
        try requireCategories(.income, in: ledger)
        try requireAccounts(1, in: ledger)
        let value = try await resolveAmount(amount, prompt: "How much did you receive?", ask: askAmount)
        let sourceID = try await resolve(source?.id) { try await askSource("Where is it from?").id }
        let accountID = try await resolve(account?.id) { try await askAccount("Which account received it?").id }
        let draft = TransactionDraft.income(amount: value, accountID: accountID, sourceID: sourceID, occurredAt: ledger.now)
        let transaction = try await record(draft, in: ledger, confirm: confirm)
        return savedOutcome(for: transaction, in: ledger)
    }

    /// Asks for the destination from the accounts other than the source, so a transfer can't
    /// use the same account twice.
    static func transfer(
        in ledger: LedgerService,
        amount: Double?,
        from source: AccountEntity?,
        to destination: AccountEntity?,
        askAmount: Ask<Double>,
        askSource: Ask<AccountEntity>,
        chooseDestination: Choose<AccountEntity>,
        confirm: Confirm
    ) async throws -> IntentOutcome {
        try requireAccounts(2, in: ledger)
        let value = try await resolveAmount(amount, prompt: "How much are you transferring?", ask: askAmount)
        let sourceID = try await resolve(source?.id) { try await askSource("Transfer from which account?").id }
        let destinationID: UUID
        if let destination, destination.id != sourceID {
            destinationID = destination.id
        } else {
            let options = try ledger.accounts().filter { $0.id != sourceID }.map(AccountEntity.init)
            destinationID = try await chooseDestination(options, "Transfer to which account?").id
        }
        let draft = TransactionDraft.transfer(amount: value, fromAccountID: sourceID, toAccountID: destinationID, occurredAt: ledger.now)
        let transaction = try await record(draft, in: ledger, confirm: confirm)
        return savedOutcome(for: transaction, in: ledger)
    }

    /// Logs an expense or income from a payment notification's text, such as a bank email passed
    /// in by a Shortcuts automation. Reads the amount, whether money went out or came in, and any
    /// reference number on the device; asks for whatever it couldn't read; and always asks before
    /// saving, because the entry comes from text Ledger didn't write.
    static func logFromMessage(
        in ledger: LedgerService,
        message: String,
        amount: Double?,
        account: AccountEntity?,
        expenseCategory: ExpenseCategoryEntity?,
        incomeSource: IncomeSourceEntity?,
        askAmount: Ask<Double>,
        chooseDirection: Ask<ParsedPaymentMessage.Direction>,
        askCategory: Ask<ExpenseCategoryEntity>,
        askSource: Ask<IncomeSourceEntity>,
        askAccount: Ask<AccountEntity>,
        confirm: Confirm
    ) async throws -> IntentOutcome {
        try requireAccounts(1, in: ledger)
        let parsed = PaymentMessageParser.parse(message)

        let value: Decimal
        if let found = parsed.amount, (try? AmountRules.transactionMinorUnits(found, currency: .php)) != nil {
            value = found
        } else {
            value = try await resolveAmount(amount, prompt: "Ledger couldn't find the amount. How much was it?", ask: askAmount)
        }

        let direction: ParsedPaymentMessage.Direction
        if let found = parsed.direction {
            direction = found
        } else {
            direction = try await chooseDirection("Was this money going out or coming in?")
        }

        let kind: TransactionKind = direction == .moneyOut ? .expense : .income
        try requireCategories(kind == .expense ? .expense : .income, in: ledger)
        let categoryID: UUID
        if kind == .expense {
            categoryID = try await resolve(expenseCategory?.id) { try await askCategory("What was it for?").id }
        } else {
            categoryID = try await resolve(incomeSource?.id) { try await askSource("Where is it from?").id }
        }
        let accountID = try await resolve(account?.id) {
            try await askAccount(kind == .expense ? "Which account did you pay from?" : "Which account received it?").id
        }

        let draft = TransactionDraft(
            kind: kind,
            amount: value,
            occurredAt: ledger.now,
            accountID: accountID,
            categoryID: categoryID,
            reference: parsed.reference
        )
        let transaction = try await record(draft, in: ledger, confirm: confirm, alwaysConfirm: true)
        return savedOutcome(for: transaction, in: ledger)
    }

    /// Reads balances: one row per active money account, then what's owed and the next due when
    /// there are credit cards, pay later accounts, loans, or bills, and the total when any opening
    /// balance is known. Never modifies anything.
    static func balances(in ledger: LedgerService) throws -> IntentOutcome {
        let sheet = try ledger.balanceSheet()
        let formatter = MoneyFormatter.current()
        let active = sheet.moneyBalances
        guard !sheet.activeBalances.isEmpty else { throw LedgerIntentError.noActiveAccounts }
        let moneyRows = active.map { balance in
            ResultRow(
                id: balance.id,
                symbolName: balance.account.kind.systemImage,
                title: balance.account.name,
                subtitle: balance.account.kind.title,
                value: balance.currentBalance.map { formatter.string($0) }
            )
        }
        let owed = try owedRows(sheet: sheet, ledger: ledger, formatter: formatter)
        let rows = moneyRows + owed.map(\.row)
        let liquid = sheet.liquidTotal
        let note = LiquidTotalCopy.note(for: liquid)
        guard !liquid.includedAccountIDs.isEmpty else {
            return IntentOutcome(headline: "Opening balances aren't set yet", body: note, bodyIsSentence: true, rows: rows, note: note)
        }
        var body = moneyRows.map { "\($0.title) \($0.value ?? "Not Set")" }.joined(separator: " · ")
        for line in owed {
            body += " · \(line.spoken)"
        }
        if let note {
            body += ". \(note)"
        }
        return IntentOutcome(
            headline: "Total liquid: \(formatter.string(liquid.total))",
            body: body,
            rows: rows,
            note: note
        )
    }

    /// "You owe" with the total owed, and "Next due" with the first unpaid due, when they apply,
    /// each with the words it's read out as.
    private static func owedRows(
        sheet: BalanceSheet,
        ledger: LedgerService,
        formatter: MoneyFormatter
    ) throws -> [(row: ResultRow, spoken: String)] {
        var rows: [(row: ResultRow, spoken: String)] = []
        if !sheet.owedBalances.isEmpty {
            let total = formatter.string(sheet.totalOwed)
            rows.append((ResultRow(
                id: UUID(),
                symbolName: AccountKind.creditCard.systemImage,
                title: "You owe",
                subtitle: "Cards, pay later, and loans",
                value: total
            ), "You owe \(total)"))
        }
        if let next = try ledger.comingUp().first(where: { !$0.isPaid }) {
            let name: String? = switch next.owner {
            case .account(let id): try ledger.account(id: id)?.name
            case .bill(let id): try ledger.bill(id: id)?.name
            }
            let date = DueStatusCopy.dateText(next, today: ledger.today, calendar: ledger.calendar)
            let amount = DueStatusCopy.amountText(next, formatter: formatter)
            rows.append((ResultRow(
                id: UUID(),
                symbolName: "calendar",
                title: "Next due",
                subtitle: [name, date].compactMap { $0 }.joined(separator: " · "),
                value: amount
            ), "Next: \([name, date.lowercased(), amount].compactMap { $0 }.joined(separator: ", "))"))
        }
        return rows
    }

    /// Brings an account to its real balance: asks for the account and the balance, then asks
    /// before recording an adjustment for the difference, or setting the opening balance when it
    /// isn't known. Records nothing when Ledger's balance already matches.
    static func updateBalance(
        in ledger: LedgerService,
        account: AccountEntity?,
        amount: Double?,
        askAccount: Ask<AccountEntity>,
        askAmount: Ask<Double>,
        confirm: Confirm
    ) async throws -> IntentOutcome {
        try requireAccounts(1, in: ledger)
        let accountID = try await resolve(account?.id) { try await askAccount("Which account do you want to update?").id }
        guard let target = try ledger.account(id: accountID) else { throw LedgerIntentError.ledger(.accountNotFound) }
        guard !target.isArchived else { throw LedgerIntentError.ledger(.accountArchived(name: target.name)) }
        if target.kind.isOwed {
            return try await updateOwed(in: ledger, target: target, amount: amount, askAmount: askAmount, confirm: confirm)
        }
        let value = try await resolveAmount(amount, prompt: "What's \(target.name)'s real balance?", ask: askAmount)

        let formatter = MoneyFormatter.current()
        let realBalance = formatter.string(Money(value, currency: target.currency), alwaysShowCentavos: true)
        switch try IntentLedger.perform({ try ledger.balanceCorrection(toReach: value, for: target) }) {
        case .alreadyMatches:
            return IntentOutcome(
                headline: "\(target.name) already matches",
                body: "\(target.name) balance: \(realBalance)",
                bodyIsSentence: true,
                rows: [balanceRow(for: target, value: realBalance, subtitle: "Balance")]
            )
        case .adjustment(let difference):
            let change = formatter.string(difference, sign: .always, alwaysShowCentavos: true)
            try await confirm("Add a \(change) balance adjustment to \(target.name)?", .continue)
        case .setOpeningBalance:
            try await confirm("Set \(target.name)'s opening balance so its balance is \(realBalance)?", .continue)
        }

        let applied = try IntentLedger.perform { try ledger.updateBalance(of: target, to: value, origin: .appIntent) }
        Log.intents.info("Updated a balance from an App Intent")
        let current = (try? ledger.balance(of: target))?.currentBalance.map { formatter.string($0, alwaysShowCentavos: true) }
        let balanceLine = "\(target.name) balance: \(current ?? realBalance)"
        let balance = balanceRow(for: target, value: current ?? realBalance, subtitle: "New balance")
        switch applied {
        case .adjustment(let difference):
            let change = formatter.string(difference, sign: .always, alwaysShowCentavos: true)
            let adjustment = ResultRow(
                id: UUID(),
                symbolName: TransactionKind.adjustment.systemImage,
                title: TransactionSummary.adjustmentTitle,
                subtitle: "\(TransactionKind.adjustment.title) · \(target.name)",
                value: change
            )
            return IntentOutcome(
                headline: "Balance updated",
                body: "\(change) · \(TransactionSummary.adjustmentTitle) · \(target.name). \(balanceLine)",
                rows: [adjustment, balance]
            )
        case .setOpeningBalance(let opening):
            let openingText = formatter.string(opening, alwaysShowCentavos: true)
            return IntentOutcome(
                headline: "Balance updated",
                body: "\(target.name)'s opening balance is \(openingText). \(balanceLine)",
                bodyIsSentence: true,
                rows: [balance]
            )
        case .alreadyMatches:
            return IntentOutcome(headline: "\(target.name) already matches", body: balanceLine, bodyIsSentence: true, rows: [balance])
        }
    }

    /// Matches what a credit card, pay later account, or loan owes to the bank's figure: asks
    /// for the amount, then asks before recording the change.
    private static func updateOwed(
        in ledger: LedgerService,
        target: Account,
        amount: Double?,
        askAmount: Ask<Double>,
        confirm: Confirm
    ) async throws -> IntentOutcome {
        let value = try await resolveAmount(amount, prompt: "What do you owe on \(target.name)?", ask: askAmount)
        let formatter = MoneyFormatter.current()
        let owedText = formatter.string(Money(value, currency: target.currency), alwaysShowCentavos: true)
        let row = balanceRow(for: target, value: owedText, subtitle: "You owe")
        switch try IntentLedger.perform({ try ledger.owedCorrection(toOwe: value, for: target) }) {
        case .alreadyMatches:
            return IntentOutcome(
                headline: "\(target.name) already matches",
                body: "You owe \(owedText) on \(target.name)",
                bodyIsSentence: true,
                rows: [row]
            )
        case .adjustment, .setOpeningBalance:
            try await confirm("Change what you owe on \(target.name) to \(owedText)?", .continue)
        }
        _ = try IntentLedger.perform { try ledger.updateOwed(of: target, to: value, origin: .appIntent) }
        Log.intents.info("Updated what an owed account owes from an App Intent")
        return IntentOutcome(
            headline: "Updated what you owe",
            body: "You owe \(owedText) on \(target.name)",
            bodyIsSentence: true,
            rows: [row]
        )
    }

    private static func balanceRow(for account: Account, value: String, subtitle: String) -> ResultRow {
        ResultRow(id: account.id, symbolName: account.kind.systemImage, title: account.name, subtitle: subtitle, value: value)
    }

    // MARK: Amounts

    /// Returns a valid peso amount, asking again with an explanation when the entry is invalid.
    /// A supplied zero counts as no amount: Shortcuts passes zero for an amount left empty.
    static func resolveAmount(_ preset: Double?, prompt: String, ask: Ask<Double>) async throws -> Decimal {
        var pending = preset.flatMap { $0 == 0 ? nil : $0 }
        var question = prompt
        var lastError = LedgerIntentError.ledger(.amountNotPositive)
        for _ in 0..<IntentPolicy.amountAttempts {
            let entered: Double
            if let value = pending {
                entered = value
                pending = nil
            } else {
                entered = try await ask(question)
            }
            do {
                return try validatedAmount(entered)
            } catch let error as LedgerIntentError {
                lastError = error
                question = "\(error.message) \(prompt)"
            }
        }
        throw lastError
    }

    /// Accepts positive peso amounts with at most two decimal places, within the ledger's limit.
    ///
    /// The number field delivers a `Double`. It is converted through its shortest decimal
    /// representation, which gives back exactly the digits that were typed (19.99 stays 19.99),
    /// and nothing is calculated in floating point.
    static func validatedAmount(_ value: Double) throws -> Decimal {
        guard value.isFinite, let parsed = Decimal(string: value.description, locale: Locale(identifier: "en_US_POSIX")) else {
            throw LedgerIntentError.ledger(.amountNotPositive)
        }
        let amount = snappedToCentavos(parsed)
        _ = try IntentLedger.perform { try AmountRules.transactionMinorUnits(amount, currency: .php) }
        return amount
    }

    /// A value a shortcut calculated in floating point, such as 0.1 + 0.2, carries noise
    /// (0.30000000000000004). Such a value is snapped to the nearest centavo when it lies within a
    /// billionth of it; finer amounts like 10.555 are left unchanged so validation refuses them.
    static func snappedToCentavos(_ amount: Decimal) -> Decimal {
        guard !amount.isNaN else { return amount }
        var value = amount
        var rounded = Decimal()
        NSDecimalRound(&rounded, &value, CurrencyCode.php.minorUnitDigits, .plain)
        let tolerance = Decimal(sign: .plus, exponent: -9, significand: 1)
        return (rounded - amount).magnitude < tolerance ? rounded : amount
    }

    // MARK: Recording

    /// Validates the entry, asks for any confirmation it needs, then saves it.
    ///
    /// Transfers are always confirmed. Expenses and income are confirmed when they match an entry
    /// saved moments ago (if that preference is on) or when the amount is unusually large.
    /// - Parameter alwaysConfirm: Confirms an expense or income even without a reason to, for
    ///   entries built from text Ledger read rather than values the person chose.
    private static func record(_ draft: TransactionDraft, in ledger: LedgerService, confirm: Confirm, alwaysConfirm: Bool = false) async throws -> LedgerTransaction {
        // Validating first means no confirmation is shown for an entry the ledger would refuse.
        let resolved = try IntentLedger.perform { try ledger.resolve(draft, editing: nil) }
        let formatter = MoneyFormatter.current()
        let amountText = formatter.string(Money(draft.amount, currency: resolved.currency), alwaysShowCentavos: true)

        var notes: [String] = []
        if let reference = resolved.reference, try !ledger.transactions(withReference: reference).isEmpty {
            notes.append("You already logged a transaction with reference \(reference).")
        }
        if AppPreferences.warnsAboutDuplicates(), let duplicate = try ledger.recentDuplicate(of: draft) {
            let line = TransactionSummary(duplicate).confirmationLine(formatter: formatter)
            notes.append("You logged \(line) \(duplicate.createdAt.formatted(.relative(presentation: .named))).")
        }
        switch draft.kind {
        case .transfer:
            let destination = resolved.destination?.name ?? TransactionSummary.unknownAccount
            let question = "Transfer \(amountText) from \(resolved.account.name) to \(destination)?"
            try await confirm((notes + [question]).joined(separator: " "), .continue)
        case .expense, .income:
            if alwaysConfirm {
                let category = resolved.category?.name ?? draft.kind.title
                let question = draft.kind == .expense
                    ? "Log \(amountText) \(category) expense from \(resolved.account.name)?"
                    : "Log \(amountText) \(category) income into \(resolved.account.name)?"
                try await confirm((notes + [question]).joined(separator: " "), .log)
            } else {
                if draft.amount >= IntentPolicy.largeAmountThreshold {
                    notes.append("That's \(amountText).")
                }
                if !notes.isEmpty {
                    try await confirm((notes + ["Save it?"]).joined(separator: " "), .log)
                }
            }
        case .adjustment:
            // `resolve` refuses adjustments, so they never reach this point.
            break
        }

        let transaction = try IntentLedger.perform {
            try recordEntry(draft, account: resolved.account, in: ledger)
        }
        Log.intents.info("Recorded a \(draft.kind.rawValue, privacy: .public) from an App Intent")
        return transaction
    }

    /// Records the entry. On a pay later account that charges a monthly fee, an expense becomes a
    /// one-month plan with that fee, as it does in the app, and the purchase is returned.
    private static func recordEntry(_ draft: TransactionDraft, account: Account, in ledger: LedgerService) throws -> LedgerTransaction {
        guard
            draft.kind == .expense,
            account.kind == .payLater,
            let rate = account.splitFeeRate,
            let accountID = draft.accountID,
            let categoryID = draft.categoryID
        else {
            return try ledger.record(draft, origin: .appIntent, requestID: UUID())
        }
        let plan = try ledger.recordSplitPurchase(
            SplitPurchase(
                amount: draft.amount,
                accountID: accountID,
                categoryID: categoryID,
                occurredAt: draft.occurredAt,
                note: draft.note,
                months: 1,
                monthly: LedgerService.splitPayment(price: draft.amount, months: 1, feeRate: rate, currency: account.currency),
                last: nil
            ),
            origin: .appIntent
        )
        guard let purchaseID = plan.purchaseID, let purchase = try ledger.transaction(id: purchaseID) else {
            throw LedgerError.transactionNotFound
        }
        return purchase
    }

    private static func savedOutcome(for transaction: LedgerTransaction, in ledger: LedgerService) -> IntentOutcome {
        let formatter = MoneyFormatter.current()
        let summary = TransactionSummary(transaction)
        let kind = summary.kind ?? .expense
        let detail = summary.confirmationLine(formatter: formatter)
        let sheet = try? ledger.balanceSheet()

        var rows = [ResultRow(
            id: transaction.id,
            symbolName: summary.symbolName,
            title: summary.title,
            subtitle: kind == .transfer ? summary.accountLine : "\(kind.title) · \(summary.accountLine)",
            value: summary.signedAmountText(formatter: formatter)
        )]
        var details = [detail]
        // A purchase recorded as a pay later plan shows the fee added with it.
        if let planID = transaction.planID,
           let fees = try? ledger.planEntries(planID: planID).first(where: { $0.origin == .planFees }) {
            let feeSummary = TransactionSummary(fees)
            details.append(feeSummary.confirmationLine(formatter: formatter))
            rows.append(ResultRow(
                id: fees.id,
                symbolName: feeSummary.symbolName,
                title: feeSummary.title,
                subtitle: "\(kind.title) · \(feeSummary.accountLine)",
                value: feeSummary.signedAmountText(formatter: formatter)
            ))
        }
        var balanceLines: [String] = []
        for account in [transaction.account, transaction.destinationAccount].compactMap({ $0 }) {
            guard let balance = sheet?.balance(for: account.id), let current = balance.currentBalance else { continue }
            if account.kind.isOwed, let owed = balance.owed {
                // Money owed reads as what's owed, or as a credit, never as a negative balance.
                let amount = formatter.string(owed.magnitude, alwaysShowCentavos: true)
                let isCredit = owed.isNegative
                balanceLines.append(isCredit ? "\(account.name) has a \(amount) credit" : "You owe \(amount) on \(account.name)")
                rows.append(ResultRow(
                    id: account.id, symbolName: account.kind.systemImage, title: account.name,
                    subtitle: isCredit ? "Credit" : "You owe", value: amount
                ))
            } else {
                let amount = formatter.string(current, alwaysShowCentavos: true)
                balanceLines.append("\(account.name) balance: \(amount)")
                rows.append(ResultRow(id: account.id, symbolName: account.kind.systemImage, title: account.name, subtitle: "New balance", value: amount))
            }
        }
        return IntentOutcome(
            headline: "\(kind.title) saved",
            body: (details + balanceLines).joined(separator: ". "),
            rows: rows
        )
    }

    // MARK: Preconditions

    private static func resolve(_ preset: UUID?, ask: () async throws -> UUID) async throws -> UUID {
        if let preset { return preset }
        return try await ask()
    }

    private static func requireAccounts(_ minimum: Int, in ledger: LedgerService) throws {
        let count = try ledger.accounts().count
        guard count > 0 else { throw LedgerIntentError.noActiveAccounts }
        guard count >= minimum else { throw LedgerIntentError.needsTwoAccounts }
    }

    private static func requireCategories(_ kind: CategoryKind, in ledger: LedgerService) throws {
        guard try !ledger.categories(kind: kind).isEmpty else {
            throw LedgerIntentError.noCategories(kind)
        }
    }
}
