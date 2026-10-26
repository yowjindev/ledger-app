import ActivityKit
import Foundation

/// One due as a reminder shows it: name, symbol, and when it's due. Never an amount, because
/// reminders appear on the Lock Screen.
struct ReminderLine: Hashable, Sendable, Codable {
    /// The owed account or bill, as `DueOwner.key`.
    let ownerKey: String
    let name: String
    let symbolName: String
    /// "Due today", "1 day overdue", "3 days overdue".
    let dateText: String
    let isOverdue: Bool
}

/// The Live Activity for everything due today or overdue. Shared by the app, which starts it,
/// and the widget extension, which draws it.
struct DueActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable, Sendable {
        /// Overdue first, then by name.
        var lines: [ReminderLine]
        /// When a scheduled start begins, so the app can tell its pending starts apart.
        var startsAt: Date?
    }
}
