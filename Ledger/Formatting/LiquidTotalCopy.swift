import Foundation

/// Wording for the total liquid balance, shared by every screen and App Intent that shows it.
enum LiquidTotalCopy {
    /// Shown in place of the total when no account in it has an opening balance yet.
    static let unavailable = "Not Available"

    /// Names the active accounts left out of the total because their opening balance isn't set,
    /// or `nil` when every active account is included.
    static func note(for liquidTotal: LiquidTotal) -> String? {
        let missing = liquidTotal.accountsMissingOpeningBalance
        guard !missing.isEmpty else { return nil }
        let names = missing.map(\.name).formatted(.list(type: .and))
        if liquidTotal.includedAccountIDs.isEmpty {
            return missing.count == 1
                ? "Set the opening balance of \(names) to see your total."
                : "Set the opening balances of \(names) to see your total."
        }
        return missing.count == 1
            ? "Excludes \(names) until its opening balance is set."
            : "Excludes \(names) until their opening balances are set."
    }
}
