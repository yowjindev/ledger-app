import Foundation

/// One unpaid due to remind about.
struct ReminderItem: Hashable, Sendable {
    let status: DueStatus
    let name: String
    let symbolName: String
    /// The item's own strict reminder setting.
    let isStrict: Bool
    /// This cycle's arrival day, only while a varying bill's amount isn't entered yet.
    let arrivesDay: CalendarDay?
}

/// How the user wants to be reminded.
struct ReminderSettings: Hashable, Sendable {
    /// Strict reminders show a Live Activity that comes back until paid; otherwise only notifications.
    var isStrictEnabled: Bool
    /// When reminders arrive each day, in minutes after midnight.
    var minutesAfterMidnight: Int

    init(isStrictEnabled: Bool = true, minutesAfterMidnight: Int = 540) {
        self.isStrictEnabled = isStrictEnabled
        self.minutesAfterMidnight = minutesAfterMidnight
    }
}

/// A local notification to schedule. Its text never includes an amount.
struct PlannedNotification: Hashable, Sendable {
    /// "ledger.reminder.<owner key>.<headsup|due|arrives>.<yyyymmdd>".
    let id: String
    let date: Date
    let title: String
    let body: String
}

/// A Live Activity to start at `date`, showing `lines`.
struct PlannedActivityStart: Hashable, Sendable {
    let date: Date
    let lines: [ReminderLine]
}

/// Everything to schedule for the reminders, worked out at one moment.
struct ReminderPlan: Hashable, Sendable {
    /// By date, at most `ReminderPlanner.maxNotifications`.
    let notifications: [PlannedNotification]
    /// By date, at most `ReminderPlanner.maxActivityStarts`.
    let activityStarts: [PlannedActivityStart]
    /// Strict items due today or overdue and not snoozed, to show in a Live Activity right away.
    let showNow: [ReminderLine]
}

/// Pure reminder scheduling: which notifications and Live Activity starts each unpaid due gets.
///
/// Every due gets a heads-up notification the day before. On the due day and each overdue day,
/// a strict item joins the Live Activity started at the reminder time and again eight hours later,
/// or gets a notification on days past the cap on scheduled starts; any other item gets one
/// notification. A varying bill whose amount isn't entered also gets a
/// notification each day from its arrival day. A snooze holds an item back until it ends.
enum ReminderPlanner {
    static let idPrefix = "ledger.reminder."
    /// How far ahead reminders are scheduled.
    static let horizonDays = 14
    /// iOS ends a Live Activity after about eight hours, so a second one starts then.
    static let secondStartDelay: TimeInterval = 8 * 3_600
    /// iOS keeps at most 64 pending notifications per app.
    static let maxNotifications = 60
    /// Scheduled Live Activities count toward the system's limit on ongoing activities.
    static let maxActivityStarts = 3

    static func plan(
        items: [ReminderItem],
        settings: ReminderSettings,
        snoozedUntil: [String: Date],
        now: Date,
        calendar: Calendar
    ) -> ReminderPlan {
        let today = CalendarDay(containing: now, calendar: calendar)
        let lastDay = today.adding(days: horizonDays, calendar: calendar)
        func at(_ day: CalendarDay) -> Date {
            reminderTime(on: day, minutes: settings.minutesAfterMidnight, calendar: calendar)
        }

        var notifications: [PlannedNotification] = []
        // Each slot's lines, with the due day each was planned for.
        var slots: [Date: [(line: ReminderLine, day: CalendarDay)]] = [:]
        // Strict items' due and overdue days, with the notification to send if no kept start covers one.
        var strictDays: [(key: String, day: CalendarDay, notification: PlannedNotification)] = []
        var showNow: [ReminderLine] = []

        for item in items where !item.status.isPaid {
            let key = item.status.owner.key
            let due = item.status.dueDate
            let isStrict = settings.isStrictEnabled && item.isStrict
            let snooze = snoozedUntil[key].flatMap { $0 > now ? $0 : nil }
            func notification(_ kind: String, on day: CalendarDay, body: String) -> PlannedNotification? {
                let date = at(day)
                guard date > now else { return nil }
                return PlannedNotification(id: "\(idPrefix)\(key).\(kind).\(day.storedValue)", date: date, title: item.name, body: body)
            }
            func notify(_ kind: String, on day: CalendarDay, body: String) {
                if let planned = notification(kind, on: day, body: body) {
                    notifications.append(planned)
                }
            }

            notify("headsup", on: due.adding(days: -1, calendar: calendar), body: "Due tomorrow")

            if let arrives = item.arrivesDay {
                var day = max(arrives, today)
                while day < due, day <= lastDay {
                    notify("arrives", on: day, body: ReminderCopy.arrivalBody(name: item.name))
                    day = day.adding(days: 1, calendar: calendar)
                }
            }

            var day = max(due, today)
            while day <= lastDay {
                let dateText = line(for: item, on: day).dateText
                if isStrict {
                    for date in [at(day), at(day).addingTimeInterval(secondStartDelay)] where date > now {
                        if let snooze, date < snooze { continue }
                        slots[date, default: []].append((line(for: item, on: CalendarDay(containing: date, calendar: calendar)), day))
                    }
                    if snooze.map({ $0 <= at(day) }) ?? true, let planned = notification("due", on: day, body: dateText) {
                        strictDays.append((key, day, planned))
                    }
                } else {
                    notify("due", on: day, body: dateText)
                }
                day = day.adding(days: 1, calendar: calendar)
            }

            guard isStrict else { continue }
            if let snooze {
                let snoozeDay = CalendarDay(containing: snooze, calendar: calendar)
                if snoozeDay >= due {
                    slots[snooze, default: []].append((line(for: item, on: snoozeDay), snoozeDay))
                }
            } else if today >= due {
                showNow.append(line(for: item, on: today))
            }
        }

        let kept = slots.sorted { $0.key < $1.key }.prefix(maxActivityStarts)
        // A strict day no kept start covers, because of the cap, gets a notification instead.
        let covered = Set(kept.flatMap { $0.value.map { "\($0.line.ownerKey)|\($0.day.storedValue)" } })
        for strict in strictDays where !covered.contains("\(strict.key)|\(strict.day.storedValue)") {
            notifications.append(strict.notification)
        }
        return ReminderPlan(
            notifications: Array(notifications.sorted { ($0.date, $0.id) < ($1.date, $1.id) }.prefix(maxNotifications)),
            activityStarts: kept.map { PlannedActivityStart(date: $0.key, lines: sorted($0.value.map(\.line))) },
            showNow: sorted(showNow)
        )
    }

    /// The moment reminders arrive on `day`: its start plus `minutes`, in the calendar's time zone.
    static func reminderTime(on day: CalendarDay, minutes: Int, calendar: Calendar) -> Date {
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = calendar.timeZone
        let start = day.start(in: calendar)
        return gregorian.date(byAdding: .minute, value: minutes, to: start) ?? start
    }

    /// How an item reads on `day`: due today, or how many days overdue.
    static func line(for item: ReminderItem, on day: CalendarDay) -> ReminderLine {
        let due = item.status.dueDate
        var gregorian = Calendar(identifier: .gregorian)
        gregorian.timeZone = TimeZone(identifier: "UTC") ?? .gmt
        let late = gregorian.dateComponents([.day], from: due.start(in: gregorian), to: day.start(in: gregorian)).day ?? 0
        let text = switch late {
        case ...0: "Due today"
        case 1: "1 day overdue"
        default: "\(late) days overdue"
        }
        return ReminderLine(
            ownerKey: item.status.owner.key,
            name: item.name,
            symbolName: item.symbolName,
            dateText: text,
            isOverdue: late > 0
        )
    }

    /// Overdue lines first, then by name.
    private static func sorted(_ lines: [ReminderLine]) -> [ReminderLine] {
        lines.sorted { lhs, rhs in
            if lhs.isOverdue != rhs.isOverdue { return lhs.isOverdue }
            return lhs.name.localizedStandardCompare(rhs.name) == .orderedAscending
        }
    }
}

extension DueOwner {
    /// A stable text form, used in notification identifiers and Live Activity buttons.
    var key: String {
        switch self {
        case .account(let id): "account-\(id.uuidString)"
        case .bill(let id): "bill-\(id.uuidString)"
        }
    }

    init?(key: String) {
        if key.hasPrefix("account-"), let id = UUID(uuidString: String(key.dropFirst("account-".count))) {
            self = .account(id)
        } else if key.hasPrefix("bill-"), let id = UUID(uuidString: String(key.dropFirst("bill-".count))) {
            self = .bill(id)
        } else {
            return nil
        }
    }
}
