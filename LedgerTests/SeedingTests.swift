import Foundation
import SwiftData
import XCTest
@testable import Ledger

/// First-launch seeding with configured opening balances: valid values are stored exactly and an
/// invalid one seeds nothing at all, so a fresh store is never half set up.
@MainActor
final class SeedingTests: XCTestCase {
    func testConfiguredOpeningBalancesAreSeededExactly() throws {
        let container = try LedgerStore.makeContainer(storage: .inMemory)
        let seed = SeedConfiguration(
            accounts: [
                .init(name: "GCash", kind: .eWallet, openingBalance: dec("4230.50")),
                .init(name: "Wallet", kind: .cash, openingBalance: 0),
                .init(name: "PNB", kind: .bank),
                .init(name: "Vault", kind: .other, openingBalance: AmountRules.maximum),
            ],
            categories: [
                .init(name: "Food", kind: .expense, symbolName: "fork.knife"),
                .init(name: "Salary", kind: .income, symbolName: "briefcase.fill"),
                .init(name: "Bills", kind: .expense, symbolName: "doc.text.fill"),
            ]
        )

        let seeded = LedgerBootstrapper(context: container.mainContext, marker: nil)
            .seedIfNeeded(with: seed, now: TestClock.referenceDate)

        XCTAssertTrue(seeded)
        let ledger = LedgerService(context: container.mainContext)
        let accounts = try ledger.accounts()
        XCTAssertEqual(accounts.map(\.name), ["GCash", "Wallet", "PNB", "Vault"])
        XCTAssertEqual(accounts.map(\.openingBalanceMinor), [423_050, 0, nil, 99_999_999_999_999])
        XCTAssertTrue(accounts.allSatisfy { $0.currency == .php && $0.createdAt == TestClock.referenceDate })
        let total = try ledger.balanceSheet().liquidTotal
        XCTAssertEqual(total.total.amount, dec("4230.50") + AmountRules.maximum)
        XCTAssertEqual(total.accountsMissingOpeningBalance.map(\.name), ["PNB"], "An unset seed balance is not zero")
        XCTAssertEqual(try ledger.categories(kind: .expense).map(\.sortOrder), [0, 1])
        XCTAssertEqual(try ledger.categories(kind: .income).map(\.sortOrder), [0])
    }

    func testAnInvalidConfiguredOpeningBalanceSeedsNothingAndCanBeRetried() throws {
        let invalidBalances: [(label: String, value: Decimal)] = [
            ("negative", dec("-1")),
            ("too precise", dec("10.005")),
            ("too large", AmountRules.maximum + dec("0.01")),
        ]
        for (label, value) in invalidBalances {
            try withScratchDefaults { defaults in
                let container = try LedgerStore.makeContainer(storage: .inMemory)
                let context = container.mainContext
                let bootstrapper = LedgerBootstrapper(context: context, marker: defaults)
                // The invalid value follows a valid account, so a partial insert would show.
                let seed = SeedConfiguration(
                    accounts: [
                        .init(name: "GCash", kind: .eWallet, openingBalance: 100),
                        .init(name: "PNB", kind: .bank, openingBalance: value),
                    ],
                    categories: [.init(name: "Food", kind: .expense, symbolName: "fork.knife")]
                )

                XCTAssertFalse(bootstrapper.seedIfNeeded(with: seed), label)
                XCTAssertEqual(try context.fetchCount(FetchDescriptor<Account>()), 0, label)
                XCTAssertEqual(try context.fetchCount(FetchDescriptor<LedgerCategory>()), 0, label)
                XCTAssertFalse(context.hasChanges, label)
                XCTAssertFalse(defaults.bool(forKey: LedgerBootstrapper.seedMarkerKey), "\(label): a failed seed is retried next launch")

                XCTAssertTrue(bootstrapper.seedIfNeeded(with: .personalDefault), label)
                XCTAssertTrue(defaults.bool(forKey: LedgerBootstrapper.seedMarkerKey), label)
                XCTAssertEqual(try context.fetchCount(FetchDescriptor<Account>()), 5, label)
            }
        }
    }

    func testAStoreWithOnlyCategoriesIsNotSeeded() throws {
        let container = try LedgerStore.makeContainer(storage: .inMemory)
        let ledger = LedgerService(context: container.mainContext)
        try ledger.createCategory(name: "Food", kind: .expense)

        let seeded = LedgerBootstrapper(context: container.mainContext, marker: nil).seedIfNeeded(with: .personalDefault)

        XCTAssertFalse(seeded)
        XCTAssertTrue(try ledger.accounts(includeArchived: true).isEmpty)
        XCTAssertEqual(try ledger.categories(kind: .expense).map(\.name), ["Food"])
    }
}
