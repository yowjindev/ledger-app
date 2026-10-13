import AppIntents
import SwiftUI

/// How to use Ledger's App Shortcuts from the Action Button, the Shortcuts app, Spotlight, and
/// Siri, and what to expect while logging.
struct ActionButtonGuideView: View {
    @AppStorage(AppPreferences.Keys.warnsAboutDuplicates) private var warnsAboutDuplicates = true

    var body: some View {
        List {
            Section {
                SettingsGuideHeader(
                    systemImage: "square.2.layers.3d.fill",
                    title: "Log in a Few Taps",
                    message: "Record expenses, income, and transfers without opening Ledger, from the Action Button, Siri, Spotlight, or the Shortcuts app."
                )
            }

            shortcutsSection
            actionButtonSection
            elsewhereSection
            loggingSection
            emailSection

            Section("Privacy") {
                SettingsInfoRow(
                    systemImage: "lock.fill",
                    title: "When iPhone Is Locked",
                    detail: "iOS asks you to unlock before Ledger shows or records anything."
                )
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Shortcuts & Action Button")
        .navigationBarTitleDisplayMode(.inline)
    }

    // MARK: Sections

    private var shortcutsSection: some View {
        Section {
            SettingsInfoRow(
                systemImage: "list.bullet",
                title: "Ledger Menu",
                detail: "Choose Expense, Income, Transfer, or Check Balances."
            )
            SettingsInfoRow(
                systemImage: TransactionKind.expense.systemImage,
                tint: LedgerTheme.badgeTint(for: .expense),
                title: "Log Expense",
                detail: "The quickest way to record spending."
            )
            SettingsInfoRow(
                systemImage: TransactionKind.income.systemImage,
                tint: LedgerTheme.badgeTint(for: .income),
                title: "Log Income",
                detail: "Record money you received."
            )
            SettingsInfoRow(
                systemImage: TransactionKind.transfer.systemImage,
                tint: LedgerTheme.badgeTint(for: .transfer),
                title: "Transfer Money",
                detail: "Move money between your accounts."
            )
            SettingsInfoRow(
                systemImage: "banknote.fill",
                title: "Check Balances",
                detail: "See each account's balance and your total."
            )
        } header: {
            Text("Ledger's Shortcuts")
        }
    }

    private var actionButtonSection: some View {
        Section {
            SettingsStepRow(
                number: 1,
                systemImage: "gearshape.fill",
                title: "Open Settings",
                detail: "Then tap **Action Button**."
            )
            SettingsStepRow(
                number: 2,
                systemImage: "hand.draw",
                title: "Swipe to Shortcut",
                detail: "Swipe through the actions until you reach **Shortcut**."
            )
            SettingsStepRow(
                number: 3,
                systemImage: "hand.tap",
                title: "Tap Choose a Shortcut"
            )
            SettingsStepRow(
                number: 4,
                systemImage: "magnifyingglass",
                title: "Find Ledger",
                detail: "Scroll to **Ledger**, or search for it."
            )
            SettingsStepRow(
                number: 5,
                systemImage: "checkmark.circle.fill",
                title: "Choose Ledger Menu",
                detail: "Or choose **Log Expense** for the fastest expense logging."
            )
        } header: {
            VStack(alignment: .leading, spacing: 2) {
                Text("Set Up the Action Button")
                Text("iPhone 15 Pro and later")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .textCase(nil)
            }
        } footer: {
            Text("Ledger can't assign the Action Button for you. Only you can choose what it does, in the Settings app.")
        }
    }

    private var emailSection: some View {
        Section {
            SettingsStepRow(
                number: 1,
                systemImage: "envelope.fill",
                title: "Get Alerts in Mail",
                detail: "Your bank's emails must arrive in Apple's **Mail** app. Automations can't see other email apps."
            )
            SettingsStepRow(
                number: 2,
                systemImage: "gearshape.2.fill",
                title: "Create an Automation",
                detail: "In **Shortcuts**, open **Automation**, tap **+**, choose **Email**, and enter your bank's address as the sender."
            )
            SettingsStepRow(
                number: 3,
                systemImage: "bolt.fill",
                title: "Choose Run Immediately"
            )
            SettingsStepRow(
                number: 4,
                systemImage: "square.and.pencil",
                title: "Add Log From Message",
                detail: "Set **Message** to **Shortcut Input** and **Account** to that bank's account in Ledger."
            )
            SettingsNoteRow(
                systemImage: "checkmark.shield",
                text: "Ledger reads the email on this iPhone, asks for anything it couldn't read, and always asks before saving. An email whose reference number was already logged is flagged."
            )
        } header: {
            Text("Log From Bank Emails")
        } footer: {
            Text("For banks that email each transaction, such as MariBank. Every bank words its emails differently, so check the first few entries.")
        }
    }

    private var elsewhereSection: some View {
        Section {
            SettingsInfoRow(
                systemImage: "square.2.layers.3d.fill",
                title: "Shortcuts App",
                detail: "Ledger's shortcuts appear automatically. There's nothing to set up."
            )
            SettingsInfoRow(
                systemImage: "magnifyingglass",
                title: "Spotlight",
                detail: "Search for a shortcut, such as “Log Expense.”"
            )
            SettingsInfoRow(
                systemImage: "waveform",
                title: "Siri",
                detail: "Say “Log an expense in Ledger.”"
            )
            ShortcutsLink()
                .frame(maxWidth: .infinity)
                .padding(.vertical, 6)
        } header: {
            Text("Also in Shortcuts, Spotlight, and Siri")
        }
    }

    private var loggingSection: some View {
        Section {
            SettingsStepRow(
                number: 1,
                systemImage: "pesosign",
                title: "Amount",
                detail: "Type how much."
            )
            SettingsStepRow(
                number: 2,
                systemImage: "tag.fill",
                title: "Category or Source",
                detail: "What it was for, or where the money came from."
            )
            SettingsStepRow(
                number: 3,
                systemImage: "wallet.bifold.fill",
                title: "Account",
                detail: "Where it was paid from or received into."
            )
            SettingsStepRow(
                number: 4,
                systemImage: "checkmark.circle.fill",
                title: "Confirmation",
                detail: "Ledger shows what was saved."
            )
            SettingsNoteRow(
                systemImage: TransactionKind.transfer.systemImage,
                text: "Transfers ask for both accounts, then ask you to confirm before saving."
            )
            SettingsNoteRow(
                systemImage: "exclamationmark.circle",
                text: "Unusually large amounts ask you to confirm, too."
            )
            SettingsNoteRow(
                systemImage: "xmark.circle",
                text: "Cancel at any step and nothing is saved."
            )
            if warnsAboutDuplicates {
                SettingsNoteRow(
                    systemImage: "doc.on.doc",
                    text: "Ledger asks before saving something identical to an entry from the last \(SettingsCopy.duplicateWindow)."
                )
            } else {
                SettingsNoteRow(
                    systemImage: "doc.on.doc",
                    text: "Duplicate warnings are off, so identical entries are saved without asking."
                )
            }
        } header: {
            Text("How Logging Works")
        }
    }
}

#Preview {
    NavigationStack {
        ActionButtonGuideView()
    }
    .ledgerPreview()
}
