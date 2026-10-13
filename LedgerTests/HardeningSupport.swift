import Foundation
import SwiftData
import XCTest
@testable import Ledger

/// Replaces the no-break spaces Foundation puts into formatted amounts with plain spaces.
func plainSpaces(_ text: String) -> String {
    text.replacingOccurrences(of: "\u{00A0}", with: " ").replacingOccurrences(of: "\u{202F}", with: " ")
}

/// An absolute instant written in ISO 8601 with an explicit offset, such as "2026-03-08T06:30:00Z".
func instant(_ text: String, file: StaticString = #filePath, line: UInt = #line) throws -> Date {
    try XCTUnwrap(ISO8601DateFormatter().date(from: text), "Unreadable fixture date \(text)", file: file, line: line)
}

/// A Gregorian calendar with a fixed time zone and first weekday, so results never depend on the
/// settings of the machine running the tests.
func fixedCalendar(
    _ timeZoneIdentifier: String,
    firstWeekday: Int = 1,
    file: StaticString = #filePath,
    line: UInt = #line
) throws -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = try XCTUnwrap(TimeZone(identifier: timeZoneIdentifier), file: file, line: line)
    calendar.locale = Locale(identifier: "en_US_POSIX")
    calendar.firstWeekday = firstWeekday
    return calendar
}

/// A money formatter with fixed preferences and locale.
func fixedFormatter(
    _ symbolStyle: CurrencySymbolStyle = .symbol,
    _ centavos: CentavoDisplay = .always,
    locale identifier: String = "en_US"
) -> MoneyFormatter {
    MoneyFormatter(
        preferences: DisplayPreferences(symbolStyle: symbolStyle, centavos: centavos),
        locale: Locale(identifier: identifier)
    )
}

/// Runs `body` with a `UserDefaults` suite that exists only for the duration of the call.
func withScratchDefaults<T>(_ body: (UserDefaults) throws -> T) throws -> T {
    let suiteName = "LedgerTests.\(UUID().uuidString)"
    let defaults = try XCTUnwrap(UserDefaults(suiteName: suiteName))
    defer { defaults.removePersistentDomain(forName: suiteName) }
    return try body(defaults)
}

extension LedgerHarness {
    /// Runs `mutation` on a service whose saves always fail, then asserts that it threw
    /// `.persistenceFailed` and left nothing pending in the shared context.
    func assertSaveFails<T>(
        file: StaticString = #filePath,
        line: UInt = #line,
        _ mutation: (LedgerService) throws -> T
    ) {
        let failing = failingLedger()
        assertThrowsLedgerError(.persistenceFailed, file: file, line: line) { try mutation(failing) }
        XCTAssertFalse(context.hasChanges, "A failed save must leave nothing pending", file: file, line: line)
    }

    /// Every interval, for summaries over the whole history.
    var allTime: DateInterval { DateInterval(start: .distantPast, end: .distantFuture) }
}
