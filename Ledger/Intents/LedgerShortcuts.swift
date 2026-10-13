import AppIntents

/// App Shortcuts that appear automatically in the Shortcuts app, Spotlight, Siri, and the
/// Action Button's shortcut picker once Ledger is installed. Assigning one to the Action Button
/// is done by the user in Settings > Action Button.
struct LedgerShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: LedgerMenuIntent(),
            phrases: [
                "\(.applicationName) menu",
                "Show the \(.applicationName) menu",
                "Log with \(.applicationName)",
            ],
            shortTitle: "Ledger Menu",
            systemImageName: "list.bullet.circle.fill"
        )
        AppShortcut(
            intent: LogExpenseIntent(),
            phrases: [
                "Log an expense in \(.applicationName)",
                "Add an expense to \(.applicationName)",
                "Log expense with \(.applicationName)",
            ],
            shortTitle: "Log Expense",
            systemImageName: "arrow.up.right.circle.fill"
        )
        AppShortcut(
            intent: LogIncomeIntent(),
            phrases: [
                "Log income in \(.applicationName)",
                "Add income to \(.applicationName)",
            ],
            shortTitle: "Log Income",
            systemImageName: "arrow.down.left.circle.fill"
        )
        AppShortcut(
            intent: TransferMoneyIntent(),
            phrases: [
                "Transfer money in \(.applicationName)",
                "Log a transfer in \(.applicationName)",
            ],
            shortTitle: "Transfer Money",
            systemImageName: "arrow.left.arrow.right.circle.fill"
        )
        AppShortcut(
            intent: CheckBalancesIntent(),
            phrases: [
                "Check my \(.applicationName) balances",
                "Show my balances in \(.applicationName)",
            ],
            shortTitle: "Check Balances",
            systemImageName: "banknote.fill"
        )
    }

    static let shortcutTileColor: ShortcutTileColor = .teal
}
