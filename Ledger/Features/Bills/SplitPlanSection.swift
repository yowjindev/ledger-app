import SwiftUI

/// What the transaction editor collects to split a pay later purchase into monthly payments.
struct SplitPlanInput: Equatable {
    var isOn = false
    var months = 3
    var monthly: Decimal?
    var hasDifferentLast = false
    var last: Decimal?
    /// The service's monthly fee as typed, a percentage of the price.
    var feeText = ""
    /// Whether the payment was typed rather than filled in from the fee.
    var isPaymentEdited = false

    /// Whether the last payment differs from the others. A single payment has no last one.
    var usesDifferentLast: Bool { hasDifferentLast && months > 1 }

    /// Ready to record: split, with the amounts the payments need.
    var isComplete: Bool {
        !isOn || (monthly != nil && (!usesDifferentLast || last != nil))
    }

    /// Fills in each payment from the price, months, and fee, unless one was typed. Leaves it alone
    /// without a price, or without a fee from 0% to 100%.
    mutating func fillPayment(price: Decimal?, locale: Locale) {
        guard !isPaymentEdited, let price, price > .zero, let rate = feeRate(locale: locale) else { return }
        monthly = LedgerService.splitPayment(price: price, months: months, feeRate: rate)
    }

    /// Records a payment typed in the field. The field repeating the filled-in amount isn't an
    /// edit, and clearing it lets the fee fill it in again.
    mutating func editPayment(_ amount: Decimal?) {
        guard amount != monthly else { return }
        monthly = amount
        isPaymentEdited = amount != nil
    }

    /// Shows the account's monthly fee, or nothing without one.
    mutating func setFeeRate(_ rate: Rate?, locale: Locale) {
        feeText = rate?.editableText(locale: locale) ?? ""
    }

    private func feeRate(locale: Locale) -> Rate? {
        guard
            !feeText.trimmingCharacters(in: .whitespaces).isEmpty,
            let percent = Rate.parse(feeText, locale: locale),
            percent >= .zero, percent <= 100,
            percent.hasAtMostFractionDigits(RateRules.maximumFractionDigits)
        else { return nil }
        return Rate(partsPerMillion: NSDecimalNumber(decimal: percent * 10_000).int64Value)
    }

    func purchase(from draft: TransactionDraft) -> SplitPurchase? {
        guard isOn, let monthly, let accountID = draft.accountID, let categoryID = draft.categoryID else { return nil }
        return SplitPurchase(
            amount: draft.amount,
            accountID: accountID,
            categoryID: categoryID,
            occurredAt: draft.occurredAt,
            note: draft.note,
            months: months,
            monthly: monthly,
            last: usesDifferentLast ? last : nil
        )
    }
}

/// Splits a pay later purchase into monthly payments: how many, the service's monthly fee, and
/// what each payment is. Each payment fills in from the price and fee and can be changed to match
/// the pay later app. Shows the extra the payments cost over the price.
struct SplitPlanSection: View {
    @Binding var input: SplitPlanInput
    /// The purchase price entered above.
    let price: Decimal?
    /// The account's monthly fee, shown when splitting starts or the account changes.
    let defaultFeeRate: Rate?

    @Environment(\.moneyFormatter) private var formatter
    @Environment(\.locale) private var locale

    var body: some View {
        Section {
            Toggle("Split Into Months", isOn: $input.isOn.animation())
            if input.isOn {
                Stepper(value: $input.months, in: LedgerService.splitMonths) {
                    LabeledContent("Months", value: "\(input.months)")
                }
                feeField
                AmountField("Each Payment", amount: payment, accessibilityLabel: "Each monthly payment")
                if input.months > 1 {
                    Toggle("Last Payment Is Different", isOn: $input.hasDifferentLast.animation())
                }
                if input.usesDifferentLast {
                    AmountField("Last Payment", amount: $input.last, accessibilityLabel: "Last payment")
                }
            }
        } footer: {
            Text(footer)
        }
        .onChange(of: input.isOn) { _, isOn in
            if isOn, input.feeText.isEmpty { input.setFeeRate(defaultFeeRate, locale: locale) }
            input.fillPayment(price: price, locale: locale)
        }
        .onChange(of: defaultFeeRate) { _, rate in
            input.setFeeRate(rate, locale: locale)
            input.fillPayment(price: price, locale: locale)
        }
        .onChange(of: price) { _, price in input.fillPayment(price: price, locale: locale) }
        .onChange(of: input.months) { _, _ in input.fillPayment(price: price, locale: locale) }
        .onChange(of: input.feeText) { _, newValue in
            let sanitized = AmountParser.sanitize(
                newValue,
                locale: locale,
                maximumFractionDigits: RateRules.maximumFractionDigits,
                maximumIntegerDigits: 3
            )
            if sanitized != newValue {
                input.feeText = sanitized
            } else {
                input.fillPayment(price: price, locale: locale)
            }
        }
    }

    private var feeField: some View {
        LabeledContent("Monthly Fee") {
            HStack(spacing: 4) {
                TextField("Monthly Fee", text: $input.feeText, prompt: Text("0"))
                    .keyboardType(.decimalPad)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                Text("% a month")
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
            }
        }
        .accessibilityElement(children: .combine)
    }

    /// The payment field's value. Only a changed amount counts as typed, since the field repeats
    /// an amount filled in for it.
    private var payment: Binding<Decimal?> {
        Binding(get: { input.monthly }, set: { input.editPayment($0) })
    }

    private var footer: String {
        guard input.isOn else { return "Paying next month or in 3, 6, or more months? Split it to track each payment on its due date." }
        guard let price, let monthly = input.monthly else {
            return "Enter the monthly fee to fill in each payment, or type the payment as your pay later app shows it. Payments start on this account's next due date."
        }
        let last = input.usesDifferentLast ? (input.last ?? monthly) : monthly
        return PlanCopy.splitSummary(price: price, months: input.months, monthly: monthly, last: last, formatter: formatter)
    }
}
