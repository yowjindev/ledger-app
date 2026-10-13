import Foundation
import XCTest

/// Drives Ledger's App Intents through the real system UI: the Shortcuts app, the prompt and
/// result cards that ShortcutsUI shows over SpringBoard, and Spotlight.
///
/// Intents run in the background against Ledger's on-disk store (the system launches the app
/// without test launch arguments), so these tests read that store to confirm what was saved.
@MainActor
class SystemUITestCase: XCTestCase {
    let ledger = XCUIApplication()
    let shortcuts = XCUIApplication(bundleIdentifier: "com.apple.shortcuts")
    /// Hosts the prompt and result cards while a shortcut runs.
    let cards = XCUIApplication(bundleIdentifier: "com.apple.ShortcutsUI")
    let springboard = XCUIApplication(bundleIdentifier: "com.apple.springboard")
    let spotlight = XCUIApplication(bundleIdentifier: "com.apple.Spotlight")

    /// Titles of Ledger's App Shortcuts. User shortcuts the tests create are named after them.
    static let actionTitles = ["Ledger Menu", "Log Expense", "Log Income", "Transfer Money", "Check Balances"]

    struct FlowError: Error, CustomStringConvertible {
        let description: String
    }

    private static var ledgerHasLaunched = false

    /// The last step reached, reported when a run fails.
    var lastStep = "start"

    override func setUp() async throws {
        try await super.setUp()
        continueAfterFailure = false
        if !Self.ledgerHasLaunched {
            launchLedgerOnce()
            Self.ledgerHasLaunched = true
        }
        ledger.terminate()
        shortcuts.terminate()
    }

    override func tearDown() async throws {
        dismissVisibleCard()
        removeCreatedShortcuts()
        shortcuts.terminate()
        try await super.tearDown()
    }

    // MARK: Evidence

    /// Attaches a screenshot of the whole screen to the test results.
    func attachScreenshot(_ name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Prints the element hierarchies of the apps involved and attaches them to the results.
    func recordHierarchies(because reason: String) {
        let apps = [("ShortcutsUI", cards), ("Shortcuts", shortcuts), ("Spotlight", spotlight), ("Ledger", ledger)]
        for (name, app) in apps where app.state == .runningForeground || app.state == .runningBackground {
            let hierarchy = app.debugDescription
            print("\(reason) — \(name) hierarchy:\n\(hierarchy)")
            let attachment = XCTAttachment(string: hierarchy)
            attachment.name = "\(reason) — \(name) hierarchy"
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    /// Waits for an element; on timeout records the hierarchies and throws.
    @discardableResult
    func require(_ element: XCUIElement, _ description: String, timeout: TimeInterval = 15) throws -> XCUIElement {
        if element.waitForExistence(timeout: timeout) { return element }
        recordHierarchies(because: "Missing \(description)")
        throw FlowError(description: "Timed out after \(Int(timeout)) s waiting for \(description)")
    }

    // MARK: Ledger

    /// Launches Ledger once so it seeds its store and the system registers its App Shortcuts.
    private func launchLedgerOnce() {
        ledger.launchArguments = ["-LedgerSkipOnboarding", "YES"]
        ledger.launch()
        XCTAssertTrue(ledger.tabBars.firstMatch.waitForExistence(timeout: 20), "Ledger didn't show its tabs")
        attachScreenshot("Ledger launched once to seed its store")
        ledger.terminate()
    }

    /// Relaunches Ledger on the Activity tab and waits for a row whose label starts with `prefix`.
    func verifyActivityRow(startingWith prefix: String, screenshot: String) throws {
        lastStep = "looking for “\(prefix)…” in Activity"
        ledger.terminate()
        ledger.launchArguments = ["-LedgerSkipOnboarding", "YES", "-LedgerInitialTab", "transactions"]
        ledger.launch()
        let row = ledger.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
        try require(row, "the Activity row “\(prefix)…”")
        attachScreenshot(screenshot)
        ledger.terminate()
    }

    /// Relaunches Ledger on the Activity tab and checks that no row starts with `prefix`.
    func verifyNoActivityRow(startingWith prefix: String, screenshot: String) throws {
        ledger.terminate()
        ledger.launchArguments = ["-LedgerSkipOnboarding", "YES", "-LedgerInitialTab", "transactions"]
        ledger.launch()
        try require(ledger.navigationBars["Activity"].firstMatch, "Ledger's Activity tab")
        let row = ledger.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
        XCTAssertFalse(row.waitForExistence(timeout: 2), "Unexpected Activity row “\(row.label)”")
        attachScreenshot(screenshot)
        ledger.terminate()
    }

    // MARK: Shortcuts

    /// Creates a user shortcut containing one of Ledger's actions and runs it from the editor.
    ///
    /// Shortcuts occasionally crashes while it prepares a newly added action, so the steps are
    /// tried a second time when the app is gone.
    func runActionInNewShortcut(_ action: String) throws {
        for attempt in 1...2 {
            lastStep = "adding the \(action) action to a new shortcut"
            shortcuts.terminate()
            shortcuts.launch()
            do {
                try require(shortcuts.buttons["Create Shortcut"].firstMatch, "Shortcuts' Create Shortcut button").tap()
                let search = try require(shortcuts.searchFields["Search Actions"].firstMatch, "the action search field")
                search.tap()
                search.typeText(action)
                let keyboardTip = shortcuts.buttons["Continue"].firstMatch
                if keyboardTip.waitForExistence(timeout: 2) { keyboardTip.tap() }
                try require(shortcuts.cells[action].firstMatch, "the \(action) action in the search results").tap()
                try require(shortcuts.buttons["play"].firstMatch, "the editor's run button").tap()
                lastStep = "running a shortcut with the \(action) action"
                return
            } catch where attempt == 1 && shortcuts.state != .runningForeground {
                attachScreenshot("Shortcuts quit while adding \(action); trying again")
            }
        }
    }

    /// Waits until the shortcut running in the editor has finished.
    func waitForRunToEnd(timeout: TimeInterval = 10) throws {
        let stop = shortcuts.buttons["Stop"].firstMatch
        let ended = XCTNSPredicateExpectation(predicate: NSPredicate(format: "exists == false"), object: stop)
        guard XCTWaiter().wait(for: [ended], timeout: timeout) == .completed else {
            recordHierarchies(because: "Run still active")
            throw FlowError(description: "The shortcut was still running after \(Int(timeout)) s")
        }
    }

    /// Deletes the user shortcuts named after Ledger's actions, which these tests create.
    func removeCreatedShortcuts() {
        let created = NSCompoundPredicate(orPredicateWithSubpredicates: Self.actionTitles.map {
            NSPredicate(format: "label BEGINSWITH %@", $0)
        })
        shortcuts.terminate()
        shortcuts.launch()
        let edit = shortcuts.buttons["Edit"].firstMatch
        guard edit.waitForExistence(timeout: 10), shortcuts.buttons.matching(created).count > 0 else { return }
        edit.tap()
        for tile in shortcuts.buttons.matching(created).allElementsBoundByIndex where tile.isHittable {
            tile.tap()
        }
        let delete = shortcuts.buttons["Delete"].firstMatch
        if delete.waitForExistence(timeout: 5), delete.isEnabled {
            delete.tap()
            let confirm = shortcuts.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Delete '")).firstMatch
            if confirm.waitForExistence(timeout: 5) { confirm.tap() }
        }
        let done = shortcuts.buttons["library.button.done"].firstMatch
        if done.waitForExistence(timeout: 3) { done.tap() }
    }

    // MARK: Cards

    /// Waits for a prompt or result card containing exactly `text`, and screenshots it.
    ///
    /// Stops early when the system reports that the action couldn't run.
    @discardableResult
    func waitForCard(_ text: String, screenshot: String, timeout: TimeInterval = 20, alsoWatching: [XCUIApplication] = []) throws -> XCUIElement {
        // Results are system dialog text, so the card's label starts with this line.
        let label = cards.staticTexts.matching(NSPredicate(format: "label BEGINSWITH %@", text)).firstMatch
        let deadline = Date.now.addingTimeInterval(timeout)
        repeat {
            if label.exists {
                // Lets the card finish animating in before the screenshot.
                Thread.sleep(forTimeInterval: 1)
                attachScreenshot(screenshot)
                lastStep = "card “\(text)”"
                return label
            }
            try checkForRunFailure(in: [shortcuts] + alsoWatching)
            Thread.sleep(forTimeInterval: 0.5)
        } while Date.now < deadline
        attachScreenshot("\(screenshot) (not shown)")
        recordHierarchies(because: "Missing card “\(text)”")
        throw FlowError(description: "The card “\(text)” didn't appear within \(Int(timeout)) s after \(lastStep)")
    }

    /// How an amount was entered on the amount card.
    struct AmountEntry {
        /// Whether the field was focused with the decimal pad showing before any tap.
        let openedWithDecimalPad: Bool
        /// Taps made on the card, including Done.
        let taps: Int
    }

    /// Types an amount into the amount card's number field, key by key, and taps Done.
    ///
    /// The field normally opens focused with the decimal pad; it is tapped only when it isn't.
    /// A previous entry left in the field is cleared first, with the field's clear button when
    /// it has one.
    @discardableResult
    func enterAmount(_ digits: String, screenshot: String) throws -> AmountEntry {
        let field = try require(cards.textFields.firstMatch, "the amount field")
        let keyboard = cards.keyboards.firstMatch
        var taps = 0
        let openedWithDecimalPad = keyboard.waitForExistence(timeout: 3)
        if !openedWithDecimalPad {
            field.tap()
            taps += 1
            try require(keyboard, "the decimal pad", timeout: 5)
        }
        XCTAssertTrue(keyboard.keys["."].exists && keyboard.keys["0"].exists, "The amount keyboard isn't a decimal pad")
        XCTAssertFalse(keyboard.keys["a"].exists, "The amount keyboard has letter keys")

        // An empty field reports its placeholder as its value.
        let value = field.value as? String ?? ""
        let previousEntry = value == field.placeholderValue ? "" : value
        // The field's clear button sits beside it and is labelled "Close".
        let clearButton = cards.buttons.matching(NSPredicate(format: "label == 'Close'")).allElementsBoundByIndex.first {
            $0.frame.midY > field.frame.minY && $0.frame.midY < field.frame.maxY
        }
        if !previousEntry.isEmpty, let clearButton {
            clearButton.tap()
            taps += 1
        } else {
            for _ in 0..<previousEntry.count {
                keyboard.keys["Delete"].tap()
                taps += 1
            }
        }
        for character in digits {
            keyboard.keys[String(character)].tap()
            taps += 1
        }
        attachScreenshot(screenshot)
        try require(cards.buttons["Done"].firstMatch, "the amount card's Done button").tap()
        taps += 1
        lastStep = "entering \(digits)"
        return AmountEntry(openedWithDecimalPad: openedWithDecimalPad, taps: taps)
    }

    /// Prints and attaches the number of taps an amount entry took.
    func recordTaps(_ entry: AmountEntry, amount: String, flow: String) {
        let summary = "\(flow): \(entry.taps) taps to enter \(amount) on the amount card "
            + "(opened with the decimal pad: \(entry.openedWithDecimalPad ? "yes" : "no"))"
        print(summary)
        let attachment = XCTAttachment(string: summary)
        attachment.name = "\(flow) — taps at the amount step"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    /// Taps an option in a list card.
    func choose(_ option: String) throws {
        let item = cards.staticTexts.matching(NSPredicate(format: "label == %@", option)).firstMatch
        try require(item, "the option “\(option)”", timeout: 10).tap()
        lastStep = "choosing \(option)"
    }

    /// Dismisses the visible card by tapping outside it, which cancels the run.
    func tapOutsideCard() {
        springboard.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.88)).tap()
        lastStep = "tapping outside the card"
    }

    /// Closes a card left open by a failed test.
    private func dismissVisibleCard() {
        guard cards.state == .runningForeground || cards.state == .runningBackground else { return }
        for title in ["Cancel", "Done"] {
            let button = cards.buttons[title].firstMatch
            if button.exists, button.isHittable {
                button.tap()
                return
            }
        }
        if cards.cells.firstMatch.exists { tapOutsideCard() }
    }

    // MARK: Failures

    /// Throws when the system shows that the action couldn't run.
    private func checkForRunFailure(in apps: [XCUIApplication]) throws {
        let failure = NSPredicate(format: "label CONTAINS 'could not run because an internal error occurred' OR label == 'Unable to run App Shortcut'")
        for app in apps where app.state == .runningForeground {
            let message = app.staticTexts.matching(failure).firstMatch
            if message.exists { try reportFailedRun(message.label) }
        }
    }

    /// Skips when the failure comes from the simulator build lacking a development team, and
    /// fails otherwise.
    ///
    /// Without a team identifier in the app's signature, linkd refuses Ledger's requests for its
    /// App Intents metadata ("Rejecting invalid client due to requiresValidBundle"). The system
    /// then can't start App Shortcuts ("Couldn't find AppShortcutsProvider") or turn a chosen
    /// category or account into an entity ("is not a registered AppEntity identifier").
    private func reportFailedRun(_ message: String) throws {
        attachScreenshot("Run failed after \(lastStep)")
        let team = LedgerInstallation.signingTeam()
        guard team == .none else {
            recordHierarchies(because: "Run failed")
            throw FlowError(description: "After \(lastStep), the system reported “\(message)” (signing: \(team))")
        }
        throw XCTSkip("""
            Not verifiable with this build. After \(lastStep), the system reported “\(message)”. Ledger is signed to \
            run locally without a development team, so linkd rejects its App Intents metadata requests and the system \
            can't resolve entity values or start App Shortcuts. Build with a development team to run this step.
            """)
    }
}
