import Foundation
import UserNotifications

/// Turns planned reminders into local notification requests.
enum NotificationRequests {
    /// Groups Ledger's reminders together in Notification Center.
    static let threadIdentifier = "ledger.reminders"

    static func requests(for plan: ReminderPlan, calendar: Calendar) -> [UNNotificationRequest] {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        return plan.notifications.map { planned in
            let content = UNMutableNotificationContent()
            content.title = planned.title
            content.body = planned.body
            content.sound = .default
            content.threadIdentifier = threadIdentifier
            let components = gregorian.dateComponents([.year, .month, .day, .hour, .minute], from: planned.date)
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
            return UNNotificationRequest(identifier: planned.id, content: content, trigger: trigger)
        }
    }
}
