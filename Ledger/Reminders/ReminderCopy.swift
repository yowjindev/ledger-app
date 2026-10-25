import Foundation

/// Wording for reminders. It names what's due and when, never how much, because reminders appear
/// on the Lock Screen.
enum ReminderCopy {
    /// "Rent · due today", "PayLater · 2 days overdue".
    static func line(_ line: ReminderLine) -> String {
        let when = line.dateText.prefix(1).lowercased() + line.dateText.dropFirst()
        return "\(line.name) · \(when)"
    }

    /// "Rent is due today", "Rent is overdue", or "3 bills need paying".
    static func activityTitle(_ lines: [ReminderLine]) -> String {
        guard lines.count == 1, let line = lines.first else { return "\(lines.count) bills need paying" }
        return line.isOverdue ? "\(line.name) is overdue" : "\(line.name) is due today"
    }

    /// The lines joined for an alert: "Rent · due today, PayLater · 2 days overdue".
    static func activityBody(_ lines: [ReminderLine]) -> String {
        lines.map(line).joined(separator: ", ")
    }

    static func arrivalBody(name: String) -> String {
        "Check if your \(name) bill came in"
    }
}
