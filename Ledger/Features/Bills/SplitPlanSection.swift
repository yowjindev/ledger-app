import SwiftUI

/// What the transaction editor collects to split a pay later purchase into monthly payments.
struct SplitPlanInput: Equatable {
    var isOn = false
    var months = 3
    var monthly: Decimal?
    var hasDifferentLast = false
    var last: Decimal?

    /// Whether the last payment differs from the others. A single payment has no last one.
    var usesDifferentLast: Bool { hasDifferentLast && months > 1 }

    /// Ready to record: split, with the amounts the payments need.
    var isComplete: Bool {
        !isOn || (monthly != nil && (!usesDifferentLast || last != nil))
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

/// Splits a pay later purchase into monthly payments: how many, and what each one is, as the pay
/// later app shows them. Shows the extra the payments cost over the price.
struct SplitPlanSection: View {
    @Binding var input: SplitPlanInput
    /// The purchase price entered above.
    let price: Decimal?

    @Environment(\.moneyFormatter) private var formatter

    var body: some View {
        Section {
            Toggle("Split Into Months", isOn: $input.isOn.animation())
            if input.isOn {
                Stepper(value: $input.months, in: LedgerService.splitMonths) {
                    LabeledContent("Months", value: "\(input.months)")
                }
                AmountField("Each Payment", amount: $input.monthly, accessibilityLabel: "Each monthly payment")
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
    }

    private var footer: String {
        guard input.isOn else { return "Paying next month or in 3, 6, or more months? Split it to track each payment on its due date." }
        guard let price, let monthly = input.monthly else {
            return "Enter each payment as your pay later app shows it. The first one is due on this account's next due date."
        }
        let last = input.usesDifferentLast ? (input.last ?? monthly) : monthly
        return PlanCopy.splitSummary(price: price, months: input.months, monthly: monthly, last: last, formatter: formatter)
    }
}
