import AppIntents
import Foundation
import SwiftData
import XCTest
@testable import Ledger

private struct UnexpectedPrompt: Error {}
private struct Declined: Error {}

/// The App Intent flows, driven with scripted answers in place of the system's prompts.
@MainActor
final class IntentFlowTests: XCTestCase {
    /// An amount as the number field delivers it.
    private func pesos(_ text: String) -> Double {
        Double(text) ?? .nan
    }

    func testExpenseWithEverySuppliedValueRecordsWithoutPrompting() async throws {
        let h = try LedgerHarness()
        let gcash = try h.account("GCash", opening: 4_230, kind: .eWallet)
        let food = try h.expenseCategory("Food")
        var confirmations: [String] = []

        let outcome = try await IntentFlows.logExpense(
            in: h.ledger,
            amount: pesos("250"),
            category: ExpenseCategoryEntity(food),
            account: AccountEntity(gcash),
            askAmount: { _ in throw UnexpectedPrompt() },
            askCategory: { _ in throw UnexpectedPrompt() },
            askAccount: { _ in throw UnexpectedPrompt() },
            confirm: { message, _ in confirmations.append(message) }
        )

        XCTAssertTrue(confirmations.isEmpty)
        XCTAssertEqual(try h.transactionCount(), 1)
        XCTAssertEqual(try h.balance(gcash), 3_980)
        XCTAssertEqual(outcome.headline, "Expense saved")
        let body = try XCTUnwrap(outcome.body)
        XCTAssertTrue(body.contains("250.00 · Food · GCash. GCash balance: "), body)
        XCTAssertTrue(outcome.text.hasPrefix("Expense saved — "), outcome.text)
        XCTAssertEqual(outcome.rows.map(\.title), ["Food", "GCash"], "The entry, then the account's new balance")
        XCTAssertEqual(outcome.rows[0].subtitle, "Expense · GCash")
        XCTAssertTrue(outcome.rows[0].value?.contains("250") ?? false)
        XCTAssertEqual(outcome.rows[1].subtitle, "New balance")
        XCTAssertEqual(outcome.rows[1].symbolName, AccountKind.eWallet.systemImage)
        XCTAssertFalse(outcome.text.contains("\n"), "Dialogs are a single paragraph")
        XCTAssertEqual(try h.ledger.transactions().first?.origin, .appIntent)
    }

    func testExpensePromptsInOrderForMissingValues() async throws {
        let h = try LedgerHarness()
        let wallet = try h.account("Wallet", opening: 1_000, kind: .cash)
        let jeep = try h.expenseCategory("Jeep")
        var prompts: [String] = []

        _ = try await IntentFlows.logExpense(
            in: h.ledger,
            amount: nil,
            category: nil,
            account: nil,
            askAmount: { prompts.append($0); return self.pesos("13") },
            askCategory: { prompts.append($0); return ExpenseCategoryEntity(jeep) },
            askAccount: { prompts.append($0); return AccountEntity(wallet) },
            confirm: { _, _ in }
        )

        XCTAssertEqual(prompts, ["How much did you spend?", "What was it for?", "Which account did you pay from?"])
        XCTAssertEqual(try h.balance(wallet), 987)
    }

    func testInvalidAmountsAreAskedForAgainWithAReason() async throws {
        let h = try LedgerHarness()
        let gcash = try h.account("GCash", opening: 100, kind: .eWallet)
        let food = try h.expenseCategory("Food")
        var answers = [pesos("0"), pesos("10.555"), pesos("12.50")]
        var prompts: [String] = []

        _ = try await IntentFlows.logExpense(
            in: h.ledger,
            amount: nil,
            category: ExpenseCategoryEntity(food),
            account: AccountEntity(gcash),
            askAmount: { prompts.append($0); return answers.removeFirst() },
            askCategory: { _ in throw UnexpectedPrompt() },
            askAccount: { _ in throw UnexpectedPrompt() },
            confirm: { _, _ in }
        )

        XCTAssertEqual(prompts, [
            "How much did you spend?",
            "Enter an amount greater than zero. How much did you spend?",
            "Amounts can have at most two decimal places. How much did you spend?",
        ])
        XCTAssertEqual(try h.transactionCount(), 1)
        XCTAssertEqual(try h.balance(gcash), dec("87.50"))
    }

    func testAnEmptyAmountFromShortcutsIsAskedForWithoutAnError() async throws {
        let h = try LedgerHarness()
        let gcash = try h.account("GCash", opening: 100, kind: .eWallet)
        let food = try h.expenseCategory("Food")
        var prompts: [String] = []

        _ = try await IntentFlows.logExpense(
            in: h.ledger,
            amount: 0,
            category: ExpenseCategoryEntity(food),
            account: AccountEntity(gcash),
            askAmount: { prompts.append($0); return self.pesos("45") },
            askCategory: { _ in throw UnexpectedPrompt() },
            askAccount: { _ in throw UnexpectedPrompt() },
            confirm: { _, _ in }
        )

        XCTAssertEqual(prompts, ["How much did you spend?"], "The first question carries no error")
        XCTAssertEqual(try h.balance(gcash), 55)
    }

    func testNumberFieldValuesConvertToExactDecimals() throws {
        XCTAssertEqual(try IntentFlows.validatedAmount(19.99), dec("19.99"))
        XCTAssertEqual(try IntentFlows.validatedAmount(0.1), dec("0.10"))
        XCTAssertEqual(try IntentFlows.validatedAmount(1234567.89), dec("1234567.89"))
        XCTAssertEqual(try IntentFlows.validatedAmount(999_999_999_999.99), AmountRules.maximum, "Exact at the limit")
        XCTAssertEqual(try IntentFlows.validatedAmount(0.1 + 0.2), dec("0.30"), "Floating-point noise from a calculation is snapped")
        for invalid in [12.345, 0.001, -5, 0, .nan, .infinity, 1e16] {
            XCTAssertThrowsError(try IntentFlows.validatedAmount(invalid), "\(invalid) should be refused")
        }
    }

    func testCancellingAPromptSavesNothing() async throws {
        let h = try LedgerHarness()
        let gcash = try h.account("GCash", opening: 100, kind: .eWallet)
        try h.expenseCategory("Food")

        do {
            _ = try await IntentFlows.logExpense(
                in: h.ledger,
                amount: pesos("250"),
                category: nil,
                account: AccountEntity(gcash),
                askAmount: { _ in throw UnexpectedPrompt() },
                askCategory: { _ in throw CancellationError() },
                askAccount: { _ in throw UnexpectedPrompt() },
                confirm: { _, _ in }
            )
            XCTFail("Expected cancellation to propagate")
        } catch is CancellationError {
            // Expected.
        }
        XCTAssertEqual(try h.transactionCount(), 0)
        XCTAssertFalse(h.context.hasChanges)
    }

    func testRepeatedEntryAsksBeforeSavingAgain() async throws {
        let h = try LedgerHarness()
        let gcash = try h.account("GCash", opening: 1_000, kind: .eWallet)
        let food = try h.expenseCategory("Food")
        func log(confirm: IntentFlows.Confirm) async throws {
            _ = try await IntentFlows.logExpense(
                in: h.ledger,
                amount: pesos("250"),
                category: ExpenseCategoryEntity(food),
                account: AccountEntity(gcash),
                askAmount: { _ in throw UnexpectedPrompt() },
                askCategory: { _ in throw UnexpectedPrompt() },
                askAccount: { _ in throw UnexpectedPrompt() },
                confirm: confirm
            )
        }

        try await log { _, _ in XCTFail("The first entry needs no confirmation") }
        h.clock.advance(by: 20)

        var messages: [String] = []
        do {
            try await log { message, _ in
                messages.append(message)
                throw Declined()
            }
            XCTFail("Declining must stop the flow")
        } catch is Declined {
            // Expected.
        }
        XCTAssertEqual(try h.transactionCount(), 1, "Declined repeat is not saved")
        XCTAssertEqual(messages.count, 1)
        XCTAssertTrue(messages[0].hasPrefix("You logged"), messages[0])
        XCTAssertTrue(messages[0].hasSuffix("Save it?"), messages[0])

        try await log { _, _ in }
        XCTAssertEqual(try h.transactionCount(), 2, "A confirmed identical purchase is kept")
        XCTAssertEqual(try h.balance(gcash), 500)
    }

    func testLargeAmountsAreConfirmed() async throws {
        let h = try LedgerHarness()
        let pnb = try h.account("PNB", opening: 500_000)
        let bills = try h.expenseCategory("Bills")
        var messages: [String] = []

        _ = try await IntentFlows.logExpense(
            in: h.ledger,
            amount: pesos("150000"),
            category: ExpenseCategoryEntity(bills),
            account: AccountEntity(pnb),
            askAmount: { _ in throw UnexpectedPrompt() },
            askCategory: { _ in throw UnexpectedPrompt() },
            askAccount: { _ in throw UnexpectedPrompt() },
            confirm: { message, _ in messages.append(message) }
        )

        XCTAssertEqual(messages.count, 1)
        XCTAssertTrue(messages[0].hasPrefix("That's"), messages[0])
        XCTAssertTrue(messages[0].contains("150,000.00"), messages[0])
    }

    func testIncomeFlowRecordsIntoTheReceivingAccount() async throws {
        let h = try LedgerHarness()
        let pnb = try h.account("PNB", opening: 12_800)
        let salary = try h.incomeSource("Salary")
        var prompts: [String] = []

        let outcome = try await IntentFlows.logIncome(
            in: h.ledger,
            amount: nil,
            source: nil,
            account: nil,
            askAmount: { prompts.append($0); return self.pesos("25000") },
            askSource: { prompts.append($0); return IncomeSourceEntity(salary) },
            askAccount: { prompts.append($0); return AccountEntity(pnb) },
            confirm: { _, _ in }
        )

        XCTAssertEqual(prompts, ["How much did you receive?", "Where is it from?", "Which account received it?"])
        XCTAssertEqual(try h.balance(pnb), 37_800)
        XCTAssertEqual(outcome.headline, "Income saved")
    }

    func testTransferIsConfirmedAndOffersOnlyOtherAccounts() async throws {
        let h = try LedgerHarness()
        let pnb = try h.account("PNB", opening: 10_000)
        let gcash = try h.account("GCash", opening: 2_000, kind: .eWallet)
        let maya = try h.account("Maya", opening: 0, kind: .eWallet)
        var offered: [UUID] = []
        var messages: [String] = []

        let outcome = try await IntentFlows.transfer(
            in: h.ledger,
            amount: pesos("500"),
            from: AccountEntity(pnb),
            to: AccountEntity(pnb),
            askAmount: { _ in throw UnexpectedPrompt() },
            askSource: { _ in throw UnexpectedPrompt() },
            chooseDestination: { options, _ in
                offered = options.map(\.id)
                return AccountEntity(gcash)
            },
            confirm: { message, _ in messages.append(message) }
        )

        XCTAssertEqual(Set(offered), [gcash.id, maya.id], "The source is never offered as the destination")
        XCTAssertEqual(messages.count, 1)
        XCTAssertTrue(messages[0].hasPrefix("Transfer"), messages[0])
        XCTAssertTrue(messages[0].hasSuffix("from PNB to GCash?"), messages[0])
        XCTAssertEqual(try h.balance(pnb), 9_500)
        XCTAssertEqual(try h.balance(gcash), 2_500)
        XCTAssertEqual(try h.liquidTotal().total.amount, 12_000)
        let body = try XCTUnwrap(outcome.body)
        XCTAssertTrue(body.contains("PNB balance: ") && body.contains("GCash balance: "), "Both accounts' new balances: \(body)")
        XCTAssertEqual(outcome.rows.map(\.title), ["Transfer", "PNB", "GCash"])
        XCTAssertEqual(outcome.rows[0].subtitle, "PNB → GCash")
    }

    func testDecliningATransferSavesNothing() async throws {
        let h = try LedgerHarness()
        let pnb = try h.account("PNB", opening: 10_000)
        let gcash = try h.account("GCash", opening: 2_000, kind: .eWallet)

        do {
            _ = try await IntentFlows.transfer(
                in: h.ledger,
                amount: pesos("500"),
                from: AccountEntity(pnb),
                to: AccountEntity(gcash),
                askAmount: { _ in throw UnexpectedPrompt() },
                askSource: { _ in throw UnexpectedPrompt() },
                chooseDestination: { _, _ in throw UnexpectedPrompt() },
                confirm: { _, _ in throw Declined() }
            )
            XCTFail("Declining must stop the transfer")
        } catch is Declined {
            // Expected.
        }
        XCTAssertEqual(try h.transactionCount(), 0)
        XCTAssertEqual(try h.balance(pnb), 10_000)
    }

    // MARK: Update Balance

    func testUpdateBalanceAsksAccountThenBalanceAndConfirms() async throws {
        let h = try LedgerHarness()
        let gcash = try h.account("GCash", opening: 117, kind: .eWallet)
        var prompts: [String] = []
        var confirmations: [String] = []

        let outcome = try await IntentFlows.updateBalance(
            in: h.ledger,
            account: nil,
            amount: nil,
            askAccount: { prompts.append($0); return AccountEntity(gcash) },
            askAmount: { prompts.append($0); return self.pesos("121") },
            confirm: { message, _ in confirmations.append(message) }
        )

        XCTAssertEqual(prompts, ["Which account do you want to update?", "What's GCash's real balance?"])
        XCTAssertEqual(confirmations.count, 1)
        let confirmation = plainSpaces(confirmations[0])
        XCTAssertTrue(confirmation.hasPrefix("Add a +₱4.00 balance adjustment to GCash?"), confirmation)
        XCTAssertEqual(try h.balance(gcash), 121)
        XCTAssertEqual(try h.ledger.transactions().first?.origin, .appIntent)
        XCTAssertEqual(outcome.headline, "Balance updated")
        XCTAssertEqual(outcome.rows.map(\.title), ["Balance adjustment", "GCash"])
        XCTAssertEqual(outcome.rows[0].subtitle, "Adjustment · GCash")
        XCTAssertEqual(outcome.rows[0].symbolName, TransactionKind.adjustment.systemImage)
        XCTAssertEqual(outcome.rows[1].subtitle, "New balance")
        XCTAssertTrue(plainSpaces(outcome.rows[0].value ?? "").contains("+₱4"))
        let body = plainSpaces(try XCTUnwrap(outcome.body))
        XCTAssertTrue(body.contains("Balance adjustment · GCash. GCash balance: ₱121"), body)
        XCTAssertFalse(outcome.text.contains("\n"))
    }

    func testUpdateBalanceThatMatchesSavesNothing() async throws {
        let h = try LedgerHarness()
        let gcash = try h.account("GCash", opening: 117, kind: .eWallet)

        let outcome = try await IntentFlows.updateBalance(
            in: h.ledger,
            account: AccountEntity(gcash),
            amount: pesos("117"),
            askAccount: { _ in throw UnexpectedPrompt() },
            askAmount: { _ in throw UnexpectedPrompt() },
            confirm: { _, _ in throw UnexpectedPrompt() }
        )

        XCTAssertEqual(outcome.headline, "GCash already matches")
        XCTAssertEqual(outcome.rows.map(\.title), ["GCash"])
        XCTAssertEqual(try h.transactionCount(), 0)
    }

    func testUpdateBalanceSetsAMissingOpeningBalance() async throws {
        let h = try LedgerHarness()
        let gcash = try h.account("GCash", opening: nil, kind: .eWallet)
        var confirmations: [String] = []

        let outcome = try await IntentFlows.updateBalance(
            in: h.ledger,
            account: AccountEntity(gcash),
            amount: pesos("121"),
            askAccount: { _ in throw UnexpectedPrompt() },
            askAmount: { _ in throw UnexpectedPrompt() },
            confirm: { message, _ in confirmations.append(message) }
        )

        XCTAssertEqual(confirmations.map(plainSpaces), ["Set GCash's opening balance so its balance is ₱121.00?"])
        XCTAssertEqual(gcash.openingBalanceMinor, 12_100)
        XCTAssertEqual(try h.transactionCount(), 0)
        XCTAssertEqual(outcome.headline, "Balance updated")
        XCTAssertEqual(outcome.rows.map(\.title), ["GCash"])
    }

    func testDecliningAnUpdateSavesNothing() async throws {
        let h = try LedgerHarness()
        let gcash = try h.account("GCash", opening: 117, kind: .eWallet)

        do {
            _ = try await IntentFlows.updateBalance(
                in: h.ledger,
                account: AccountEntity(gcash),
                amount: pesos("121"),
                askAccount: { _ in throw UnexpectedPrompt() },
                askAmount: { _ in throw UnexpectedPrompt() },
                confirm: { _, _ in throw Declined() }
            )
            XCTFail("Declining must stop the update")
        } catch is Declined {
            // Expected.
        }
        XCTAssertEqual(try h.transactionCount(), 0)
        XCTAssertEqual(try h.balance(gcash), 117)
    }

    func testUpdateBalanceAsksAgainForAnEmptyAmount() async throws {
        let h = try LedgerHarness()
        let gcash = try h.account("GCash", opening: 117, kind: .eWallet)
        var prompts: [String] = []

        _ = try await IntentFlows.updateBalance(
            in: h.ledger,
            account: AccountEntity(gcash),
            amount: 0,
            askAccount: { _ in throw UnexpectedPrompt() },
            askAmount: { prompts.append($0); return self.pesos("110") },
            confirm: { _, _ in }
        )

        XCTAssertEqual(prompts, ["What's GCash's real balance?"], "The first question carries no error")
        XCTAssertEqual(try h.balance(gcash), 110)
    }

    // MARK: Owed accounts

    private func owedHarness() throws -> (LedgerHarness, Account) {
        let h = try LedgerHarness(calendar: try fixedCalendar("Asia/Manila"))
        let card = try h.ledger.createOwedAccount(
            name: "Visa card", kind: .creditCard, terms: OwedTerms(statementDay: 5, dueDay: 25), owedNow: 2_000, stillDue: 0
        )
        return (h, card)
    }

    func testUpdateWhatYouOweAsksAndConfirms() async throws {
        let (h, card) = try owedHarness()
        var prompts: [String] = []
        var confirmations: [String] = []

        let outcome = try await IntentFlows.updateBalance(
            in: h.ledger,
            account: nil,
            amount: nil,
            askAccount: { prompts.append($0); return AccountEntity(card) },
            askAmount: { prompts.append($0); return self.pesos("2150") },
            confirm: { message, _ in confirmations.append(message) }
        )

        XCTAssertEqual(prompts, ["Which account do you want to update?", "What do you owe on Visa card?"])
        XCTAssertEqual(confirmations.count, 1)
        XCTAssertTrue(plainSpaces(confirmations[0]).hasPrefix("Change what you owe on Visa card to ₱2,150.00?"), confirmations[0])
        XCTAssertEqual(try h.ledger.balance(of: card)?.owed?.amount, 2_150)
        XCTAssertEqual(try h.ledger.transactions().first?.origin, .appIntent)
        XCTAssertEqual(outcome.headline, "Updated what you owe")
        XCTAssertEqual(outcome.rows.map(\.title), ["Visa card"])
        XCTAssertEqual(outcome.rows[0].subtitle, "You owe")
        XCTAssertTrue(plainSpaces(outcome.rows[0].value ?? "").contains("2,150"))
        XCTAssertFalse(outcome.text.contains("\n"))
    }

    func testUpdateWhatYouOweTreatsZeroAsNotSupplied() async throws {
        let (h, card) = try owedHarness()
        var prompts: [String] = []

        _ = try await IntentFlows.updateBalance(
            in: h.ledger,
            account: AccountEntity(card),
            amount: 0,
            askAccount: { _ in throw UnexpectedPrompt() },
            askAmount: { prompts.append($0); return self.pesos("1900") },
            confirm: { _, _ in }
        )

        XCTAssertEqual(prompts, ["What do you owe on Visa card?"])
        XCTAssertEqual(try h.ledger.balance(of: card)?.owed?.amount, 1_900)
    }

    func testCheckBalancesListsMoneyAccountsThenOwedAndNextDue() throws {
        let h = try LedgerHarness(calendar: try fixedCalendar("Asia/Manila"))
        try h.account("Bank", opening: 10_000)
        try h.ledger.createOwedAccount(
            name: "Visa card", kind: .creditCard, terms: OwedTerms(statementDay: 5, dueDay: 25), owedNow: 2_500, stillDue: 2_500
        )
        let before = try h.transactionCount()

        let outcome = try IntentFlows.balances(in: h.ledger)

        XCTAssertEqual(outcome.rows.map(\.title), ["Bank", "You owe", "Next due"])
        XCTAssertTrue(plainSpaces(outcome.rows[1].value ?? "").contains("2,500"))
        XCTAssertTrue((outcome.rows[2].subtitle ?? "").hasPrefix("Visa card · "), outcome.rows[2].subtitle ?? "")
        XCTAssertTrue(plainSpaces(outcome.headline).contains("10,000"), outcome.headline)
        XCTAssertFalse(plainSpaces(outcome.headline).contains("7,500"), "The total excludes money owed")
        let body = plainSpaces(try XCTUnwrap(outcome.body))
        XCTAssertTrue(body.contains("You owe ₱2,500"), body)
        XCTAssertEqual(try h.transactionCount(), before)
        XCTAssertFalse(h.context.hasChanges)
    }

    func testUpdateBalanceRefusesAnArchivedAccount() async throws {
        let h = try LedgerHarness()
        let gcash = try h.account("GCash", opening: 117, kind: .eWallet)
        try h.account("PNB", opening: 1_000)
        try h.ledger.archiveAccount(gcash)

        do {
            _ = try await IntentFlows.updateBalance(
                in: h.ledger,
                account: AccountEntity(gcash),
                amount: pesos("121"),
                askAccount: { _ in throw UnexpectedPrompt() },
                askAmount: { _ in throw UnexpectedPrompt() },
                confirm: { _, _ in throw UnexpectedPrompt() }
            )
            XCTFail("An archived account can't be updated")
        } catch let error as LedgerIntentError {
            XCTAssertEqual(error, .ledger(.accountArchived(name: "GCash")))
        }
        XCTAssertEqual(try h.transactionCount(), 0)
    }

    func testMenuOffersUpdateBalance() {
        XCTAssertEqual(LedgerAction.allCases.last, .updateBalance)
        XCTAssertNotNil(LedgerAction.caseDisplayRepresentations[.updateBalance])
    }

    func testFlowsExplainMissingSetup() async throws {
        let h = try LedgerHarness()
        let only = try h.account("Wallet", opening: 100, kind: .cash)

        do {
            _ = try await IntentFlows.logExpense(
                in: h.ledger, amount: nil, category: nil, account: nil,
                askAmount: { _ in throw UnexpectedPrompt() },
                askCategory: { _ in throw UnexpectedPrompt() },
                askAccount: { _ in throw UnexpectedPrompt() },
                confirm: { _, _ in }
            )
            XCTFail("Expected an error")
        } catch let error as LedgerIntentError {
            XCTAssertEqual(error, .noCategories(.expense))
        }

        do {
            _ = try await IntentFlows.transfer(
                in: h.ledger, amount: nil, from: AccountEntity(only), to: nil,
                askAmount: { _ in throw UnexpectedPrompt() },
                askSource: { _ in throw UnexpectedPrompt() },
                chooseDestination: { _, _ in throw UnexpectedPrompt() },
                confirm: { _, _ in }
            )
            XCTFail("Expected an error")
        } catch let error as LedgerIntentError {
            XCTAssertEqual(error, .needsTwoAccounts)
        }
    }

    func testCheckingBalancesChangesNothing() throws {
        let h = try LedgerHarness()
        try h.account("GCash", opening: 4_230, kind: .eWallet)
        try h.account("Maya", opening: nil, kind: .eWallet)
        let before = try h.transactionCount()

        let outcome = try IntentFlows.balances(in: h.ledger)

        XCTAssertEqual(try h.transactionCount(), before)
        XCTAssertFalse(h.context.hasChanges)
        XCTAssertTrue(outcome.headline.hasPrefix("Total liquid:"), outcome.headline)
        XCTAssertEqual(outcome.rows.map(\.title), ["GCash", "Maya"], "Balances are shown as rows")
        XCTAssertEqual(outcome.rows[0].subtitle, "E-wallet")
        XCTAssertNotNil(outcome.rows[0].value)
        XCTAssertNil(outcome.rows[1].value, "An unset opening balance has no amount in its row")
        XCTAssertEqual(outcome.note, "Excludes Maya until its opening balance is set.")
        let body = try XCTUnwrap(outcome.body, "The full text is still spoken")
        XCTAssertTrue(body.hasPrefix("GCash "), body)
        XCTAssertTrue(body.contains(" · Maya Not Set"), "An unset opening balance is shown as not set, not as zero: \(body)")
        XCTAssertTrue(body.hasSuffix("Excludes Maya until its opening balance is set."), "The total explains what it leaves out: \(body)")
    }

    func testBalancesWithoutAnyOpeningBalanceShowNoTotal() throws {
        let h = try LedgerHarness()
        try h.account("GCash", opening: nil, kind: .eWallet)

        let outcome = try IntentFlows.balances(in: h.ledger)

        XCTAssertEqual(outcome.headline, "Opening balances aren't set yet", "No total is invented when nothing is known")
        XCTAssertEqual(outcome.text, "Opening balances aren't set yet. Set the opening balance of GCash to see your total.")
        XCTAssertEqual(outcome.rows.map(\.title), ["GCash"], "Each account is still listed")
        XCTAssertNil(outcome.rows[0].value, "An unset opening balance is listed as not set, never as zero")
        XCTAssertEqual(outcome.note, "Set the opening balance of GCash to see your total.")
    }

    func testBalancesWithoutActiveAccountsExplainWhatToDo() throws {
        let h = try LedgerHarness()
        XCTAssertThrowsError(try IntentFlows.balances(in: h.ledger)) { error in
            XCTAssertEqual(error as? LedgerIntentError, .noActiveAccounts)
        }
    }
}
