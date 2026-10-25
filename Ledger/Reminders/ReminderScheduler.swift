import Foundation
import SwiftData
import UIKit
import UserNotifications
import os

/// Applies the reminder plan: replaces Ledger's pending notifications and scheduled Live
/// Activities with the ones the plan calls for, and shows or closes the Live Activity for what's
/// due now. Refreshes after every save, so paying a due removes its reminders at once.
@MainActor
final class ReminderScheduler {
    static let shared = ReminderScheduler()

    private var container: ModelContainer?
    private var saveObserver: NSObjectProtocol?
    private var pendingRefresh: Task<Void, Never>?
    private let runner = SerialRunner()

    /// Starts refreshing after every save to `container`.
    func start(container: ModelContainer) {
        self.container = container
        guard saveObserver == nil else { return }
        saveObserver = NotificationCenter.default.addObserver(forName: ModelContext.didSave, object: nil, queue: .main) { _ in
            Task { @MainActor in ReminderScheduler.shared.scheduleRefresh() }
        }
    }

    /// Refreshes shortly, so several saves in a row refresh once.
    func scheduleRefresh() {
        pendingRefresh?.cancel()
        pendingRefresh = Task {
            try? await Task.sleep(for: .milliseconds(300))
            guard !Task.isCancelled else { return }
            await refresh()
        }
    }

    /// Plans every reminder again from the ledger and applies the plan, one refresh at a time.
    ///
    /// - Parameter canStartActivities: Whether iOS will accept new Live Activities now: while the
    ///   app is on screen, or inside a Live Activity intent. Defaults to whether the app is active.
    func refresh(canStartActivities: Bool? = nil) async {
        let canStart = canStartActivities ?? (UIApplication.shared.applicationState == .active)
        await runner.run { await self.performRefresh(canStartActivities: canStart) }
    }

    private func performRefresh(canStartActivities: Bool) async {
        guard let container else { return }
        let ledger = LedgerService(context: container.mainContext)
        let items: [ReminderItem]
        do {
            items = try ledger.reminderItems()
        } catch {
            Log.ledger.error("Couldn't plan reminders: \(String(describing: error), privacy: .private)")
            return
        }
        ReminderPreferences.clearSnoozes(except: Set(items.map(\.status.owner.key)))
        var settings = ReminderPreferences.settings()
        // Without Live Activities, strict items fall back to notifications.
        settings.isStrictEnabled = settings.isStrictEnabled && LiveActivities.areEnabled
        let plan = ReminderPlanner.plan(
            items: items,
            settings: settings,
            snoozedUntil: ReminderPreferences.snoozes(now: ledger.now),
            now: ledger.now,
            calendar: ledger.calendar
        )
        if !items.isEmpty {
            await requestPermissionIfNeeded()
        }
        await applyNotifications(plan, calendar: ledger.calendar)
        await LiveActivities.apply(
            showNow: plan.showNow,
            starts: plan.activityStarts,
            dueKeys: Set(items.map(\.status.owner.key)),
            canStart: canStartActivities
        )
    }

    /// Asks once for permission to notify, only while the app is on screen and not running a
    /// throwaway debug store.
    func requestPermissionIfNeeded() async {
        guard UIApplication.shared.applicationState == .active, !AppLaunchConfiguration.current.usesInMemoryStore else { return }
        let center = UNUserNotificationCenter.current()
        guard await center.notificationSettings().authorizationStatus == .notDetermined else { return }
        do {
            _ = try await center.requestAuthorization(options: [.alert, .sound, .badge])
        } catch {
            Log.ledger.error("Couldn't ask for notification permission: \(String(describing: error), privacy: .private)")
        }
    }

    private func applyNotifications(_ plan: ReminderPlan, calendar: Calendar) async {
        let center = UNUserNotificationCenter.current()
        let pendingIDs = await center.pendingNotificationRequests().map(\.identifier).filter { $0.hasPrefix(ReminderPlanner.idPrefix) }
        center.removePendingNotificationRequests(withIdentifiers: pendingIDs)
        let status = await center.notificationSettings().authorizationStatus
        guard status == .authorized || status == .provisional || status == .ephemeral else { return }
        for request in NotificationRequests.requests(for: plan, calendar: calendar) {
            do {
                try await center.add(request)
            } catch {
                Log.ledger.error("Couldn't schedule a reminder: \(String(describing: error), privacy: .private)")
            }
        }
    }
}
