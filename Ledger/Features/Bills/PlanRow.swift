import SwiftUI

/// A payment plan in a list: what it's for, each payment, how many are paid, and when the last
/// one is due.
struct PlanRow: View {
    let plan: PaymentPlan
    let monthsPaid: Int

    @Environment(\.moneyFormatter) private var formatter

    var body: some View {
        let progress = PlanCopy.progress(paid: monthsPaid, months: plan.months)
        let finish = PlanSnapshot(plan)?.slices.last.map { PlanCopy.finish($0.cycle) }
        AdaptiveRowLayout {
            VStack(alignment: .leading, spacing: 2) {
                Text(plan.title)
                Text([progress, finish].compactMap { $0 }.joined(separator: " · "))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        } trailing: {
            Text("\(formatter.string(plan.monthly)) a month")
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel([plan.title, progress, finish, "\(formatter.string(plan.monthly, alwaysShowCentavos: true)) a month"].compactMap { $0 }.joined(separator: ", "))
    }
}
