import AppIntents
import Foundation

/// One row of the list an intent shows when it finishes.
struct ResultListItem: Equatable, Sendable {
    let id: String
    let title: String
    let subtitle: String
    let symbolName: String
}

/// Shows an intent's result in the system's own list, the one Shortcuts and Siri use for menus such
/// as the Ledger Menu. The system draws it, so its text follows the glass behind it in light and
/// dark appearance like the rest of the system's interface.
///
/// The list is a value prompt: choosing a row or dismissing the list closes it. Either way the
/// result was saved before the list appeared.
@MainActor
enum ResultList {
    /// The outcome being listed. `ResultListOptions` reads it while the list is on screen.
    private(set) static var shown: IntentOutcome?

    /// The outcome's rows, each subtitle led by the row's value, for example "₱4,230.00 · E-wallet".
    static func items(for outcome: IntentOutcome) -> [ResultListItem] {
        outcome.rows.map { row in
            ResultListItem(
                id: row.id.uuidString,
                title: row.title,
                subtitle: ([row.value ?? "Not Set"] + [row.subtitle].compactMap { $0 }).joined(separator: " · "),
                symbolName: row.symbolName
            )
        }
    }

    /// Lists the outcome's rows under its headline until a row is chosen or the list is dismissed.
    static func show(_ outcome: IntentOutcome, ask: (IntentDialog) async throws -> Void) async {
        shown = outcome
        defer { shown = nil }
        // Choosing a row and dismissing the list both just close it.
        _ = try? await ask(outcome.dialog)
    }
}

/// Supplies the rows of the list on screen.
struct ResultListOptions: DynamicOptionsProvider {
    @MainActor
    func results() async throws -> IntentItemCollection<String> {
        guard let outcome = ResultList.shown else { return .empty }
        let items = ResultList.items(for: outcome).map { item in
            IntentItem(
                item.id,
                title: "\(item.title)",
                subtitle: "\(item.subtitle)",
                image: DisplayRepresentation.Image(systemName: item.symbolName)
            )
        }
        return IntentItemCollection(sections: [IntentItemSection(items: items)])
    }
}
