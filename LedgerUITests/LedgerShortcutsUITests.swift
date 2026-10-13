import Foundation
import XCTest

/// Ledger's App Shortcuts and intents, run end to end through the Shortcuts app, the system's
/// prompt cards, and Spotlight. Run with the LedgerShortcutsUITests scheme on a simulator.
///
/// Steps that need the system to resolve a category or account, or to start an App Shortcut,
/// are skipped with an explanation when the build has no development team (see
/// `SystemUITestCase.reportFailedRun`).
final class LedgerShortcutsUITests: SystemUITestCase {
    // MARK: Registration

    func test01_AppShortcutsAppearInShortcutsApp() throws {
        shortcuts.launch()
        let section = try require(shortcuts.buttons["Ledger"].firstMatch, "the Ledger section in All Shortcuts")
        for title in ["Ledger Menu", "Log Expense", "Log Income", "Transfer Money"] {
            try require(shortcuts.otherElements[title].firstMatch, "the \(title) tile in All Shortcuts", timeout: 5)
        }
        attachScreenshot("Registration — Ledger's App Shortcuts in All Shortcuts")

        section.tap()
        for title in Self.actionTitles {
            let tile = shortcuts.descendants(matching: .any).matching(NSPredicate(format: "label == %@", title)).firstMatch
            try require(tile, "the \(title) App Shortcut on Ledger's page", timeout: 10)
        }
        attachScreenshot("Registration — Ledger's page lists all five App Shortcuts")
    }

    func test02_LogExpenseFromAppShortcutTile() throws {
        let countBefore = try LedgerStoreProbe().transactionCount()
        shortcuts.launch()
        try require(shortcuts.otherElements["Log Expense"].firstMatch, "the Log Expense App Shortcut tile").tap()
        lastStep = "tapping the Log Expense App Shortcut tile"
        try completeLogExpense(
            "App Shortcut tile", amount: "120", amountText: "₱120.00", minorUnits: 12_000,
            category: "Transport", account: "Wallet", countBefore: countBefore
        )
    }

    // MARK: Flows

    func test03_CheckBalances() throws {
        let countBefore = try LedgerStoreProbe().transactionCount()
        try runActionInNewShortcut("Check Balances")
        let unset = "Opening balances aren't set yet"
        let headline = cards.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@ OR label BEGINSWITH 'Total liquid: '", unset)).firstMatch
        try require(headline, "the Check Balances result", timeout: 25)
        Thread.sleep(forTimeInterval: 1)
        attachScreenshot("Check Balances — result")

        // The list's header shows the total and its rows name each account; read every label the
        // card shows.
        let text = cards.descendants(matching: .any).allElementsBoundByIndex.map(\.label).joined(separator: "\n")
        let isUnset = text.contains(unset)
        for name in ["GCash", "GoTyme", "Maya", "PNB", "Wallet"] {
            XCTAssertTrue(text.contains(name), "The result doesn't mention \(name): \(text)")
        }
        if isUnset {
            XCTAssertFalse(text.contains("₱"), "An amount was shown without opening balances: \(text)")
            XCTAssertTrue(text.contains("opening balances of"), "No note explains the missing total: \(text)")
        }
        // Choosing a row closes the list.
        try choose("GCash")
        try waitForRunToEnd()
        XCTAssertEqual(try LedgerStoreProbe().transactionCount(), countBefore, "Checking balances changed the ledger")
    }

    func test04_LogExpense() throws {
        let countBefore = try LedgerStoreProbe().transactionCount()
        try runActionInNewShortcut("Log Expense")
        try completeLogExpense(
            "Log Expense", amount: "250", amountText: "₱250.00", minorUnits: 25_000,
            category: "Food", account: "GCash", countBefore: countBefore
        )
    }

    func test05_TransferMoney() throws {
        let countBefore = try LedgerStoreProbe().transactionCount()
        try runActionInNewShortcut("Transfer Money")
        try waitForCard("How much are you transferring?", screenshot: "Transfer — 1 amount prompt")
        let transferEntry = try enterAmount("500", screenshot: "Transfer — 2 amount typed")
        XCTAssertTrue(transferEntry.openedWithDecimalPad, "The amount field didn't open focused with the decimal pad")
        recordTaps(transferEntry, amount: "₱500", flow: "Transfer")
        try waitForCard("Transfer from which account?", screenshot: "Transfer — 3 source account prompt")
        try choose("PNB")
        try waitForCard("Transfer to which account?", screenshot: "Transfer — 4 destination account prompt")
        XCTAssertFalse(cards.staticTexts["PNB"].exists, "The source account was offered as the destination")
        try choose("GCash")
        try waitForCard("Transfer ₱500.00 from PNB to GCash?", screenshot: "Transfer — 5 confirmation")
        try require(cards.buttons["Continue"].firstMatch, "the confirmation's Continue button").tap()
        try waitForCard("Transfer saved", screenshot: "Transfer — 6 result")
        try require(cardText(containing: "₱500.00 · PNB → GCash"), "the saved transfer in the result list")
        try choose("Transfer")

        let store = try LedgerStoreProbe()
        XCTAssertEqual(try store.transactionCount(), countBefore + 1)
        XCTAssertEqual(try store.newestEntry(), .init(
            kind: "transfer", amountMinor: 50_000, category: nil, account: "PNB", destination: "GCash", origin: "appIntent"
        ))
        try verifyActivityRow(startingWith: "Transfer, ₱500.00, PNB to GCash", screenshot: "Transfer — 7 row in Activity")
    }

    func test06_LedgerMenuThenExpense() throws {
        let countBefore = try LedgerStoreProbe().transactionCount()
        try runActionInNewShortcut("Ledger Menu")
        try waitForCard("What would you like to do?", screenshot: "Ledger Menu — 1 action prompt")
        for option in ["Expense", "Income", "Transfer", "Check Balances"] {
            try require(cards.staticTexts[option].firstMatch, "the \(option) option", timeout: 5)
        }
        try choose("Expense")
        try completeLogExpense(
            "Ledger Menu → Expense", amount: "85", amountText: "₱85.00", minorUnits: 8_500,
            category: "Food", account: "Maya", countBefore: countBefore
        )
    }

    func test07_CancellingAtCategoryPromptRecordsNothing() throws {
        let countBefore = try LedgerStoreProbe().transactionCount()
        try runActionInNewShortcut("Log Expense")
        try waitForCard("How much did you spend?", screenshot: "Cancel — 1 amount prompt")
        let cancelEntry = try enterAmount("75", screenshot: "Cancel — 2 amount typed")
        XCTAssertTrue(cancelEntry.openedWithDecimalPad, "The amount field didn't open focused with the decimal pad")
        try waitForCard("What was it for?", screenshot: "Cancel — 3 category prompt")
        tapOutsideCard()
        try waitForRunToEnd()
        Thread.sleep(forTimeInterval: 1)
        attachScreenshot("Cancel — 4 run ended after tapping outside the card")
        XCTAssertFalse(cards.staticTexts["What was it for?"].exists, "The category prompt is still showing")
        XCTAssertFalse(
            shortcuts.staticTexts.matching(NSPredicate(format: "label CONTAINS 'could not run'")).firstMatch.exists,
            "Cancelling showed an error"
        )
        XCTAssertEqual(try LedgerStoreProbe().transactionCount(), countBefore, "Cancelling recorded a transaction")
        try verifyNoActivityRow(startingWith: "Expense, ₱75.00", screenshot: "Cancel — 5 Activity has no ₱75.00 expense")
    }

    func test08_AmountPromptKeepsCentavosExact() throws {
        let countBefore = try LedgerStoreProbe().transactionCount()
        try runActionInNewShortcut("Log Expense")
        try waitForCard("How much did you spend?", screenshot: "Precision — 1 amount prompt")
        let firstEntry = try enterAmount("12.345", screenshot: "Precision — 2 typed 12.345")
        XCTAssertTrue(firstEntry.openedWithDecimalPad, "The amount field didn't open focused with the decimal pad")
        try waitForCard(
            "Amounts can have at most two decimal places. How much did you spend?",
            screenshot: "Precision — 3 asked again for 12.345"
        )
        let retryEntry = try enterAmount("19.99", screenshot: "Precision — 4 typed 19.99")
        recordTaps(retryEntry, amount: "19.99 after the re-ask", flow: "Precision")
        try waitForCard("What was it for?", screenshot: "Precision — 5 accepted 19.99")
        tapOutsideCard()
        try waitForRunToEnd()

        try require(shortcuts.buttons["play"].firstMatch, "the editor's run button").tap()
        try waitForCard("How much did you spend?", screenshot: "Precision — 6 amount prompt again")
        let secondRunEntry = try enterAmount("0.10", screenshot: "Precision — 7 typed 0.10")
        XCTAssertTrue(secondRunEntry.openedWithDecimalPad, "The amount field didn't open focused with the decimal pad")
        try waitForCard("What was it for?", screenshot: "Precision — 8 accepted 0.10")
        tapOutsideCard()
        try waitForRunToEnd()
        XCTAssertEqual(try LedgerStoreProbe().transactionCount(), countBefore)
    }

    func test09_LogExpenseFromSpotlight() throws {
        let countBefore = try LedgerStoreProbe().transactionCount()
        XCUIDevice.shared.press(.home)
        let searchButton = springboard.buttons["Search"].firstMatch
        if searchButton.waitForExistence(timeout: 5) { searchButton.tap() } else { springboard.swipeDown() }
        let field = try require(spotlight.textFields["SpotlightSearchField"].firstMatch, "Spotlight's search field")
        field.typeText("Log Expense")
        // App results only: web suggestions and web results also match the query text.
        let appResult = NSPredicate(format: """
            label CONTAINS 'Log Expense' AND NOT (identifier CONTAINS 'PunchOut') \
            AND NOT (identifier BEGINSWITH 'Identifier:ResultCell')
            """)
        let result = spotlight.cells.matching(appResult).firstMatch
        try require(result, "Ledger's Log Expense App Shortcut in Spotlight")
        Thread.sleep(forTimeInterval: 1)
        attachScreenshot("Spotlight — results for “Log Expense”")
        recordHierarchies(because: "Spotlight results")
        let title = result.staticTexts["Log Expense"].firstMatch
        (title.exists ? title : result).tap()
        lastStep = "tapping the App Shortcut in Spotlight"
        do {
            try waitForCard("How much did you spend?", screenshot: "Spotlight — amount prompt", alsoWatching: [spotlight, springboard])
        } catch let error as FlowError where LedgerInstallation.signingTeam() == .none {
            // Spotlight starts App Shortcuts through the same lookup as the Shortcuts app's tiles;
            // when the system refuses it, Spotlight's runner ends without showing an error.
            throw XCTSkip("""
                Not verifiable with this build. No prompt appeared after tapping Ledger's Log Expense App Shortcut in \
                Spotlight (\(error.description)). Ledger is signed to run locally without a development team, so the \
                system can't fetch App Shortcut actions and Spotlight's runner ends silently.
                """)
        }
        try completeLogExpense(
            "Spotlight", amount: "45", amountText: "₱45.00", minorUnits: 4_500,
            category: "Food", account: "GCash", countBefore: countBefore, alsoWatching: [spotlight, springboard]
        )
    }

    // MARK: Helpers

    /// Answers the Log Expense prompts, then checks the result list, the store, and Activity.
    private func completeLogExpense(
        _ name: String, amount: String, amountText: String, minorUnits: Int64,
        category: String, account: String, countBefore: Int, alsoWatching: [XCUIApplication] = []
    ) throws {
        try waitForCard("How much did you spend?", screenshot: "\(name) — amount prompt", alsoWatching: alsoWatching)
        let entry = try enterAmount(amount, screenshot: "\(name) — amount typed")
        XCTAssertTrue(entry.openedWithDecimalPad, "The amount field didn't open focused with the decimal pad")
        recordTaps(entry, amount: amountText, flow: name)
        try waitForCard("What was it for?", screenshot: "\(name) — category prompt", alsoWatching: alsoWatching)
        try choose(category)
        try waitForCard("Which account did you pay from?", screenshot: "\(name) — account prompt", alsoWatching: alsoWatching)
        try choose(account)
        try waitForCard("Expense saved", screenshot: "\(name) — result", alsoWatching: alsoWatching)
        try require(cardText(containing: "\(amountText) · Expense · \(account)"), "the saved expense in the result list")
        try choose(category)

        let store = try LedgerStoreProbe()
        XCTAssertEqual(try store.transactionCount(), countBefore + 1)
        XCTAssertEqual(try store.newestEntry(), .init(
            kind: "expense", amountMinor: minorUnits, category: category, account: account, destination: nil, origin: "appIntent"
        ))
        try verifyActivityRow(
            startingWith: "Expense, \(amountText), \(category), \(account)",
            screenshot: "\(name) — row in Activity"
        )
    }

    /// Any element of the visible card whose label contains `text`.
    private func cardText(containing text: String) -> XCUIElement {
        cards.descendants(matching: .any).matching(NSPredicate(format: "label CONTAINS %@", text)).firstMatch
    }
}
