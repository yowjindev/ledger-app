import Foundation

/// What the due reminder Live Activity's buttons do in the app.
@MainActor
enum ReminderActions {
    /// Snoozes everything the Live Activity shows for `minutes`, closes it, and plans its return.
    static func snooze(minutes: Int) async {
        snooze(lines: LiveActivities.shownLines(), minutes: minutes, now: .now, defaults: .standard)
        await LiveActivities.endShown()
        await ReminderScheduler.shared.refresh()
    }

    static func snooze(lines: [ReminderLine], minutes: Int, now: Date, defaults: UserDefaults) {
        ReminderPreferences.snooze(lines.map(\.ownerKey), until: now.addingTimeInterval(TimeInterval(minutes * 60)), in: defaults)
    }

    /// Opens the payment for a due. Nothing is paid until the user confirms it in the app.
    static func openPayment(ownerKey: String, routing: ReminderRouting = .shared) {
        guard let owner = DueOwner(key: ownerKey) else { return }
        routing.pending = .pay(owner)
    }

    static func openMove(ownerKey: String, routing: ReminderRouting = .shared) {
        guard let owner = DueOwner(key: ownerKey) else { return }
        routing.pending = .move(owner)
    }
}
