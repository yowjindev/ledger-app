import ActivityKit
import Foundation
import os

/// The due reminder Live Activities on this device. Each call looks the activities up itself, so
/// no activity object crosses between concurrency domains.
enum LiveActivities {
    /// Whether the user allows Ledger's Live Activities.
    static var areEnabled: Bool {
        ActivityAuthorizationInfo().areActivitiesEnabled
    }

    /// What the Live Activities on screen show now.
    static func shownLines() -> [ReminderLine] {
        shown().flatMap { $0.content.state.lines }
    }

    /// Closes every Live Activity on screen.
    static func endShown() async {
        for activity in shown() {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
    }

    /// Shows `showNow` in one Live Activity, or closes it when nothing is due, and brings the
    /// scheduled starts in line with `starts` (see `ActivityStartChanges`). New activities are
    /// requested only when `canStart`: iOS accepts them only while Ledger is on screen or running
    /// a Live Activity intent.
    static func apply(showNow: [ReminderLine], starts: [PlannedActivityStart], dueKeys: Set<String>, canStart: Bool) async {
        let current = shown()
        if showNow.isEmpty {
            for activity in current {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        } else if let first = current.first {
            await first.update(ActivityContent(state: .init(lines: showNow), staleDate: nil))
            for extra in current.dropFirst() {
                await extra.end(nil, dismissalPolicy: .immediate)
            }
        } else if canStart {
            do {
                _ = try Activity.request(
                    attributes: DueActivityAttributes(),
                    content: ActivityContent(state: .init(lines: showNow), staleDate: nil),
                    pushType: nil
                )
            } catch {
                Log.ledger.info("Couldn't show a due reminder now: \(String(describing: error), privacy: .private)")
            }
        }

        let pending = Activity<DueActivityAttributes>.activities.filter { $0.activityState == .pending }
        let changes = ActivityStartChanges.changes(
            pending: pending.map { PendingStart(id: $0.id, startsAt: $0.content.state.startsAt, lines: $0.content.state.lines) },
            planned: starts,
            dueKeys: dueKeys,
            canStart: canStart
        )
        for activity in pending where changes.end.contains(activity.id) {
            await activity.end(nil, dismissalPolicy: .immediate)
        }
        for start in changes.request {
            do {
                _ = try Activity.request(
                    attributes: DueActivityAttributes(),
                    content: ActivityContent(
                        state: .init(lines: start.lines, startsAt: start.date),
                        staleDate: start.date.addingTimeInterval(ReminderPlanner.secondStartDelay)
                    ),
                    pushType: nil,
                    style: .standard,
                    alertConfiguration: AlertConfiguration(
                        title: LocalizedStringResource(stringLiteral: ReminderCopy.activityTitle(start.lines)),
                        body: LocalizedStringResource(stringLiteral: ReminderCopy.activityBody(start.lines)),
                        sound: .default
                    ),
                    start: start.date
                )
            } catch {
                Log.ledger.info("Couldn't schedule a due reminder: \(String(describing: error), privacy: .private)")
            }
        }
    }

    private static func shown() -> [Activity<DueActivityAttributes>] {
        Activity<DueActivityAttributes>.activities.filter { $0.activityState == .active || $0.activityState == .stale }
    }
}
