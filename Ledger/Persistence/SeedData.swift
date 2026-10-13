import Foundation

/// Accounts and categories inserted into an empty store on first launch.
///
/// Edit `personalDefault` to change what a fresh install starts with. Nothing here is used by
/// financial calculations; after seeding, everything is ordinary user-editable data.
struct SeedConfiguration: Sendable {
    struct AccountSeed: Sendable {
        var name: String
        var kind: AccountKind
        /// Leave `nil` so the user enters the real opening balance during setup.
        var openingBalance: Decimal? = nil
    }

    struct CategorySeed: Sendable {
        var name: String
        var kind: CategoryKind
        var symbolName: String
    }

    var accounts: [AccountSeed]
    var categories: [CategorySeed]
}

extension SeedConfiguration {
    /// Personal defaults. Opening balances are intentionally unset.
    static let personalDefault = SeedConfiguration(
        accounts: [
            AccountSeed(name: "GCash", kind: .eWallet),
            AccountSeed(name: "GoTyme", kind: .bank),
            AccountSeed(name: "Maya", kind: .eWallet),
            AccountSeed(name: "PNB", kind: .bank),
            AccountSeed(name: "Wallet", kind: .cash),
        ],
        categories: [
            CategorySeed(name: "Food", kind: .expense, symbolName: "fork.knife"),
            CategorySeed(name: "Transport", kind: .expense, symbolName: "car.fill"),
            CategorySeed(name: "Shopping", kind: .expense, symbolName: "bag.fill"),
            CategorySeed(name: "Bills", kind: .expense, symbolName: "doc.text.fill"),
            CategorySeed(name: "Bus", kind: .expense, symbolName: "bus.fill"),
            CategorySeed(name: "Gym", kind: .expense, symbolName: "dumbbell.fill"),
            CategorySeed(name: "Haircut", kind: .expense, symbolName: "scissors"),
            CategorySeed(name: "Jeep", kind: .expense, symbolName: "car.side.fill"),
            CategorySeed(name: "Marketing", kind: .expense, symbolName: "basket.fill"),
            CategorySeed(name: "Mobile Data", kind: .expense, symbolName: "antenna.radiowaves.left.and.right"),
            CategorySeed(name: "Salary", kind: .income, symbolName: "briefcase.fill"),
            CategorySeed(name: "Other income", kind: .income, symbolName: "plus.circle.fill"),
            CategorySeed(name: "Refund", kind: .income, symbolName: "arrow.uturn.backward.circle.fill"),
            CategorySeed(name: "Bonus", kind: .income, symbolName: "gift.fill"),
        ]
    )
}
