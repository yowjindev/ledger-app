import Foundation
import SwiftUI

/// The total of active liquid accounts. Accounts left out because their opening balance isn't set
/// are named, and an unknown total is never shown as zero.
struct LiquidTotalSummary: View {
    let liquidTotal: LiquidTotal
    let hasActiveAccounts: Bool
    let showAccounts: () -> Void

    @Environment(\.moneyFormatter) private var formatter

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Total Liquid")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                headline
                if let coverage {
                    Text(coverage)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityElement(children: .combine)

            if let note {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.circle.fill")
                        .accessibilityHidden(true)
                    Text(note)
                }
                .font(.footnote)
                .foregroundStyle(.secondary)
            }

            if let actionTitle {
                Button(actionTitle, action: showAccounts)
                    .buttonStyle(.bordered)
                    .buttonBorderShape(.capsule)
            }
        }
        .padding(.vertical, 6)
    }

    /// The total, or a statement that it isn't known yet.
    @ViewBuilder
    private var headline: some View {
        if !liquidTotal.includedAccountIDs.isEmpty {
            LargeAmountText(formatter.string(liquidTotal.total))
        } else {
            Text(hasActiveAccounts ? LiquidTotalCopy.unavailable : "No Active Accounts")
                .font(.system(.title2, design: .rounded, weight: .semibold))
                .foregroundStyle(.secondary)
        }
    }

    /// "Across 5 accounts" when every active liquid account is included.
    private var coverage: String? {
        let count = liquidTotal.includedAccountIDs.count
        guard liquidTotal.isComplete, count > 0 else { return nil }
        return count == 1 ? "Across 1 account" : "Across \(count) accounts"
    }

    /// Why the total is incomplete or unavailable.
    private var note: String? {
        guard hasActiveAccounts else { return "Add an account to see your total." }
        return LiquidTotalCopy.note(for: liquidTotal)
    }

    private var actionTitle: String? {
        if !hasActiveAccounts { return "Go to Accounts" }
        return liquidTotal.isComplete ? nil : "Set Opening Balances"
    }
}

/// A prominent "Log Expense" button with smaller Income and Transfer buttons.
struct QuickAddButtons: View {
    let activeAccountCount: Int

    @Environment(AppRouter.self) private var router
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        VStack(spacing: 10) {
            Button {
                router.addTransaction(.expense)
            } label: {
                Label("Log Expense", systemImage: "plus")
                    .font(.headline)
                    .foregroundStyle(.background)
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!TransactionLogging.canLog(.expense, activeAccountCount: activeAccountCount))

            let layout = dynamicTypeSize.isAccessibilitySize
                ? AnyLayout(VStackLayout(spacing: 10))
                : AnyLayout(HStackLayout(spacing: 10))
            layout {
                secondaryButton(for: .income)
                secondaryButton(for: .transfer)
            }

            if let explanation {
                Text(explanation)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
        }
        .labelStyle(.titleAndIcon)
        .controlSize(.large)
    }

    private func secondaryButton(for kind: TransactionKind) -> some View {
        Button {
            router.addTransaction(kind)
        } label: {
            Label(kind.title, systemImage: kind.systemImage)
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.bordered)
        .disabled(!TransactionLogging.canLog(kind, activeAccountCount: activeAccountCount))
        .accessibilityLabel("Log \(kind.title)")
    }

    private var explanation: String? {
        switch activeAccountCount {
        case 0: "Add an account in Accounts to start logging."
        case 1: "Transfers need a second account."
        default: nil
        }
    }
}

/// Section header with a menu for the reporting period and the period's dates.
struct PeriodHeader: View {
    @Binding var period: ReportingPeriod
    let interval: DateInterval

    var body: some View {
        AdaptiveRowLayout {
            Menu {
                Picker("Period", selection: $period) {
                    ForEach(ReportingPeriod.allCases) { period in
                        Text(period.title).tag(period)
                    }
                }
            } label: {
                HStack(spacing: 4) {
                    Text(period.title)
                    Image(systemName: "chevron.up.chevron.down")
                        .imageScale(.small)
                }
                .contentShape(.rect)
            }
            .accessibilityLabel("Period")
            .accessibilityValue(period.title)
        } trailing: {
            Text(dateRange)
        }
        .textCase(nil)
    }

    /// "Oct 1 – 31". The interval's end is exclusive, so the last day shown is the one before it.
    private var dateRange: String {
        let lastMoment = interval.end.addingTimeInterval(-1)
        guard lastMoment > interval.start else { return "" }
        return (interval.start..<lastMoment).formatted(.interval.month(.abbreviated).day())
    }
}

/// Income, expenses, and net cash flow for a period, as list rows.
struct PeriodSummaryRows: View {
    let summary: PeriodSummary

    @Environment(\.moneyFormatter) private var formatter

    var body: some View {
        SummaryRow(
            title: "Income",
            detail: TransactionLogging.countText(summary.incomeCount),
            systemImage: TransactionKind.income.systemImage,
            tint: LedgerTheme.income,
            value: formatter.string(summary.income, sign: .always),
            valueColor: summary.income.isZero ? .primary : LedgerTheme.income
        )
        SummaryRow(
            title: "Expenses",
            detail: TransactionLogging.countText(summary.expenseCount),
            systemImage: TransactionKind.expense.systemImage,
            tint: LedgerTheme.badgeTint(for: .expense),
            value: formatter.string(-summary.expenses, sign: .always)
        )
        SummaryRow(
            title: "Net",
            detail: "Income minus expenses",
            systemImage: netSymbol,
            tint: netTint,
            value: formatter.string(summary.net, sign: .always),
            valueColor: summary.net.isPositive ? LedgerTheme.income : .primary
        )
    }

    /// An arrow for the direction of the net flow, so its sign isn't conveyed by color alone.
    private var netSymbol: String {
        if summary.net.isPositive { return "arrow.up" }
        if summary.net.isNegative { return "arrow.down" }
        return "equal"
    }

    private var netTint: Color {
        if summary.net.isPositive { return LedgerTheme.income }
        if summary.net.isNegative { return .orange }
        return .secondary
    }
}

/// A symbol, title, optional detail, and a trailing value.
struct SummaryRow: View {
    let title: String
    var detail: String?
    let systemImage: String
    let tint: Color
    let value: String
    var valueColor: Color = .primary

    var body: some View {
        HStack(spacing: 12) {
            SymbolBadge(systemName: systemImage, tint: tint)
            AdaptiveRowLayout {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.body)
                    if let detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            } trailing: {
                Text(value)
                    .font(.body.weight(.semibold))
                    .monospacedDigit()
                    .foregroundStyle(valueColor)
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// An account with its kind and current balance, or "Not set" while its opening balance is unknown.
struct AccountBalanceRow: View {
    let balance: AccountBalance

    @Environment(\.moneyFormatter) private var formatter

    var body: some View {
        HStack(spacing: 12) {
            SymbolBadge(systemName: balance.account.kind.systemImage)
            AdaptiveRowLayout {
                VStack(alignment: .leading, spacing: 2) {
                    Text(balance.account.name)
                        .font(.body)
                    Text(balance.account.kind.title)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            } trailing: {
                if let current = balance.currentBalance {
                    Text(formatter.string(current))
                        .font(.body.weight(.semibold))
                        .monospacedDigit()
                } else {
                    HStack(spacing: 4) {
                        Image(systemName: "exclamationmark.circle")
                        Text("Not Set")
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Balance not set")
                }
            }
        }
        .padding(.vertical, 2)
        .accessibilityElement(children: .combine)
    }
}

/// First-run explanation, shown until an opening balance is set or a transaction is logged.
struct WelcomeCard: View {
    let canLog: Bool
    let setOpeningBalances: () -> Void
    let logExpense: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Welcome to Ledger")
                    .font(.title2.weight(.bold))
                Text("Two steps and your balances are ready.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            .accessibilityElement(children: .combine)

            VStack(alignment: .leading, spacing: 14) {
                WelcomeStep(
                    systemImage: "wallet.bifold",
                    title: "Set opening balances",
                    detail: "Enter what each account holds today so balances and your total are accurate."
                )
                WelcomeStep(
                    systemImage: "button.horizontal.top.press",
                    title: "Log as you spend",
                    detail: "Tap Log Expense, or set the Action Button to the Ledger Menu shortcut in iPhone Settings to log without opening Ledger."
                )
            }

            VStack(spacing: 10) {
                Button(action: setOpeningBalances) {
                    Text("Set Opening Balances")
                        .font(.headline)
                        .foregroundStyle(.background)
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                Button(action: logExpense) {
                    Label("Log Expense", systemImage: "plus")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(!canLog)
            }
            .labelStyle(.titleAndIcon)
            .controlSize(.large)
        }
        .padding(.vertical, 10)
    }
}

/// One getting-started step in the welcome card.
private struct WelcomeStep: View {
    let systemImage: String
    let title: String
    let detail: String

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            SymbolBadge(systemName: systemImage)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
    }
}
