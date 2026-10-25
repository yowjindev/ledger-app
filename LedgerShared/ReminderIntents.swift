import AppIntents
import Foundation

// The due reminder Live Activity's buttons. They're compiled into the widget extension so its
// buttons can name them, and run in the app, which does the work.

/// Hides the reminder for a while; it comes back when the snooze ends.
struct SnoozeReminderIntent: LiveActivityIntent {
    static let title: LocalizedStringResource = "Snooze Reminder"
    static let isDiscoverable = false

    @Parameter(title: "Minutes")
    var minutes: Int

    init() {}

    init(minutes: Int) {
        self.minutes = minutes
    }

    static var parameterSummary: some ParameterSummary {
        Summary("Snooze for \(\.$minutes) minutes")
    }

    func perform() async throws -> some IntentResult {
        #if !LEDGER_WIDGET
        await ReminderActions.snooze(minutes: minutes)
        #endif
        return .result()
    }
}

/// Opens Ledger to pay a due. Paying always happens in the app, never from the Lock Screen.
struct PayDueFromReminderIntent: AppIntent {
    static let title: LocalizedStringResource = "Pay Due"
    static let isDiscoverable = false
    static let supportedModes: IntentModes = .foreground

    @Parameter(title: "Due")
    var ownerKey: String

    init() {}

    init(ownerKey: String) {
        self.ownerKey = ownerKey
    }

    static var parameterSummary: some ParameterSummary {
        Summary("Pay \(\.$ownerKey)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !LEDGER_WIDGET
        ReminderActions.openPayment(ownerKey: ownerKey)
        #endif
        return .result()
    }
}

/// Opens Ledger to move this month's due date.
struct MoveDueFromReminderIntent: AppIntent {
    static let title: LocalizedStringResource = "Move Due"
    static let isDiscoverable = false
    static let supportedModes: IntentModes = .foreground

    @Parameter(title: "Due")
    var ownerKey: String

    init() {}

    init(ownerKey: String) {
        self.ownerKey = ownerKey
    }

    static var parameterSummary: some ParameterSummary {
        Summary("Move \(\.$ownerKey)")
    }

    @MainActor
    func perform() async throws -> some IntentResult {
        #if !LEDGER_WIDGET
        ReminderActions.openMove(ownerKey: ownerKey)
        #endif
        return .result()
    }
}
