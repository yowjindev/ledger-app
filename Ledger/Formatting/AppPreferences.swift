import Foundation

/// Non-financial app preferences stored in `UserDefaults`, shared by the app and App Intents.
enum AppPreferences {
    enum Keys {
        /// Bool, default `true`: ask before recording an entry identical to one saved moments ago.
        static let warnsAboutDuplicates = "preferences.warnsAboutDuplicates"
        /// `ReportingPeriod` raw value, default `.thisMonth`: the dashboard's income and expense period.
        static let dashboardPeriod = "preferences.dashboardPeriod"
        /// UUID string: the account last used in the app's transaction editor, preselected next time.
        static let lastUsedAccountID = "preferences.lastUsedAccountID"
    }

    static func warnsAboutDuplicates(in defaults: UserDefaults = .standard) -> Bool {
        defaults.object(forKey: Keys.warnsAboutDuplicates) as? Bool ?? true
    }
}
