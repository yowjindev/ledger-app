import SwiftUI

/// A text field for entering an amount. Accepts digits and the locale's decimal separator, with
/// at most two decimal places. `amount` is `nil` while the field is empty or unparseable.
struct AmountField: View {
    let title: String
    @Binding var amount: Decimal?
    var currency: CurrencyCode = .php
    /// Spoken label when it should say more than the placeholder, such as which account it's for.
    var accessibilityLabel: String?

    @Environment(\.moneyFormatter) private var formatter
    @Environment(\.locale) private var locale
    @State private var text = ""

    init(_ title: String, amount: Binding<Decimal?>, currency: CurrencyCode = .php, accessibilityLabel: String? = nil) {
        self.title = title
        self._amount = amount
        self.currency = currency
        self.accessibilityLabel = accessibilityLabel
    }

    var body: some View {
        HStack(spacing: 6) {
            Text(formatter.currencyLabel(for: currency))
                .foregroundStyle(.secondary)
                .accessibilityHidden(true)
            TextField(title, text: $text)
                .keyboardType(.decimalPad)
                .monospacedDigit()
                .accessibilityLabel(accessibilityLabel ?? title)
        }
        .onAppear(perform: showAmount)
        .onChange(of: text) { _, newValue in
            let sanitized = AmountParser.sanitize(newValue, locale: locale, maximumFractionDigits: currency.minorUnitDigits)
            guard sanitized == newValue else {
                text = sanitized
                return
            }
            amount = AmountParser.parse(sanitized, locale: locale)
        }
        .onChange(of: amount) { _, newValue in
            if newValue != AmountParser.parse(text, locale: locale) { showAmount() }
        }
    }

    private func showAmount() {
        text = amount.map { AmountParser.editableText(for: $0, locale: locale) } ?? ""
    }
}
