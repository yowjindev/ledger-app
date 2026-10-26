import Foundation
import XCTest
@testable import Ledger

/// Reminder settings and snoozes kept in `UserDefaults`.
final class ReminderPreferencesTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_773_540_000)

    func testDefaults() throws {
        try withScratchDefaults { defaults in
            let settings = ReminderPreferences.settings(in: defaults)
            XCTAssertTrue(settings.isStrictEnabled)
            XCTAssertEqual(settings.minutesAfterMidnight, 540)

            defaults.set(false, forKey: ReminderPreferences.Keys.strictEnabled)
            defaults.set(1_200, forKey: ReminderPreferences.Keys.minutes)
            XCTAssertEqual(ReminderPreferences.settings(in: defaults), ReminderSettings(isStrictEnabled: false, minutesAfterMidnight: 1_200))
        }
    }

    func testSnoozeRoundTrips() throws {
        try withScratchDefaults { defaults in
            let until = now.addingTimeInterval(3_600)
            ReminderPreferences.snooze(["a", "b"], until: until, in: defaults)

            XCTAssertEqual(ReminderPreferences.snoozes(in: defaults, now: now), ["a": until, "b": until])
        }
    }

    func testExpiredAndPaidSnoozesAreDropped() throws {
        try withScratchDefaults { defaults in
            ReminderPreferences.snooze(["old"], until: now.addingTimeInterval(-60), in: defaults)
            ReminderPreferences.snooze(["due", "paid"], until: now.addingTimeInterval(600), in: defaults)

            XCTAssertEqual(Set(ReminderPreferences.snoozes(in: defaults, now: now).keys), ["due", "paid"])

            ReminderPreferences.clearSnoozes(except: ["due"], in: defaults)
            XCTAssertEqual(Set(ReminderPreferences.snoozes(in: defaults, now: now).keys), ["due"])
            ReminderPreferences.clearSnoozes(except: [], in: defaults)
            XCTAssertTrue(ReminderPreferences.snoozes(in: defaults, now: now).isEmpty)
        }
    }
}
