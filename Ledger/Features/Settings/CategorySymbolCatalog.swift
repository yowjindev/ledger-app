import Foundation

/// An SF Symbol offered for expense categories and income sources.
struct CategorySymbolChoice: Identifiable, Hashable, Sendable {
    let symbolName: String
    /// What the symbol depicts, read by VoiceOver.
    let label: String

    var id: String { symbolName }
}

/// The curated symbols offered when creating or editing a category or income source.
///
/// Every symbol the seed data uses is included, so seeded categories open with their symbol
/// selected. `scripts/check_sf_symbols.py` validates each entry because this file's name contains
/// "Symbol"; keep other dotted lowercase string literals out of this file.
enum CategorySymbolCatalog {
    /// Symbols for spending, grouped loosely: food and shopping, transport, bills, home and health,
    /// leisure and travel, family and giving.
    static let spending: [CategorySymbolChoice] = [
        CategorySymbolChoice(symbolName: "fork.knife", label: "Fork and Knife"),
        CategorySymbolChoice(symbolName: "cup.and.saucer.fill", label: "Coffee Cup"),
        CategorySymbolChoice(symbolName: "cart.fill", label: "Shopping Cart"),
        CategorySymbolChoice(symbolName: "basket.fill", label: "Basket"),
        CategorySymbolChoice(symbolName: "bag.fill", label: "Shopping Bag"),
        CategorySymbolChoice(symbolName: "tshirt.fill", label: "T-Shirt"),
        CategorySymbolChoice(symbolName: "car.fill", label: "Car"),
        CategorySymbolChoice(symbolName: "car.side.fill", label: "Car, Side View"),
        CategorySymbolChoice(symbolName: "bus.fill", label: "Bus"),
        CategorySymbolChoice(symbolName: "tram.fill", label: "Train"),
        CategorySymbolChoice(symbolName: "motorcycle", label: "Motorcycle"),
        CategorySymbolChoice(symbolName: "fuelpump.fill", label: "Fuel Pump"),
        CategorySymbolChoice(symbolName: "doc.text.fill", label: "Bill"),
        CategorySymbolChoice(symbolName: "bolt.fill", label: "Lightning Bolt"),
        CategorySymbolChoice(symbolName: "drop.fill", label: "Water Drop"),
        CategorySymbolChoice(symbolName: "wifi", label: "Wi-Fi"),
        CategorySymbolChoice(symbolName: "antenna.radiowaves.left.and.right", label: "Mobile Signal"),
        CategorySymbolChoice(symbolName: "iphone", label: "Phone"),
        CategorySymbolChoice(symbolName: "house.fill", label: "House"),
        CategorySymbolChoice(symbolName: "wrench.and.screwdriver.fill", label: "Tools"),
        CategorySymbolChoice(symbolName: "shippingbox.fill", label: "Package"),
        CategorySymbolChoice(symbolName: "cross.case.fill", label: "First Aid Kit"),
        CategorySymbolChoice(symbolName: "pills.fill", label: "Pills"),
        CategorySymbolChoice(symbolName: "dumbbell.fill", label: "Dumbbell"),
        CategorySymbolChoice(symbolName: "scissors", label: "Scissors"),
        CategorySymbolChoice(symbolName: "hands.and.sparkles.fill", label: "Personal Care"),
        CategorySymbolChoice(symbolName: "graduationcap.fill", label: "Graduation Cap"),
        CategorySymbolChoice(symbolName: "film.fill", label: "Film"),
        CategorySymbolChoice(symbolName: "gamecontroller.fill", label: "Game Controller"),
        CategorySymbolChoice(symbolName: "airplane", label: "Airplane"),
        CategorySymbolChoice(symbolName: "suitcase.rolling.fill", label: "Suitcase"),
        CategorySymbolChoice(symbolName: "figure.2.and.child.holdinghands", label: "Family"),
        CategorySymbolChoice(symbolName: "pawprint.fill", label: "Paw Print"),
        CategorySymbolChoice(symbolName: "gift.fill", label: "Gift"),
        CategorySymbolChoice(symbolName: "heart.fill", label: "Heart"),
        CategorySymbolChoice(symbolName: "tag.fill", label: "Tag"),
    ]

    /// Symbols for earning and saving.
    static let earning: [CategorySymbolChoice] = [
        CategorySymbolChoice(symbolName: "briefcase.fill", label: "Briefcase"),
        CategorySymbolChoice(symbolName: "laptopcomputer", label: "Laptop"),
        CategorySymbolChoice(symbolName: "banknote.fill", label: "Banknote"),
        CategorySymbolChoice(symbolName: "building.columns.fill", label: "Bank"),
        CategorySymbolChoice(symbolName: "pesosign.circle.fill", label: "Peso Sign"),
        CategorySymbolChoice(symbolName: "chart.line.uptrend.xyaxis", label: "Rising Chart"),
        CategorySymbolChoice(symbolName: "arrow.uturn.backward.circle.fill", label: "Return Arrow"),
        CategorySymbolChoice(symbolName: "plus.circle.fill", label: "Plus"),
    ]

    /// Every choice, ordered for `kind`: income sources list earning symbols first.
    ///
    /// - Parameter current: A symbol the category already uses. If it isn't one of the curated
    ///   choices, it is offered first so the category's existing symbol can stay selected.
    static func choices(for kind: CategoryKind, keeping current: String? = nil) -> [CategorySymbolChoice] {
        let ordered = kind == .income ? earning + spending : spending + earning
        guard let current, !current.isEmpty, !ordered.contains(where: { $0.symbolName == current }) else {
            return ordered
        }
        return [CategorySymbolChoice(symbolName: current, label: "Current Symbol")] + ordered
    }
}
