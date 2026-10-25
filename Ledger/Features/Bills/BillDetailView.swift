import SwiftData
import SwiftUI

/// One regular bill: its current due, paying it, entering this month's amount, moving this due,
/// its details, and its payments. Looks the bill up by ID, so it copes with the bill being
/// deleted elsewhere.
struct BillDetailView: View {
    let billID: UUID

    @Environment(\.modelContext) private var modelContext
    @Environment(\.dismiss) private var dismiss
    @Environment(\.calendar) private var calendar
    @Environment(\.moneyFormatter) private var formatter
    @Query private var matches: [Bill]
    @Query(sort: LedgerService.newestFirst) private var transactions: [LedgerTransaction]
    @Query private var overrides: [DueOverride]
    @State private var now = Date.now
    @State private var sheet: Sheet?
    @State private var isConfirmingDelete = false
    @State private var didDelete = false
    @State private var alert: LedgerAlert?

    private enum Sheet: Identifiable {
        case edit
        case pay(DueStatus)
        case setAmount(CalendarMonth)
        case move(DueStatus)

        var id: String {
            switch self {
            case .edit: "edit"
            case .pay: "pay"
            case .setAmount: "amount"
            case .move: "move"
            }
        }
    }

    init(billID: UUID) {
        self.billID = billID
        _matches = Query(filter: #Predicate<Bill> { $0.id == billID })
    }

    var body: some View {
        if let bill = matches.first {
            content(bill)
        } else if didDelete {
            ContentUnavailableView("Bill Deleted", systemImage: "trash")
        } else {
            ContentUnavailableView("Bill Not Found", systemImage: "questionmark.folder", description: Text("It may have been deleted."))
        }
    }

    private func content(_ bill: Bill) -> some View {
        let payments = transactions.filter { $0.billID == billID }
        let today = CalendarDay(containing: now, calendar: calendar)
        let status = DueCalculator.status(
            LedgerService.billDueInput(for: bill, payments: payments, overrides: overrides),
            today: today
        )
        return List {
            Section {
                header(bill)
            }
            if !bill.isArchived {
                dueSection(bill, status: status, today: today)
            }
            detailsSection(bill)
            paymentsSection(payments)
            actionsSection(bill, hasPayments: !payments.isEmpty)
        }
        .listStyle(.insetGrouped)
        .navigationTitle(bill.name)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button("Edit") { sheet = .edit }
            }
        }
        .refreshingCurrentDate($now)
        .sheet(item: $sheet) { sheet in
            switch sheet {
            case .edit:
                BillEditorView(bill: bill)
            case .pay(let status):
                PayBillView(bill: bill, cycle: status.cycle, suggestedAmount: status.left?.amount)
            case .setAmount(let cycle):
                SetBillAmountView(bill: bill, cycle: cycle)
            case .move(let status):
                MoveDueView(owner: .bill(bill.id), cycle: status.cycle, schedule: bill.schedule, currentDue: status.dueDate)
            }
        }
        .ledgerAlert($alert)
    }

    // MARK: Sections

    private func header(_ bill: Bill) -> some View {
        VStack(spacing: 8) {
            SymbolBadge(systemName: bill.category?.symbolName ?? "doc.text", tint: bill.isArchived ? .secondary : .accentColor, size: 52)
            Text(bill.isArchived ? "Bill · Archived" : "Bill")
                .font(.subheadline)
                .foregroundStyle(.secondary)
            if let amount = bill.amount {
                MoneyText(amount)
                    .font(.system(.largeTitle, design: .rounded, weight: .bold))
                    .lineLimit(1)
                    .minimumScaleFactor(0.5)
                    .padding(.top, 4)
                Text("Every Month")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            } else {
                Text("Amount Varies")
                    .font(.title2.weight(.semibold))
                    .padding(.top, 4)
            }
        }
        .multilineTextAlignment(.center)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }

    private func dueSection(_ bill: Bill, status: DueStatus, today: CalendarDay) -> some View {
        Section {
            LabeledContent {
                Text(DueStatusCopy.amountText(status, formatter: formatter))
                    .monospacedDigit()
            } label: {
                HStack(spacing: 4) {
                    if status.isOverdue {
                        Image(systemName: "exclamationmark.circle.fill")
                    }
                    Text(DueStatusCopy.dateText(status, today: today, calendar: calendar))
                }
                .foregroundStyle(status.isOverdue ? .red : .primary)
            }
            if !status.isPaid {
                Button("Paid", systemImage: "checkmark.circle") {
                    sheet = .pay(status)
                }
                if bill.amountMinor == nil {
                    Button(status.left == nil ? "Set This Month's Amount" : "Change This Month's Amount", systemImage: "pencil") {
                        sheet = .setAmount(status.cycle)
                    }
                }
                Button("Move This Due", systemImage: "calendar.badge.clock") {
                    sheet = .move(status)
                }
            }
        } header: {
            Text(status.isOverdue ? "Overdue" : "Current Due")
        } footer: {
            if status.dueDate != status.originalDueDate {
                Text("Moved from \(DueStatusCopy.shortDate(status.originalDueDate, calendar: calendar)) for this month only.")
            } else if status.left == nil, let arrives = bill.arrivesDay {
                Text("This bill usually arrives on \(BillsCopy.dayPhrase(arrives)).")
            }
        }
    }

    private func detailsSection(_ bill: Bill) -> some View {
        Section("Details") {
            LabeledContent("Category", value: bill.category?.name ?? "None")
            LabeledContent("Due", value: BillsCopy.dayTitle(bill.dueDay))
            if let arrives = bill.arrivesDay {
                LabeledContent("Usually Arrives", value: BillsCopy.dayTitle(arrives))
            }
            LabeledContent("Pay From", value: bill.payFrom?.name ?? "Choose each time")
        }
    }

    private func paymentsSection(_ payments: [LedgerTransaction]) -> some View {
        Section("Payments") {
            if payments.isEmpty {
                Text("No payments yet")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(HistoryItem.items(from: payments)) { item in
                    HistoryItemLink(item: item, showsDate: true)
                }
            }
        }
    }

    private func actionsSection(_ bill: Bill, hasPayments: Bool) -> some View {
        Section {
            if bill.isArchived {
                Button("Unarchive", systemImage: "tray.and.arrow.up") {
                    perform { try $0.unarchiveBill(bill) }
                }
            } else {
                Button("Archive", systemImage: "archivebox") {
                    perform { try $0.archiveBill(bill) }
                }
            }
            if !hasPayments {
                Button("Delete", systemImage: "trash", role: .destructive) {
                    isConfirmingDelete = true
                }
                .confirmationDialog("Delete \(bill.name)?", isPresented: $isConfirmingDelete, titleVisibility: .visible) {
                    Button("Delete", role: .destructive) {
                        if perform({ try $0.deleteBill(bill) }) {
                            didDelete = true
                            dismiss()
                        }
                    }
                    Button("Cancel", role: .cancel) {}
                } message: {
                    Text("This can't be undone.")
                }
            }
        } footer: {
            if hasPayments {
                Text("A bill with payments can't be deleted, only archived, so its payments stay.")
            }
        }
    }

    @discardableResult
    private func perform(_ change: (LedgerService) throws -> Void) -> Bool {
        do {
            try change(LedgerService(context: modelContext))
            return true
        } catch {
            alert = LedgerAlert(error)
            return false
        }
    }
}
