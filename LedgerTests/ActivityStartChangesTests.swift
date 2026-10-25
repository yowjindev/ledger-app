import Foundation
import XCTest
@testable import Ledger

/// Keeping scheduled Live Activity starts in step with the plan without losing them when iOS
/// won't accept new ones, and running reminder refreshes one at a time.
@MainActor
final class ActivityStartChangesTests: XCTestCase {
    private let nine = Date(timeIntervalSince1970: 1_773_968_400)
    private var five: Date { nine.addingTimeInterval(8 * 3_600) }
    private var nextNine: Date { nine.addingTimeInterval(24 * 3_600) }

    private func line(_ key: String, _ text: String = "Due today") -> ReminderLine {
        ReminderLine(ownerKey: key, name: key, symbolName: "doc.text", dateText: text, isOverdue: text != "Due today")
    }

    func testWhileStartsAreAllowedOnlyDifferencesChange() {
        let pending = [
            PendingStart(id: "a", startsAt: nine, lines: [line("rent")]),
            PendingStart(id: "b", startsAt: five, lines: [line("rent")]),
        ]
        let planned = [
            PlannedActivityStart(date: nine, lines: [line("rent")]),
            PlannedActivityStart(date: five, lines: [line("rent"), line("card")]),
            PlannedActivityStart(date: nextNine, lines: [line("rent", "1 day overdue")]),
        ]

        let changes = ActivityStartChanges.changes(pending: pending, planned: planned, dueKeys: ["rent", "card"], canStart: true)

        XCTAssertEqual(changes.end, ["b"])
        XCTAssertEqual(changes.request.map(\.date), [five, nextNine])
    }

    func testWhenStartsArentAllowedScheduledOnesAreKept() {
        let pending = [PendingStart(id: "a", startsAt: nine, lines: [line("rent")])]
        let planned = [PlannedActivityStart(date: five, lines: [line("rent")])]

        let changes = ActivityStartChanges.changes(pending: pending, planned: planned, dueKeys: ["rent"], canStart: false)

        XCTAssertTrue(changes.end.isEmpty)
        XCTAssertTrue(changes.request.isEmpty)
    }

    func testWhenStartsArentAllowedPaidDuesAreStillEnded() {
        let pending = [
            PendingStart(id: "paid", startsAt: nine, lines: [line("rent")]),
            PendingStart(id: "due", startsAt: five, lines: [line("card")]),
        ]

        let changes = ActivityStartChanges.changes(pending: pending, planned: [], dueKeys: ["card"], canStart: false)

        XCTAssertEqual(changes.end, ["paid"])
        XCTAssertTrue(changes.request.isEmpty)
    }

    func testSerialRunnerNeverOverlaps() async {
        let runner = SerialRunner()
        let recorder = EventRecorder()

        let first = Task {
            await runner.run {
                recorder.events.append("a-start")
                try? await Task.sleep(for: .milliseconds(50))
                recorder.events.append("a-end")
            }
        }
        let second = Task {
            await runner.run {
                recorder.events.append("b-start")
                recorder.events.append("b-end")
            }
        }
        await first.value
        await second.value

        XCTAssertEqual(recorder.events, ["a-start", "a-end", "b-start", "b-end"])
    }
}

@MainActor
private final class EventRecorder {
    var events: [String] = []
}
