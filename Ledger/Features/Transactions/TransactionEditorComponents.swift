import Foundation
import SwiftUI

/// Values being edited in the transaction editor.
struct TransactionEditorForm: Equatable, Sendable {
    var kind: TransactionKind
    /// `nil` while the amount field is empty.
    var amount: Decimal?
    var occurredAt: Date
    /// Expense: paid from. Income: deposited to. Transfer: from.
    var accountID: UUID?
    /// Transfer destination.
    var destinationAccountID: UUID?
    /// Expense category or income source.
    var categoryID: UUID?
    var note = ""
    /// Carried over unchanged from the transaction being edited; not editable here.
    var reference: String?

    init(kind: TransactionKind, occurredAt: Date, accountID: UUID? = nil) {
        self.kind = kind
        self.occurredAt = occurredAt
        self.accountID = accountID
    }

    init(_ draft: TransactionDraft) {
        kind = draft.kind
        amount = draft.amount
        occurredAt = draft.occurredAt
        accountID = draft.accountID
        destinationAccountID = draft.kind == .transfer ? draft.destinationAccountID : nil
        categoryID = draft.kind == .transfer ? nil : draft.categoryID
        note = draft.note ?? ""
        reference = draft.reference
    }

    /// A draft for `LedgerService`, or `nil` until the amount is positive and every required
    /// account and category is chosen.
    var draft: TransactionDraft? {
        guard let amount, amount > .zero, let accountID else { return nil }
        switch kind {
        case .expense, .income:
            guard let categoryID else { return nil }
            return TransactionDraft(
                kind: kind,
                amount: amount,
                occurredAt: occurredAt,
                accountID: accountID,
                categoryID: categoryID,
                note: note,
                reference: reference
            )
        case .transfer:
            guard let destinationAccountID, destinationAccountID != accountID else { return nil }
            return TransactionDraft(
                kind: .transfer,
                amount: amount,
                occurredAt: occurredAt,
                accountID: accountID,
                destinationAccountID: destinationAccountID,
                note: note,
                reference: reference
            )
        case .adjustment:
            return nil
        }
    }
}

/// An account, expense category, or income source offered by the editor.
struct EditorOption: Identifiable, Hashable {
    let id: UUID
    let name: String
    let symbolName: String
    let isArchived: Bool

    @MainActor
    init(_ account: Account) {
        id = account.id
        name = account.name
        symbolName = account.kind.systemImage
        isArchived = account.isArchived
    }

    @MainActor
    init(_ category: LedgerCategory) {
        id = category.id
        name = category.name
        symbolName = category.symbolName
        isArchived = category.isArchived
    }

    /// The name as shown in menus, which can't show a tag.
    var menuTitle: String {
        isArchived ? "\(name) (Archived)" : name
    }
}

/// Tappable grid of expense categories or income sources, in display order.
struct CategoryGrid: View {
    let options: [EditorOption]
    @Binding var selection: UUID?
    let tint: Color

    // Capped so the grid keeps several columns at accessibility text sizes.
    @ScaledMetric(relativeTo: .caption) private var scaledCellWidth: CGFloat = 74
    @ScaledMetric(relativeTo: .caption) private var scaledBadgeSize: CGFloat = 40

    private var minimumCellWidth: CGFloat { min(scaledCellWidth, 104) }
    private var badgeSize: CGFloat { min(scaledBadgeSize, 52) }

    var body: some View {
        LazyVGrid(
            columns: [GridItem(.adaptive(minimum: minimumCellWidth), spacing: 6, alignment: .top)],
            spacing: 6
        ) {
            ForEach(options) { option in
                cell(for: option)
            }
        }
        .padding(.vertical, 6)
    }

    private func cell(for option: EditorOption) -> some View {
        let isSelected = selection == option.id
        let shape = RoundedRectangle(cornerRadius: 14, style: .continuous)
        return Button {
            selection = option.id
        } label: {
            VStack(spacing: 6) {
                SymbolBadge(systemName: option.symbolName, tint: tint, size: badgeSize)
                Text(option.name)
                    .font(.caption)
                    .foregroundStyle(.primary)
                    .multilineTextAlignment(.center)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if option.isArchived {
                    ArchivedTag()
                }
            }
            .frame(maxWidth: .infinity, minHeight: 44)
            .padding(.vertical, 8)
            .padding(.horizontal, 2)
            .background(shape.fill(isSelected ? tint.opacity(0.14) : .clear))
            .overlay(shape.strokeBorder(isSelected ? tint : .clear, lineWidth: 2))
            .contentShape(shape)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(option.isArchived ? "\(option.name), Archived" : option.name)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}
