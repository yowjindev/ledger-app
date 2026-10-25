import Foundation
import SwiftData
import SwiftUI
import UIKit

/// A small capsule marking an archived account, category, or income source.
struct ArchivedTag: View {
    var body: some View {
        Text("Archived")
            .font(.caption2.weight(.semibold))
            .foregroundStyle(.secondary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(.quaternary, in: .capsule)
    }
}

/// A name followed by an "Archived" tag when the record is archived.
struct NameWithArchivedTag: View {
    let name: String
    let isArchived: Bool

    var body: some View {
        HStack(spacing: 6) {
            Text(name)
            if isArchived {
                ArchivedTag()
            }
        }
        .accessibilityElement(children: .combine)
    }
}

/// A prominent amount on one line. Uses the large title size when it fits and steps down a text
/// style at a time for long amounts or large text sizes, so digits never wrap or truncate.
struct LargeAmountText: View {
    let text: String

    init(_ text: String) {
        self.text = text
    }

    var body: some View {
        ViewThatFits(in: .horizontal) {
            amount(.largeTitle)
            amount(.title)
            amount(.title2)
                .minimumScaleFactor(0.5)
        }
    }

    private func amount(_ style: Font.TextStyle) -> some View {
        Text(text)
            .font(.system(style, design: .rounded, weight: .semibold))
            .monospacedDigit()
            .lineLimit(1)
    }
}

/// Toolbar menu that opens the shared editor for a new expense, income, or transfer.
struct AddTransactionMenu: View {
    /// Number of active accounts. Logging needs one; a transfer needs two.
    let activeAccountCount: Int

    @Environment(AppRouter.self) private var router

    var body: some View {
        Menu {
            ForEach(TransactionKind.loggable) { kind in
                Button(kind.title, systemImage: kind.systemImage) {
                    router.addTransaction(kind)
                }
                .disabled(!TransactionLogging.canLog(kind, activeAccountCount: activeAccountCount))
            }
        } label: {
            Label("Add Transaction", systemImage: "plus")
        }
        .disabled(activeAccountCount == 0)
    }
}

/// When the app offers to record a transaction, and shared wording about transactions.
enum TransactionLogging {
    /// Whether a transaction of `kind` can be recorded with this many active accounts.
    static func canLog(_ kind: TransactionKind, activeAccountCount: Int) -> Bool {
        switch kind {
        case .expense, .income: activeAccountCount >= 1
        case .transfer: activeAccountCount >= 2
        case .adjustment: false
        }
    }

    /// "No transactions", "1 transaction", or "12 transactions".
    static func countText(_ count: Int) -> String {
        switch count {
        case 0: "No transactions"
        case 1: "1 transaction"
        default: "\(count.formatted()) transactions"
        }
    }

    /// Where a transaction was entered, for display.
    static func sourceDescription(_ origin: EntryOrigin) -> String {
        switch origin {
        case .app: "Ledger app"
        case .appIntent: "Shortcuts, Siri, or Action Button"
        case .interest: "Added by Ledger"
        }
    }
}

/// Places `trailing` after `leading` on one line, or below it at accessibility text sizes so
/// neither is truncated.
struct AdaptiveRowLayout<Leading: View, Trailing: View>: View {
    private let leading: Leading
    private let trailing: Trailing

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    init(@ViewBuilder leading: () -> Leading, @ViewBuilder trailing: () -> Trailing) {
        self.leading = leading()
        self.trailing = trailing()
    }

    var body: some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 4) {
                leading
                trailing
            }
        } else {
            HStack(spacing: 8) {
                leading
                Spacer(minLength: 8)
                trailing
            }
        }
    }
}

extension View {
    /// Sets `date` to the current time when the app becomes active and when the day or time zone
    /// changes, so relative labels such as "Today" and the current period stay correct.
    func refreshingCurrentDate(_ date: Binding<Date>) -> some View {
        modifier(CurrentDateRefresher(date: date))
    }
}

private struct CurrentDateRefresher: ViewModifier {
    @Binding var date: Date
    @Environment(\.scenePhase) private var scenePhase

    func body(content: Content) -> some View {
        content
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { date = .now }
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
                date = .now
            }
    }
}

#if DEBUG
/// Passes the ID of the newest transaction in the preview store to `content`.
struct NewestTransactionPreview<Content: View>: View {
    private let content: (UUID) -> Content

    @Query(sort: LedgerService.newestFirst) private var transactions: [LedgerTransaction]

    init(@ViewBuilder content: @escaping (UUID) -> Content) {
        self.content = content
    }

    var body: some View {
        if let transaction = transactions.first {
            content(transaction.id)
        } else {
            ContentUnavailableView("No Sample Transactions", systemImage: "tray")
        }
    }
}
#endif
