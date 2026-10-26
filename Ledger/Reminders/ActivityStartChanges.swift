import Foundation

/// A scheduled Live Activity start already on the device.
struct PendingStart: Hashable, Sendable {
    let id: String
    let startsAt: Date?
    let lines: [ReminderLine]
}

/// How to bring the scheduled Live Activity starts in line with the plan.
struct ActivityStartChanges: Hashable, Sendable {
    /// Pending starts to end, by id.
    let end: [String]
    /// Planned starts to request.
    let request: [PlannedActivityStart]

    /// While new starts can be requested, ends the pending starts the plan no longer has and
    /// requests the planned ones not already pending. When they can't (iOS accepts them only while
    /// Ledger is on screen or running a Live Activity intent), leaves the schedule in place, ending
    /// only pending starts that name a due no longer due, so a paid bill never reminds.
    static func changes(pending: [PendingStart], planned: [PlannedActivityStart], dueKeys: Set<String>, canStart: Bool) -> ActivityStartChanges {
        guard canStart else {
            let stale = pending.filter { start in start.lines.contains { !dueKeys.contains($0.ownerKey) } }
            return ActivityStartChanges(end: stale.map(\.id), request: [])
        }
        let matches = { (start: PendingStart, plan: PlannedActivityStart) in start.startsAt == plan.date && start.lines == plan.lines }
        return ActivityStartChanges(
            end: pending.filter { start in !planned.contains { matches(start, $0) } }.map(\.id),
            request: planned.filter { plan in !pending.contains { matches($0, plan) } }
        )
    }
}
