import Foundation
import SwiftData
import XCTest
@testable import Ledger

/// A controllable clock so tests never depend on the wall clock.
@MainActor
final class TestClock {
    /// 2026-03-15 02:00:00 UTC (10:00 in Manila).
    static let referenceDate = Date(timeIntervalSince1970: 1_773_540_000)

    var now: Date

    init(_ now: Date = TestClock.referenceDate) {
        self.now = now
    }

    func advance(by seconds: TimeInterval) {
        now = now.addingTimeInterval(seconds)
    }
}

struct SimulatedSaveFailure: Error {}

/// Parses a decimal literal written with "." so fixtures never pass through `Double`.
func dec(_ text: String) -> Decimal {
    Decimal(string: text, locale: Locale(identifier: "en_US_POSIX")) ?? .nan
}

/// An isolated in-memory ledger with fixture helpers. Every test builds its own harness, so no
/// state is shared between tests and no real data is involved.
@MainActor
final class LedgerHarness {
    let container: ModelContainer
    let clock: TestClock
    let ledger: LedgerService

    var context: ModelContext { container.mainContext }

    init(clock: TestClock = TestClock(), calendar: Calendar = .current) throws {
        self.container = try LedgerStore.makeContainer(storage: .inMemory)
        self.clock = clock
        self.ledger = LedgerService(context: container.mainContext, clock: { clock.now }, calendar: calendar)
    }

    /// A service over the same context whose saves always fail, as if storage were full.
    func failingLedger() -> LedgerService {
        LedgerService(
            context: context,
            clock: { [clock] in clock.now },
            calendar: ledger.calendar,
            persist: { _ in throw SimulatedSaveFailure() }
        )
    }

    @discardableResult
    func account(_ name: String, opening: Decimal?, kind: AccountKind = .bank) throws -> Account {
        try ledger.createAccount(name: name, kind: kind, openingBalance: opening)
    }

    @discardableResult
    func expenseCategory(_ name: String) throws -> LedgerCategory {
        try ledger.createCategory(name: name, kind: .expense)
    }

    @discardableResult
    func incomeSource(_ name: String) throws -> LedgerCategory {
        try ledger.createCategory(name: name, kind: .income)
    }

    /// Current balance, or `nil` while the opening balance is unset.
    func balance(_ account: Account) throws -> Decimal? {
        try ledger.balance(of: account)?.currentBalance?.amount
    }

    func liquidTotal() throws -> LiquidTotal {
        try ledger.balanceSheet().liquidTotal
    }

    func transactionCount() throws -> Int {
        try context.fetchCount(FetchDescriptor<LedgerTransaction>())
    }
}

/// Asserts that `expression` throws exactly `expected`.
@MainActor
func assertThrowsLedgerError<T>(
    _ expected: LedgerError,
    file: StaticString = #filePath,
    line: UInt = #line,
    _ expression: () throws -> T
) {
    do {
        _ = try expression()
        XCTFail("Expected \(expected), but no error was thrown", file: file, line: line)
    } catch let error as LedgerError {
        XCTAssertEqual(error, expected, file: file, line: line)
    } catch {
        XCTFail("Expected \(expected), got \(error)", file: file, line: line)
    }
}
