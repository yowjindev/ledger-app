import SwiftData
import SwiftUI

/// Onboarding step for entering what each starting account holds right now. An empty amount
/// stays "not set". Entries already logged (for example from Shortcuts before setup) are taken
/// into account, so each balance shows exactly what was entered. Accounts turned off are deleted
/// when the user continues, or archived if transactions already use them, after a confirmation.
/// Everything is saved together through `LedgerService.applySetup(_:)`.
struct OnboardingBalancesStep: View {
    /// Label of the secondary button, which leaves without saving.
    var skipTitle: LocalizedStringKey = "Skip for Now"
    let onSkip: () -> Void
    let onSaved: () -> Void

    @Environment(\.modelContext) private var modelContext
    @Query(
        filter: #Predicate<Account> { !$0.isArchived },
        sort: [SortDescriptor(\Account.sortOrder), SortDescriptor(\Account.createdAt)]
    )
    private var accounts: [Account]
    @Query private var transactions: [LedgerTransaction]
    @State private var unusedIDs: Set<UUID> = []
    /// Amounts edited on this screen. An entry holding `nil` means the field was cleared;
    /// accounts without an entry show their saved opening balance.
    @State private var entries: [UUID: Decimal?] = [:]
    @State private var isAddingAccount = false
    @State private var confirmsRemoval = false
    @State private var isSaving = false
    @State private var alert: LedgerAlert?
    @FocusState private var focusedAccountID: UUID?

    var body: some View {
        let sheet = balanceSheet
        let entryCounts = entryCountsByAccount
        Form {
            ForEach(accounts) { account in
                Section {
                    OnboardingAccountRow(
                        name: account.name,
                        kind: account.kind,
                        isUsed: usageBinding(for: account.id)
                    )
                    let entryCount = entryCounts[account.id, default: 0]
                    if unusedIDs.contains(account.id) {
                        Text(entryCount > 0
                            ? "Not used. Ledger will archive it, since it has transactions."
                            : "Not used. Ledger will remove it.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    } else {
                        AmountField(
                            "Current Balance",
                            amount: amountBinding(for: account, savedBalance: sheet.balance(for: account.id)?.currentBalance?.amount),
                            currency: account.currency,
                            accessibilityLabel: "\(account.name) current balance"
                        )
                        .focused($focusedAccountID, equals: account.id)
                        if entryCount > 0 {
                            Text(entryCount == 1
                                ? "Includes the 1 entry already logged."
                                : "Includes the \(entryCount) entries already logged.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                } header: {
                    if account.id == accounts.first?.id {
                        header
                    }
                }
            }
            Section {
                Button("Add Account", systemImage: "plus.circle") {
                    isAddingAccount = true
                }
            } header: {
                if accounts.isEmpty {
                    header
                }
            } footer: {
                Text("From now on, each balance changes only with the transactions you record. Leave an amount empty if you're not sure; Ledger won't treat it as ₱0. You can change balances anytime in Accounts.")
            }
        }
        .listSectionSpacing(.compact)
        .scrollDismissesKeyboard(.interactively)
        .scrollEdgeEffectStyle(.soft, for: .top)
        .scrollEdgeEffectStyle(.hard, for: .bottom)
        .toolbar(.hidden, for: .navigationBar)
        .safeAreaBar(edge: .bottom) {
            bottomBar
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                Spacer()
                Button("Done") {
                    focusedAccountID = nil
                }
            }
        }
        .sheet(isPresented: $isAddingAccount) {
            AccountEditorView(account: nil)
        }
        .confirmationDialog(removalTitle, isPresented: $confirmsRemoval, titleVisibility: .visible) {
            Button("Remove and Continue", role: .destructive, action: saveAndContinue)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Accounts without transactions are deleted. Accounts with transactions are archived and keep their history. You can add or unarchive accounts later in Accounts.")
        }
        .ledgerAlert($alert)
    }

    /// The title, in the content rather than the navigation bar so it can wrap at large text sizes.
    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Current Balances")
                .font(.largeTitle.bold())
                .foregroundStyle(Color.primary)
                .accessibilityAddTraits(.isHeader)
            Text("Enter what each account holds right now.")
                .font(.body)
                .foregroundStyle(Color.secondary)
        }
        .textCase(nil)
        .padding(.top, 24)
        .padding(.bottom, 12)
    }

    private var bottomBar: some View {
        VStack(spacing: 4) {
            if !hasUsedAccount {
                Text("Use at least one account to continue.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            Button(action: requestContinue) {
                ContrastingButtonTitle("Continue", fillsWidth: true)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(isSaving || !hasUsedAccount)
            Button(action: onSkip) {
                Text(skipTitle)
                    .frame(maxWidth: .infinity, minHeight: 44)
            }
            .disabled(isSaving)
        }
        .padding(.horizontal, 24)
    }

    private var hasUsedAccount: Bool {
        accounts.contains { !unusedIDs.contains($0.id) }
    }

    private var balanceSheet: BalanceSheet {
        LedgerService.balanceSheet(accounts: accounts, transactions: transactions)
    }

    /// Number of transactions that reference each account, in any role.
    private var entryCountsByAccount: [UUID: Int] {
        var counts: [UUID: Int] = [:]
        for transaction in transactions {
            for id in Set([transaction.account?.id, transaction.destinationAccount?.id].compactMap { $0 }) {
                counts[id, default: 0] += 1
            }
        }
        return counts
    }

    private var unusedAccounts: [Account] {
        accounts.filter { unusedIDs.contains($0.id) }
    }

    private var removalTitle: String {
        "Remove \(ListFormatter.localizedString(byJoining: unusedAccounts.map(\.name)))?"
    }

    private func usageBinding(for id: UUID) -> Binding<Bool> {
        Binding(
            get: { !unusedIDs.contains(id) },
            set: { isUsed in
                if isUsed {
                    unusedIDs.remove(id)
                } else {
                    unusedIDs.insert(id)
                    if focusedAccountID == id { focusedAccountID = nil }
                }
            }
        )
    }

    /// Shows what was typed here, otherwise the account's current balance if it's known.
    private func amountBinding(for account: Account, savedBalance: Decimal?) -> Binding<Decimal?> {
        let id = account.id
        return Binding(
            get: {
                if let entry = entries[id] { return entry }
                return savedBalance
            },
            set: { entries[id] = .some($0) }
        )
    }

    /// The balance shown for an account: what was typed here, otherwise its current balance.
    private func enteredBalance(for account: Account, in sheet: BalanceSheet) -> Decimal? {
        if let entry = entries[account.id] { return entry }
        return sheet.balance(for: account.id)?.currentBalance?.amount
    }

    /// Asks before removing accounts that were turned off; otherwise saves straight away.
    private func requestContinue() {
        guard !isSaving, hasUsedAccount else { return }
        focusedAccountID = nil
        if unusedAccounts.isEmpty {
            saveAndContinue()
        } else {
            confirmsRemoval = true
        }
    }

    /// Saves every choice in one step, then moves on. On failure nothing was changed and the
    /// step stays open with an alert.
    private func saveAndContinue() {
        guard !isSaving, hasUsedAccount else { return }
        isSaving = true
        focusedAccountID = nil
        let sheet = balanceSheet
        let choices = accounts.map { account in
            AccountSetupChoice(
                accountID: account.id,
                isUsed: !unusedIDs.contains(account.id),
                currentBalance: enteredBalance(for: account, in: sheet)
            )
        }
        do {
            try LedgerService(context: modelContext).applySetup(choices)
            onSaved()
        } catch {
            isSaving = false
            alert = LedgerAlert(error)
        }
    }
}

/// An account's name and kind, with the switch that decides whether to keep it.
private struct OnboardingAccountRow: View {
    let name: String
    let kind: AccountKind
    @Binding var isUsed: Bool

    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    var body: some View {
        let layout = dynamicTypeSize.isAccessibilitySize
            ? AnyLayout(VStackLayout(alignment: .leading, spacing: 10))
            : AnyLayout(HStackLayout(spacing: 12))
        layout {
            HStack(spacing: 12) {
                SymbolBadge(systemName: kind.systemImage, tint: isUsed ? .accentColor : .secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text(name)
                    Text(kind.title)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                .accessibilityElement(children: .combine)
            }
            if !dynamicTypeSize.isAccessibilitySize {
                Spacer(minLength: 8)
            }
            Toggle("Use", isOn: $isUsed)
                .fixedSize()
                .accessibilityLabel("Use \(name)")
        }
        .padding(.vertical, 2)
    }
}

#if DEBUG
#Preview {
    NavigationStack {
        OnboardingBalancesStep(onSkip: {}, onSaved: {})
    }
    .ledgerPreview(sampleData: false)
}
#endif
