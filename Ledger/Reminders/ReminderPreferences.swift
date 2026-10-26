import Foundation

/// Reminder settings and snoozes, stored in `UserDefaults` and shared by the app and App Intents.
enum ReminderPreferences {
    enum Keys {
        /// Bool, default `true`: strict reminders for items whose own toggle is on.
        static let strictEnabled = "reminders.strictEnabled"
        /// Int, default 540 (9:00): when reminders arrive, in minutes after midnight.
        static let minutes = "reminders.minutes"
        /// [owner key: seconds since 1970]: when each snooze ends.
        static let snoozes = "reminders.snoozes"
    }

    static func settings(in defaults: UserDefaults = .standard) -> ReminderSettings {
        ReminderSettings(
            isStrictEnabled: defaults.object(forKey: Keys.strictEnabled) as? Bool ?? true,
            minutesAfterMidnight: defaults.object(forKey: Keys.minutes) as? Int ?? 540
        )
    }

    /// Snoozes that haven't ended by `now`.
    static func snoozes(in defaults: UserDefaults = .standard, now: Date) -> [String: Date] {
        stored(in: defaults).compactMapValues { seconds in
            let date = Date(timeIntervalSince1970: seconds)
            return date > now ? date : nil
        }
    }

    static func snooze(_ keys: [String], until date: Date, in defaults: UserDefaults = .standard) {
        var all = stored(in: defaults)
        for key in keys {
            all[key] = date.timeIntervalSince1970
        }
        defaults.set(all, forKey: Keys.snoozes)
    }

    /// Removes snoozes for anything not in `keys`, such as dues paid since.
    static func clearSnoozes(except keys: Set<String>, in defaults: UserDefaults = .standard) {
        defaults.set(stored(in: defaults).filter { keys.contains($0.key) }, forKey: Keys.snoozes)
    }

    private static func stored(in defaults: UserDefaults) -> [String: Double] {
        defaults.dictionary(forKey: Keys.snoozes) as? [String: Double] ?? [:]
    }
}
