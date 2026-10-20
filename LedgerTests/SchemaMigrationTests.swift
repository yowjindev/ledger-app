import Foundation
import SwiftData
import XCTest
@testable import Ledger

/// A store written by an earlier schema version opens with the current one, keeping every record
/// and giving new fields their defaults.
@MainActor
final class SchemaMigrationTests: XCTestCase {
    func testVersion1StoreOpensWithEveryRecordAndDefaults() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "LedgerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "Ledger.store", directoryHint: .notDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        do {
            let schema = Schema(versionedSchema: LedgerSchemaV1.self)
            let configuration = ModelConfiguration(schema: schema, url: url, allowsSave: true, cloudKitDatabase: .none)
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let context = container.mainContext
            let account = LedgerSchemaV1.Account(
                name: "Savings",
                kind: .bank,
                openingBalanceMinor: 1_250_050,
                createdAt: TestClock.referenceDate,
                sortOrder: 0
            )
            let food = LedgerSchemaV1.LedgerCategory(
                name: "Food",
                kind: .expense,
                symbolName: "fork.knife",
                createdAt: TestClock.referenceDate,
                sortOrder: 0
            )
            context.insert(account)
            context.insert(food)
            context.insert(LedgerSchemaV1.LedgerTransaction(
                kind: .expense,
                amountMinor: 25_000,
                currency: .php,
                occurredAt: TestClock.referenceDate,
                createdAt: TestClock.referenceDate,
                note: nil,
                account: account,
                destinationAccount: nil,
                category: food,
                origin: .app,
                reference: nil,
                requestID: nil
            ))
            try context.save()
        }

        let container = try LedgerStore.makeContainer(storage: .onDisk(url))
        let ledger = LedgerService(context: container.mainContext, clock: { TestClock.referenceDate })
        let savings = try XCTUnwrap(try ledger.accounts().first)
        XCTAssertEqual(savings.name, "Savings")
        XCTAssertEqual(savings.openingBalanceMinor, 1_250_050)
        XCTAssertNil(savings.interestRatePPM)
        XCTAssertEqual(savings.interestTaxRatePPM, 200_000)
        XCTAssertNil(savings.interestPaidThrough)
        let expense = try XCTUnwrap(try ledger.transactions().first)
        XCTAssertEqual(expense.amountMinor, 25_000)
        XCTAssertEqual(expense.category?.name, "Food")
        XCTAssertNil(expense.directionRaw)
        XCTAssertNil(expense.basisMinor)
        XCTAssertNil(expense.basisRatePPM)
        XCTAssertEqual(try ledger.balance(of: savings)?.currentBalance?.amount, dec("12250.50"))
    }
}
