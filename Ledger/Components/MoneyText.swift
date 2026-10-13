import SwiftUI

/// An amount formatted with the user's currency display preferences.
struct MoneyText: View {
    let money: Money
    var sign: MoneyFormatter.SignStyle = .automatic
    var alwaysShowCentavos = false

    @Environment(\.moneyFormatter) private var formatter

    init(_ money: Money, sign: MoneyFormatter.SignStyle = .automatic, alwaysShowCentavos: Bool = false) {
        self.money = money
        self.sign = sign
        self.alwaysShowCentavos = alwaysShowCentavos
    }

    var body: some View {
        Text(formatter.string(money, sign: sign, alwaysShowCentavos: alwaysShowCentavos))
            .monospacedDigit()
    }
}

/// A circular badge showing an SF Symbol, used for categories, accounts, and transfers.
struct SymbolBadge: View {
    let systemName: String
    var tint: Color = .accentColor
    var size: CGFloat = 36

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: size * 0.44, weight: .semibold))
            .foregroundStyle(tint)
            .frame(width: size, height: size)
            .background(tint.opacity(0.15), in: Circle())
            .accessibilityHidden(true)
    }
}
