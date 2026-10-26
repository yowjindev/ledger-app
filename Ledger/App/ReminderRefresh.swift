import SwiftUI

extension View {
    /// Plans reminders again whenever the app becomes active, so they follow the clock and any
    /// change made while the app was away.
    func refreshingReminders() -> some View {
        modifier(ReminderRefresh())
    }
}

private struct ReminderRefresh: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                await ReminderScheduler.shared.refresh()
            }
    }
}
