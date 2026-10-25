import Foundation
import SwiftData
import SwiftUI

/// Details of one transaction, with editing and deletion. The record is looked up by ID, so the
/// screen copes with it being deleted elsewhere: it shows "not found" for an unknown ID and closes
/// itself if the record disappears while shown.
struct TransactionDetailView: View {
    let transactionID: UUID

    @Environment(AppRouter.self) private var router
    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss

    @Query private var matches: [LedgerTransaction]
    @Query private var cashbackMatches: [LedgerTransaction]
    @Query private var plans: [PaymentPlan]
    @Environment(\.moneyFormatter) private var formatter

    /// The last details shown. Keeps the screen intact while it closes after a deletion.
    @State private var lastShown: TransactionDetails?
    /// Set once the screen is closing because its transaction was deleted.
    @State private var isLeaving = false
    @State private var isConfirmingDeletion = false
    @State private var alert: LedgerAlert?

    init(transactionID: UUID) {
        self.transactionID = transactionID
        var descriptor = FetchDescriptor<LedgerTransaction>(predicate: #Predicate { $0.id == transactionID })
        descriptor.fetchLimit = 1
        _matches = Query(descriptor)
        let key: UUID? = transactionID
        _cashbackMatches = Query(filter: #Predicate<LedgerTransaction> { $0.sourceTransactionID == key })
    }

    var body: some View {
        let live = isLeaving ? nil : liveTransaction
        let current = live.map(TransactionDetails.init)
        Group {
            if let details = current ?? lastShown {
                content(details)
                    .disabled(current == nil)
            } else {
                ContentUnavailableView(
                    "Transaction Not Found",
                    systemImage: "questionmark.circle",
                    description: Text("It may have been deleted.")
                )
            }
        }
        .navigationTitle((current ?? lastShown)?.summary.kind?.title ?? "Transaction")
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if let live, live.isEditable {
                ToolbarItem(placement: .primaryAction) {
                    Button("Edit") {
                        router.edit(live)
                    }
                }
            }
        }
        .ledgerAlert($alert)
        .onChange(of: current, initial: true) { _, details in
            if let details {
                lastShown = details
            } else if lastShown != nil, !isLeaving {
                // The transaction was deleted elsewhere while shown, for example from the editor.
                isLeaving = true
                dismiss()
            }
        }
    }

    /// The transaction, unless it has been deleted.
    private var liveTransaction: LedgerTransaction? {
        guard let match = matches.first, match.modelContext != nil, !match.isDeleted else { return nil }
        return match
    }

    private func content(_ details: TransactionDetails) -> some View {
        List {
            Section {
                TransactionDetailHeader(details: details)
                    .listRowBackground(Color.clear)
            }

            Section {
                LabeledContent("Type", value: details.summary.kind?.title ?? details.summary.title)
                LabeledContent("Amount") {
                    MoneyText(details.summary.amount, alwaysShowCentavos: true)
                }
                switch details.summary.kind {
                case .expense, .income:
                    LabeledContent(details.summary.kind == .income ? "Income Source" : "Category") {
                        NameWithArchivedTag(
                            name: details.category?.name ?? details.summary.title,
                            isArchived: details.category?.isArchived ?? false
                        )
                    }
                    accountRow("Account", account: details.account)
                case .transfer:
                    accountRow("From", account: details.account)
                    accountRow("To", account: details.destination)
                case .adjustment, nil:
                    accountRow("Account", account: details.account)
                }
                if let cashback = cashbackMatches.first {
                    LabeledContent("Cashback") {
                        MoneyText(cashback.amount, alwaysShowCentavos: true)
                    }
                }
                if let plan = plan(for: details) {
                    LabeledContent("Plan", value: "Part of a \(plan.months)-month plan")
                }
            }

            if let note = details.summary.note {
                Section("Note") {
                    Text(note)
                        .textSelection(.enabled)
                }
            }

            if let reference = details.reference {
                Section {
                    LabeledContent("Reference") {
                        Text(reference)
                            .textSelection(.enabled)
                    }
                }
            }

            Section {
                LabeledContent("Logged", value: details.createdAt.formatted(date: .abbreviated, time: .shortened))
                if details.wasEdited {
                    LabeledContent("Edited", value: details.updatedAt.formatted(date: .abbreviated, time: .shortened))
                }
                LabeledContent("Source", value: TransactionLogging.sourceDescription(details.origin))
            }

            Section {
                Button("Delete Transaction", role: .destructive) {
                    isConfirmingDeletion = true
                }
                .frame(maxWidth: .infinity)
                .confirmationDialog(
                    "Delete Transaction?",
                    isPresented: $isConfirmingDeletion,
                    titleVisibility: .visible
                ) {
                    Button("Delete Transaction", role: .destructive, action: deleteTransaction)
                } message: {
                    Text(deletionMessage(details))
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func plan(for details: TransactionDetails) -> PaymentPlan? {
        guard let planID = details.planID else { return nil }
        return plans.first { $0.id == planID }
    }

    private func deletionMessage(_ details: TransactionDetails) -> String {
        guard details.planID != nil else {
            return cashbackMatches.isEmpty
                ? "This can't be undone."
                : "Its cashback is deleted too. This can't be undone."
        }
        return details.origin == .planFees
            ? "This also deletes its plan and purchase. This can't be undone."
            : "This also deletes its plan and fees. This can't be undone."
    }

    @ViewBuilder
    private func accountRow(_ title: String, account: TransactionDetails.Reference?) -> some View {
        if let account {
            NavigationLink(value: LedgerRoute.account(account.id)) {
                LabeledContent(title) {
                    NameWithArchivedTag(name: account.name, isArchived: account.isArchived)
                }
            }
        } else {
            LabeledContent(title, value: TransactionSummary.unknownAccount)
        }
    }

    private func deleteTransaction() {
        let ledger = LedgerService(context: modelContext)
        do {
            guard let transaction = try ledger.transaction(id: transactionID) else {
                throw LedgerError.transactionNotFound
            }
            isLeaving = true
            try ledger.delete(transaction)
            dismiss()
        } catch {
            isLeaving = false
            alert = LedgerAlert(error)
        }
    }
}

/// Display values for one transaction, copied from the model so the screen never reads a
/// deleted record.
struct TransactionDetails: Equatable {
    /// An account or category the transaction refers to.
    struct Reference: Equatable {
        let id: UUID
        let name: String
        let isArchived: Bool
    }

    let summary: TransactionSummary
    let category: Reference?
    let account: Reference?
    let destination: Reference?
    let reference: String?
    let createdAt: Date
    let updatedAt: Date
    let origin: EntryOrigin
    let planID: UUID?

    /// Whether the transaction was changed after it was first saved.
    var wasEdited: Bool { updatedAt.timeIntervalSince(createdAt) >= 1 }

    @MainActor
    init(_ transaction: LedgerTransaction) {
        summary = TransactionSummary(transaction)
        category = transaction.category.map { Reference(id: $0.id, name: $0.name, isArchived: $0.isArchived) }
        account = transaction.account.map { Reference(id: $0.id, name: $0.name, isArchived: $0.isArchived) }
        destination = transaction.destinationAccount.map { Reference(id: $0.id, name: $0.name, isArchived: $0.isArchived) }
        reference = transaction.reference
        createdAt = transaction.createdAt
        updatedAt = transaction.updatedAt
        origin = transaction.origin
        planID = transaction.planID
    }
}

/// Large symbol, title, signed amount with its type, and the local date and time.
private struct TransactionDetailHeader: View {
    let details: TransactionDetails

    @Environment(\.moneyFormatter) private var formatter
    @ScaledMetric(relativeTo: .largeTitle) private var badgeSize: CGFloat = 64

    var body: some View {
        let summary = details.summary
        VStack(spacing: 12) {
            SymbolBadge(
                systemName: summary.symbolName,
                tint: LedgerTheme.badgeTint(for: summary.kind),
                size: min(badgeSize, 96)
            )
            VStack(spacing: 4) {
                Text(summary.title)
                    .font(.title3.weight(.semibold))
                LargeAmountText(summary.signedAmountText(formatter: formatter))
                    .foregroundStyle(amountColor(for: summary.kind))
                if let kind = summary.kind {
                    HStack(spacing: 4) {
                        Image(systemName: kind.systemImage)
                        Text(kind.title)
                    }
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.secondary)
                }
            }
            Text(summary.occurredAt.formatted(date: .complete, time: .shortened))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(summary.accessibilityLabel(formatter: formatter))
    }

    /// Transfers use the primary color here so the large amount stays legible; the type label and
    /// unsigned amount identify them.
    private func amountColor(for kind: TransactionKind?) -> Color {
        kind == .transfer ? .primary : LedgerTheme.amountColor(for: kind)
    }
}

#if DEBUG
#Preview("Transaction") {
    NavigationStack {
        NewestTransactionPreview { id in
            TransactionDetailView(transactionID: id)
        }
        .ledgerRouteDestinations()
    }
    .ledgerPreview()
}
#endif

#Preview("Transaction – Not Found") {
    NavigationStack {
        TransactionDetailView(transactionID: UUID())
    }
    .ledgerPreview()
}
