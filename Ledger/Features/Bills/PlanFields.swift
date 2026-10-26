import SwiftUI

/// The payments of a plan as the editors collect them: each payment, a different last one, the
/// number of months, and how many are already paid.
struct PlanPaymentsInput: Equatable {
    var title = ""
    var monthly: Decimal?
    var hasDifferentLast = false
    var last: Decimal?
    var months = 12
    var paidAtStart = 0
    /// The item's price, for a split already under way.
    var price: Decimal?

    var isComplete: Bool {
        !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && monthly != nil
            && (!hasDifferentLast || last != nil)
    }

    func terms(nextDue: CalendarDay) -> PlanTerms? {
        guard let monthly else { return nil }
        return PlanTerms(
            title: title,
            monthly: monthly,
            last: hasDifferentLast ? last : nil,
            months: months,
            paidAtStart: paidAtStart,
            nextDue: nextDue,
            price: price
        )
    }
}

/// Form rows for a plan's payments, shared by the loan and existing-split editors.
struct PlanPaymentRows: View {
    @Binding var input: PlanPaymentsInput
    let months: ClosedRange<Int>
    /// Whether to ask how many payments are already made.
    var asksPaidSoFar = true

    var body: some View {
        AmountField("Each Payment", amount: $input.monthly, accessibilityLabel: "Each monthly payment")
        Toggle("Last Payment Is Different", isOn: $input.hasDifferentLast.animation())
        if input.hasDifferentLast {
            AmountField("Last Payment", amount: $input.last, accessibilityLabel: "Last payment")
        }
        Stepper(value: $input.months, in: months) {
            LabeledContent("Months", value: "\(input.months)")
        }
        .onChange(of: input.months) { _, months in
            input.paidAtStart = min(input.paidAtStart, months - 1)
        }
        if asksPaidSoFar {
            Stepper(value: $input.paidAtStart, in: 0...max(input.months - 1, 0)) {
                LabeledContent("Already Paid", value: PlanCopy.progress(paid: input.paidAtStart, months: input.months))
            }
        }
    }
}
