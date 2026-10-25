import SwiftUI
import UIKit
import UserNotifications

/// Settings for due reminders: strict mode, the time reminders arrive, and notification permission.
struct ReminderSettingsSection: View {
    @AppStorage(ReminderPreferences.Keys.strictEnabled) private var isStrictEnabled = true
    @AppStorage(ReminderPreferences.Keys.minutes) private var minutes = 540
    @Environment(\.scenePhase) private var scenePhase
    @State private var permission: UNAuthorizationStatus?

    var body: some View {
        Section {
            Toggle("Strict Reminders", isOn: $isStrictEnabled)
            DatePicker("Reminder Time", selection: time, displayedComponents: .hourAndMinute)
            permissionRow
        } header: {
            Text("Reminders")
        } footer: {
            Text(isStrictEnabled
                ? "On a due day, bills and debts show in the Dynamic Island and on the Lock Screen until they're paid. Turn this off for notifications only. Reminders never show amounts."
                : "You'll get a notification the day before, on the due day, and each day it's overdue. Reminders never show amounts.")
        }
        .onChange(of: isStrictEnabled) { ReminderScheduler.shared.scheduleRefresh() }
        .onChange(of: minutes) { ReminderScheduler.shared.scheduleRefresh() }
        .task(id: scenePhase) {
            permission = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
        }
    }

    @ViewBuilder
    private var permissionRow: some View {
        switch permission {
        case .notDetermined:
            Button("Allow Notifications") {
                Task {
                    _ = try? await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound, .badge])
                    permission = await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
                    ReminderScheduler.shared.scheduleRefresh()
                }
            }
        case .denied:
            Button("Turn On Notifications in Settings") {
                if let url = URL(string: UIApplication.openNotificationSettingsURLString) {
                    UIApplication.shared.open(url)
                }
            }
        default:
            EmptyView()
        }
    }

    /// The reminder time as a date today, for the time picker.
    private var time: Binding<Date> {
        Binding {
            Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: .now) ?? .now
        } set: { date in
            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
            minutes = (parts.hour ?? 9) * 60 + (parts.minute ?? 0)
        }
    }
}
