import SwiftData
import SwiftUI

/// Turns strict reminders on or off for one bill or debt.
struct StrictReminderToggle: View {
    let owner: DueOwner
    let isOn: Bool

    @Environment(\.modelContext) private var modelContext
    @AppStorage(ReminderPreferences.Keys.strictEnabled) private var isStrictEnabled = true
    @State private var alert: LedgerAlert?

    var body: some View {
        Section {
            Toggle("Strict Reminder", isOn: Binding(get: { isOn }, set: change))
                .disabled(!isStrictEnabled)
        } footer: {
            Text(isStrictEnabled
                ? "On the due day, it shows in the Dynamic Island and on the Lock Screen until it's paid. Off: notifications only."
                : "Strict reminders are off in Settings, so this gets notifications only.")
        }
        .ledgerAlert($alert)
    }

    private func change(_ value: Bool) {
        do {
            try LedgerService(context: modelContext).setStrictReminder(value, for: owner)
        } catch {
            alert = LedgerAlert(error)
        }
    }
}
