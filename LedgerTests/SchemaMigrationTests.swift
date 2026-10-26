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

    func testVersion2StoreOpensWithEveryRecordAndDefaults() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "LedgerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "Ledger.store", directoryHint: .notDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        do {
            let schema = Schema(versionedSchema: LedgerSchemaV2.self)
            let configuration = ModelConfiguration(schema: schema, url: url, allowsSave: true, cloudKitDatabase: .none)
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let context = container.mainContext
            let account = LedgerSchemaV2.Account(
                name: "Savings",
                kind: .bank,
                openingBalanceMinor: 1_250_050,
                createdAt: TestClock.referenceDate,
                sortOrder: 0
            )
            account.interestRatePPM = 32_500
            let food = LedgerSchemaV2.LedgerCategory(
                name: "Food",
                kind: .expense,
                symbolName: "fork.knife",
                createdAt: TestClock.referenceDate,
                sortOrder: 0
            )
            context.insert(account)
            context.insert(food)
            context.insert(LedgerSchemaV2.LedgerTransaction(
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
        let context = container.mainContext
        let ledger = LedgerService(context: context, clock: { TestClock.referenceDate })
        let savings = try XCTUnwrap(try ledger.accounts().first)
        XCTAssertEqual(savings.name, "Savings")
        XCTAssertEqual(savings.interestRatePPM, 32_500)
        XCTAssertNil(savings.statementDay)
        XCTAssertNil(savings.dueDay)
        XCTAssertNil(savings.creditLimitMinor)
        XCTAssertNil(savings.cashbackRatePPM)
        XCTAssertTrue(savings.strictReminder)
        XCTAssertNil(savings.dueSchedule)
        let expense = try XCTUnwrap(try ledger.transactions().first)
        XCTAssertEqual(expense.category?.name, "Food")
        XCTAssertNil(expense.sourceTransactionID)
        XCTAssertNil(expense.planID)
        XCTAssertNil(expense.billID)
        XCTAssertNil(expense.billCycle)
        XCTAssertTrue(expense.isEditable)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<PaymentPlan>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<Bill>()), 0)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<DueOverride>()), 0)
        XCTAssertEqual(try ledger.balance(of: savings)?.currentBalance?.amount, dec("12250.50"))
    }

    func testVersion3StoreOpensWithEveryRecordAndDefaults() throws {
        let directory = FileManager.default.temporaryDirectory
            .appending(path: "LedgerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appending(path: "Ledger.store", directoryHint: .notDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

        do {
            let schema = Schema(versionedSchema: LedgerSchemaV3.self)
            let configuration = ModelConfiguration(schema: schema, url: url, allowsSave: true, cloudKitDatabase: .none)
            let container = try ModelContainer(for: schema, configurations: [configuration])
            let context = container.mainContext
            let account = LedgerSchemaV3.Account(
                name: "PayLater",
                kind: .payLater,
                openingBalanceMinor: -150_000,
                createdAt: TestClock.referenceDate,
                sortOrder: 0
            )
            account.statementDay = 31
            account.dueDay = 5
            account.creditLimitMinor = 1_000_000
            context.insert(account)
            context.insert(LedgerSchemaV3.PaymentPlan(
                title: "Headphones",
                account: account,
                monthlyMinor: 50_000,
                lastMinor: 50_000,
                months: 3,
                paidAtStart: 0,
                firstDue: 20260405,
                createdAt: TestClock.referenceDate
            ))
            try context.save()
        }

        let container = try LedgerStore.makeContainer(storage: .onDisk(url))
        let ledger = LedgerService(context: container.mainContext, clock: { TestClock.referenceDate })
        let payLater = try XCTUnwrap(try ledger.accounts().first)
        XCTAssertEqual(payLater.name, "PayLater")
        XCTAssertFalse(payLater.feesUseLimit)
        XCTAssertEqual(payLater.creditLimitMinor, 1_000_000)
        let plan = try XCTUnwrap(try ledger.plans(for: payLater).first)
        XCTAssertNil(plan.feesMinor)
        XCTAssertEqual(plan.monthlyMinor, 50_000)
        XCTAssertEqual(plan.months, 3)
        XCTAssertEqual(try ledger.balance(of: payLater)?.owed?.amount, 1_500)
    }
}
