import Foundation
import SwiftData
import SwiftUI
import os

extension View {
    /// Posts daily interest that's due whenever the app becomes active, then again at each
    /// 1:00 AM while it stays open.
    func postingDueInterest() -> some View {
        modifier(InterestCatchUp())
    }
}

private struct InterestCatchUp: ViewModifier {
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.modelContext) private var modelContext

    func body(content: Content) -> some View {
        content
            .task(id: scenePhase) {
                guard scenePhase == .active else { return }
                while !Task.isCancelled {
                    let ledger = LedgerService(context: modelContext)
                    do {
                        try ledger.postDueInterest()
                    } catch {
                        // Nothing was saved; the next run tries again.
                        Log.ledger.error("Couldn't post daily interest: \(String(describing: error), privacy: .private)")
                    }
                    let next = InterestCalculator.nextPostingTime(after: ledger.now, calendar: ledger.calendar)
                    try? await Task.sleep(for: .seconds(max(1, next.timeIntervalSince(ledger.now) + 1)))
                }
            }
    }
}
