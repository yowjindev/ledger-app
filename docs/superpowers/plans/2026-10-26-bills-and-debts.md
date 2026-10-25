# Bills and Debts (Part A) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Track money the user owes (credit cards, pay later, loans) and regular bills in a new
Bills tab. Cashback, split purchases and due math are handled automatically, and Part B's
reminders can build on them.

**Architecture:**
- **Domain (pure, unit-tested):**
  - `CalendarMonth` and `DueSchedule` handle billing-cycle dates.
  - `DueCalculator` works out what's left on each due from immutable snapshots. It stores
    nothing, so any transfer counts as a payment.
- **Persistence:** schema version 3 adds the account terms, transaction links and three models
  (`PaymentPlan`, `Bill`, `DueOverride`).
- **Writes:** `LedgerService` extensions do every write (owed accounts, plans, cashback, bills)
  in one save each, with the existing rollback.
- **UI:** SwiftUI screens read with `@Query` and call the service. They reuse
  `MoneyFormatter`, `AmountField` and `LedgerAlert`.

**Tech Stack:** Swift 6.4 (Swift 6 mode, strict concurrency), SwiftUI, SwiftData, App Intents,
XCTest. iOS 26.0 deployment target, iOS 27 SDK.

**Spec:** `docs/superpowers/specs/2026-10-26-bills-debts-and-reminders-design.md` (Part A
only; Part B gets its own plan after this branch merges).

## Global Constraints

- **Platform:** deployment target iOS 26.0, iPhone only. No iOS 27-only API. No packages,
  network, analytics or third-party code.
- **Money and rates:** money is stored as `Int64` minor units and calculated as `Decimal`, and
  rates as `Rate` parts per million. Never `Double`.
- **Writes:** every financial write goes through `LedgerService` and commits before returning.
  A failed save rolls back, refreshes loaded models (add the three new model types to
  `refreshLoadedModels()`) and throws `LedgerError.persistenceFailed`.
- **Opening balances:** `nil` means not set, never zero.
- **Logging:** use `Log` (`os.Logger`). Never log amounts, balances, names, notes or references.
- **Imports:** `MemberImportVisibility` is on, so import every module a file uses (`os` for
  `Log` interpolation).
- **Files:** synchronized folders, so new files under `Ledger/` and `LedgerTests/` join their
  target automatically. Don't edit `project.pbxproj` for them.
- **Copy:** user-facing text in sentence case and plain words. Amounts go through
  `MoneyFormatter`.
- **SF Symbols:** only those available on iOS 26; `python3 scripts/check_sf_symbols.py` must
  pass.
- **Tests:** XCTest, in-memory `LedgerHarness`, made-up amounts only.
  - Time-dependent tests use `LedgerHarness(calendar: try fixedCalendar("Asia/Manila"))` and
    set `h.clock.now`. `TestClock.referenceDate` is 2026-03-15 10:00 Manila.
  - Classes using the assert helpers are `@MainActor`.
- **Builds:** zero warnings (`grep -c "warning:"` on a clean build log).
- **Commits:** subject starts with Add, Update, Fix, Implement, Remove, Refactor or Improve. At
  most 50 characters, imperative, no `feat:`-style prefixes, no `Co-Authored-By` trailer. One
  task per commit.
- **Comments** describe what the code does, never history.

Build and test commands (from `CLAUDE.md`):

```sh
xcodebuild -project Ledger.xcodeproj -scheme Ledger \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' -derivedDataPath .scratch/DerivedData test
# one class:  ... test -only-testing:LedgerTests/DueScheduleTests
```

## Review Focus

These are inputs the spec implies but no task's main tests exercise. Each line names its test
and the task that owns it.

1. **A purchase at 23:30 on the statement day** in the device's time zone belongs to the closing
   cycle, even though UTC has already moved to the next day. Test:
   `testPurchaseLateOnStatementDayInLocalTimeBelongsToClosingCycle` (Task 4).
2. **Archived owed accounts and bills** don't appear in Coming up or Total you owe, and don't
   break anything. Test: `testArchivedAccountsAndBillsLeaveComingUp` (Task 8).
3. **Deleting a loan account that has a plan but no entries** removes its plans and due
   overrides as well, so nothing is left over. Test:
   `testDeletingAnAccountRemovesItsPlansAndOverrides` (Task 5).
4. **A due day of 31 in a 30-day month**, when moving a due: the allowed range uses the clamped
   dates. Test: `testMoveRangeUsesClampedDueDates` (Task 7).
5. **Update Balance from the Ledger Menu on an owed account** with a Shortcuts amount of 0 asks
   again instead of recording "owe ₱0". Test: `testUpdateWhatYouOweTreatsZeroAsNotSupplied`
   (Task 13).

---

### Task 1: Calendar months and due schedule

**Files:**
- Create: `Ledger/Domain/CalendarMonth.swift`
- Create: `Ledger/Domain/DueSchedule.swift`
- Test: `LedgerTests/DueScheduleTests.swift`
- Also commit: `docs/superpowers/specs/2026-10-26-bills-debts-and-reminders-design.md` and
  this plan

**Interfaces:**
- Consumes: `CalendarDay` (`Ledger/Domain/CalendarDay.swift`).
- Produces:

```swift
/// A Gregorian month, stored as yyyymm (202611). Billing cycles are named by the month their
/// due date falls in.
struct CalendarMonth: Hashable, Comparable, Sendable, CustomStringConvertible {
    let year: Int
    let month: Int
    init(year: Int, month: Int)
    init(containing day: CalendarDay)
    init?(storedValue: Int)
    var storedValue: Int
    var dayCount: Int
    func adding(months: Int) -> CalendarMonth
    /// `day` clamped to 1...dayCount: day 31 in a 30-day month is the 30th.
    func day(_ day: Int) -> CalendarDay
}

/// When a statement closes and when its payment is due. Loans and bills have no statement.
struct DueSchedule: Hashable, Sendable {
    let statementDay: Int?
    let dueDay: Int
    func dueDate(in cycle: CalendarMonth) -> CalendarDay
    /// The latest statement day strictly before `dueDate(in: cycle)`; `nil` without a statement day.
    func statementClose(for cycle: CalendarMonth) -> CalendarDay?
    /// The cycle whose (unmoved) due date is the first on or after `day`.
    func cycle(dueOnOrAfter day: CalendarDay) -> CalendarMonth
    /// The cycle a purchase on `day` is billed in: its statement is the first close on or after
    /// `day` (the statement day itself is inclusive). Without a statement day: `cycle(dueOnOrAfter:)`.
    func billingCycle(for day: CalendarDay) -> CalendarMonth
}
```

- [ ] **Step 1: Write the failing tests** in `DueScheduleTests` (no harness needed):
  - `testMonthArithmeticCrossesYears`: `CalendarMonth(year: 2026, month: 12).adding(months: 1)
    == (2027, 1)`. `adding(months: -1)` from 2027-01 gives 2026-12. `storedValue` of 2026-11 is
    `202611`, and `CalendarMonth(storedValue: 202611)` round-trips. `CalendarMonth(storedValue:
    202613)` is `nil`.
  - `testDay31ClampsToMonthEnd`: `CalendarMonth(2026, 2).day(31) == CalendarDay(2026, 2, 28)`.
    `CalendarMonth(2028, 2).day(29) == CalendarDay(2028, 2, 29)`.
  - `testDueAfterStatementFallsInNextMonth`: statement 20, due 10. `dueDate(in: 2026-11) ==
    2026-11-10` and `statementClose(for: 2026-11) == 2026-10-20`.
  - `testDueLaterInSameMonth`: statement 5, due 25. `statementClose(for: 2026-11) ==
    2026-11-05`.
  - `testSameStatementAndDueDay`: both 15. `statementClose(for: 2026-11) == 2026-10-15`.
  - `testEndOfMonthStatement`: statement 31, due 5. `statementClose(for: 2026-03) ==
    2026-02-28`.
  - `testPurchaseOnStatementDayBelongsToClosingCycle`: statement 20, due 10. A purchase on
    2026-10-20 is billed in 2026-11; on 2026-10-21, in 2026-12.
  - `testCycleDueOnOrAfter`: due 10. 2026-11-10 gives 2026-11, and 2026-11-11 gives 2026-12.
  - `testLoanScheduleHasNoStatement`: `DueSchedule(statementDay: nil, dueDay: 8)`.
    `statementClose` is `nil`, and `billingCycle(for: 2026-03-15) == 2026-04`.
- [ ] **Step 2: Run them to make sure they fail**:
  `... test -only-testing:LedgerTests/DueScheduleTests` fails to compile (`CalendarMonth` not
  found).
- [ ] **Step 3: Implement** both types. All arithmetic is on Gregorian year and month integers,
  and no `Calendar` is needed. `dayCount` follows the Gregorian leap rule.
- [ ] **Step 4: Run them to make sure they pass.**
- [ ] **Step 5: Commit** the spec, this plan, and the code:
  `git commit -m "Add design and due schedule for bills and debts"`.

### Task 2: Schema version 3

**Files:**
- Create: `Ledger/Persistence/LedgerSchemaV3.swift`. It holds full copies of the V2 models
  with additions, plus `PaymentPlan`, `Bill` and `DueOverride`. `LedgerMigrationPlan` and the
  type aliases move here.
- Modify: `Ledger/Persistence/LedgerSchemaV2.swift` (remove the plan and aliases; V2 stays
  frozen otherwise).
- Modify: `Ledger/Persistence/LedgerStore.swift` (`Schema(versionedSchema: LedgerSchemaV3.self)`).
- Modify: `Ledger/Services/LedgerService.swift`: `refreshLoadedModels()` fetches the three new
  types.
- Modify: `Ledger/Persistence/ModelAccessors.swift`.
- Modify: `Ledger/Domain/LedgerKinds.swift`: `EntryOrigin` gains `.cashback` and `.planFees`.
- Test: `LedgerTests/SchemaMigrationTests.swift`.

**Interfaces:**
- Produces the stored fields. All have defaults or are optional, and the existing V2
  properties are unchanged.
  - `Account`:
    - `statementDay: Int? = nil`
    - `dueDay: Int? = nil`
    - `creditLimitMinor: Int64? = nil`
    - `cashbackRatePPM: Int64? = nil`
    - `strictReminder: Bool = true`
    - `@Relationship(deleteRule: .cascade, inverse: \PaymentPlan.account) var plans: [PaymentPlan]? = []`
    - `@Relationship(deleteRule: .nullify, inverse: \Bill.payFrom) var billsPaidFrom: [Bill]? = []`
  - `LedgerCategory`:
    `@Relationship(deleteRule: .nullify, inverse: \Bill.category) var bills: [Bill]? = []`
  - `LedgerTransaction`:
    - `sourceTransactionID: UUID? = nil` (the purchase a cashback entry belongs to)
    - `planID: UUID? = nil`
    - `billID: UUID? = nil`
    - `billCycle: Int? = nil` (yyyymm)
  - `PaymentPlan`: `id: UUID`, `title: String = ""`, `account: Account? = nil`,
    `monthlyMinor: Int64 = 0`, `lastMinor: Int64 = 0`, `months: Int = 0`,
    `paidAtStart: Int = 0`, `firstDue: Int = 0` (yyyymmdd), `createdAt: Date`,
    `purchaseID: UUID? = nil`, `feesID: UUID? = nil`.
  - `Bill`: `id`, `name = ""`, `category: LedgerCategory? = nil`, `dueDay: Int = 1`,
    `amountMinor: Int64? = nil` (`nil` = varies), `arrivesDay: Int? = nil`,
    `payFrom: Account? = nil`, `isArchived = false`, `archivedAt: Date? = nil`,
    `sortOrder = 0`, `createdAt`, `startCycle: Int = 0` (yyyymm), `strictReminder = true`.
  - `DueOverride`: `id`, `ownerID: UUID`, `cycle: Int` (yyyymm), `movedTo: Int? = nil`
    (yyyymmdd), `amountMinor: Int64? = nil`.
- Produces these accessors (in `ModelAccessors.swift`):

```swift
extension Account {
    var dueSchedule: DueSchedule?          // nil while dueDay is nil
    var creditLimit: Money?
    var cashbackRate: Rate?
}
extension PaymentPlan {
    var monthly: Money; var last: Money
    var total: Money                       // monthly × (months − 1) + last
    var firstDueDay: CalendarDay?
}
extension Bill {
    var amount: Money?
    var schedule: DueSchedule              // DueSchedule(statementDay: nil, dueDay: dueDay)
}
extension DueOverride {
    var cycleMonth: CalendarMonth?; var movedToDay: CalendarDay?
}
extension LedgerTransaction {
    /// Adjustments, automatic entries (interest, cashback, plan fees) and plan purchases aren't editable.
    var isEditable: Bool   // kind != .adjustment && ![.interest, .cashback, .planFees].contains(origin) && planID == nil
}
```

- [ ] **Step 1: Write the failing test**
  `testVersion2StoreOpensWithEveryRecordAndDefaults`. Follow
  `testVersion1StoreOpensWithEveryRecordAndDefaults`, but write the store with
  `LedgerSchemaV2`: an account with `interestRatePPM = 32_500` and a ₱250.00 Food expense.
  Then open it with `LedgerStore.makeContainer(storage: .onDisk(url))` and assert:
  - Account: `interestRatePPM == 32_500`. `statementDay`, `dueDay`, `creditLimitMinor` and
    `cashbackRatePPM` are `nil`, and `strictReminder` is `true`.
  - Expense: `sourceTransactionID`, `planID`, `billID` and `billCycle` are `nil`.
  - `fetchCount` of `PaymentPlan`, `Bill` and `DueOverride` is 0.
  - The balance is unchanged.
- [ ] **Step 2: Run it to make sure it fails** (it doesn't compile: there's no V3).
- [ ] **Step 3: Implement V3**:
  - Add `.lightweight(fromVersion: LedgerSchemaV2.self, toVersion: LedgerSchemaV3.self)` after
    the V1→V2 stage.
  - Point `schemas` at V1, V2 and V3.
  - Point the type aliases (`Account`, `LedgerCategory`, `LedgerTransaction`, `PaymentPlan`,
    `Bill`, `DueOverride`) at V3.
- [ ] **Step 4: Run the whole unit suite.** All 249 existing tests and the new one pass, and the
  V1 migration test passes through both stages.
- [ ] **Step 5: Commit**: `Add schema version 3 for bills and debts`.

### Task 3: Owed accounts

**Files:**
- Modify: `Ledger/Domain/LedgerKinds.swift` (`AccountKind`)
- Modify: `Ledger/Domain/Money.swift` (`AmountRules`)
- Modify: `Ledger/Domain/InterestTerms.swift` (`RateRules.cashbackRate`)
- Modify: `Ledger/Domain/LedgerError.swift`
- Modify: `Ledger/Services/BalanceCalculator.swift` (`AccountBalance.owed`, `BalanceSheet`
  groups)
- Modify: `Ledger/Services/LedgerService+Accounts.swift` (group guards)
- Modify: `Ledger/Services/LedgerService+Adjustments.swift` (shared signed core)
- Create: `Ledger/Services/LedgerService+Owed.swift`
- Test: `LedgerTests/OwedAccountTests.swift`

**Interfaces:**
- Consumes: `DueSchedule`, `CalendarMonth` (Task 1); the V3 fields and `DueOverride` (Task 2).
- Produces:

```swift
enum AccountKind { case cash, bank, eWallet, other, creditCard, payLater, loan }
// titles "Credit card", "Pay later", "Loan"; symbols "creditcard.fill", "cart.badge.clock",
// "doc.text.fill" (fall back to "cart.fill" if the symbol check rejects "cart.badge.clock")
extension AccountKind {
    var isOwed: Bool
    static let moneyKinds: [AccountKind]   // [.cash, .bank, .eWallet, .other]
    static let owedKinds: [AccountKind]    // [.creditCard, .payLater, .loan]
    // countsTowardLiquidTotal == !isOwed
}
extension AmountRules {
    /// An amount owed: zero or more, within `maximum`, at most two decimals. Throws `.owedNegative`.
    static func owedMinorUnits(_ amount: Decimal, currency: CurrencyCode) throws -> Int64
}
extension RateRules {
    /// Above 0% and at most 100%. Throws `.cashbackRateOutOfRange`, or `.rateTooPrecise`.
    static func cashbackRate(percent: Decimal) throws -> Rate
}
struct OwedTerms: Equatable, Sendable {
    var statementDay: Int?        // required for cards and pay later, nil for loans
    var dueDay: Int
    var creditLimit: Decimal?
    var cashbackPercent: Decimal? // cards only
}
extension AccountBalance { var owed: Money? }   // −currentBalance; negative means a credit
extension BalanceSheet {
    var moneyBalances: [AccountBalance]   // active, !kind.isOwed
    var owedBalances: [AccountBalance]    // active, kind.isOwed
    var totalOwed: Money                  // sum of `owed` over owedBalances with a known balance
}
extension LedgerService {
    /// Cards and pay later. Sets opening = −owedNow; stores `stillDue` as the DueOverride amount
    /// of `awaitingDue(for:)`'s cycle.
    func createOwedAccount(name: String, kind: AccountKind, terms: OwedTerms, owedNow: Decimal, stillDue: Decimal?) throws -> Account
    func updateOwedAccount(_ account: Account, name: String, terms: OwedTerms) throws
    /// The due a "Still due" amount refers to: the upcoming due whose statement closed before
    /// today. `nil` when no statement is waiting for payment.
    func awaitingDue(for schedule: DueSchedule) -> CalendarDay?
    func owedCorrection(toOwe owed: Decimal, for account: Account) throws -> BalanceCorrection
    @discardableResult
    func updateOwed(of account: Account, to owed: Decimal, origin: EntryOrigin = .app) throws -> BalanceCorrection
}
```

- New `LedgerError` cases and their messages:
  - `.owedNegative`: "What you owe can't be negative."
  - `.wrongAccountGroup`: "Money you have and money you owe are kept apart, so this can't be
    changed."
  - `.dayOutOfRange`: "Choose a day from 1 to 31."
  - `.statementDayRequired`: "Choose the day the statement closes."
  - `.cashbackNotOffered`: "Only credit cards can have cashback."
  - `.cashbackRateOutOfRange`: "Enter a cashback rate above 0% and up to 100%."
  - `.stillDueNotApplicable`: "No bill is waiting for payment right now. Leave this empty."

- [ ] **Step 1: Write the failing tests.** `OwedAccountTests` is `@MainActor` and uses a Manila
  harness:
  - `testOwedKindsStayOutOfTheLiquidTotal`:
    - Accounts: a bank with ₱10,000 and a card created with `owedNow: 2_500` (statement 5,
      due 25).
    - `liquidTotal().total == 10_000` and `includedAccountIDs == [bank.id]`.
    - `owedBalances.map(\.id) == [card.id]` and `totalOwed == 2_500`.
    - The card's balance is −2,500.
  - `testCardPurchaseRaisesOwedAndPaymentIsNotSpending`:
    - A card owing ₱1,000. A ₱500 Food expense on it brings `owed` to 1_500.
    - A ₱1,500 transfer from the bank to the card brings `owed` to 0.
    - `periodSummary(this month).expenses == 500`.
  - `testStillDueIsStoredForTheWaitingStatement`:
    - Now is 2026-03-15 and the card has statement 5, due 25. `awaitingDue == 2026-03-25`.
    - Creating it with `owedNow: 4_000, stillDue: 1_200` leaves one `DueOverride` with
      `cycle == 202603` and `amountMinor == 120_000`.
  - `testStillDueIsRefusedWhenNoStatementIsWaiting`: statement 20, due 10. On 2026-03-15,
    `awaitingDue` is `nil` (the March 10 due has passed). Creating with `stillDue: 100` throws
    `.stillDueNotApplicable`, and no account is saved.
  - `testOwedAmountCanBeZeroButNotNegative`: `owedNow: 0` is accepted, and its balance is 0.
    `owedNow: -1` throws `.owedNegative`.
  - `testUpdateWhatYouOweRecordsAnAdjustment`:
    - Owed 2,000. `owedCorrection(toOwe: 2_150)` is `.adjustment(Money(-150))`.
    - `updateOwed(to: 2_150)` brings `owed` to 2_150.
    - The month's income and expenses are unchanged.
  - `testOverpaymentLeavesACredit`: owed 100, then a ₱150 transfer in. `owed == -50`.
  - `testMoneyAndOwedGroupsCantBeSwapped`:
    - `createAccount(kind: .creditCard)` throws `.wrongAccountGroup`.
    - `updateAccount(bank, kind: .creditCard)` throws `.wrongAccountGroup`.
    - `balanceCorrection(toReach: 5, for: card)` throws `.wrongAccountGroup`.
    - `owedCorrection(toOwe: 5, for: bank)` throws `.wrongAccountGroup`.
    - `setInterest(_, for: card)` throws `.wrongAccountGroup`.
    - `createOwedAccount(kind: .loan, …)` throws `.wrongAccountGroup`.
  - `testTermsAreValidated`:
    - `dueDay: 0` and `dueDay: 32` throw `.dayOutOfRange`.
    - A card without a `statementDay` throws `.statementDayRequired`.
    - `cashbackPercent: 1` on pay later throws `.cashbackNotOffered`.
    - `cashbackPercent: 0` throws `.cashbackRateOutOfRange`.
    - `cashbackPercent: 2.5` stores `cashbackRatePPM == 25_000`.
  - `testFailedSaveLeavesNoOwedAccount`: `failingLedger().createOwedAccount` throws
    `.persistenceFailed`. There are no accounts and no `DueOverride`s.
- [ ] **Step 2: Run them to make sure they fail** (they don't compile).
- [ ] **Step 3: Implement.**
  - Move the body of `balanceCorrection` into a private signed
    `correction(reaching target: Decimal, for: Account)`. With no opening balance, the opening
    is `target − activity`, any sign, with magnitude at most `AmountRules.maximum`, otherwise
    `.amountTooLarge`.
  - `balanceCorrection(toReach:)` keeps today's money-account checks and throws
    `.wrongAccountGroup` for owed kinds.
  - `owedCorrection(toOwe:)` validates with `owedMinorUnits` and calls the core with
    `-owed`.
  - `updateOwed` applies the result the same way `updateBalance` does. It has no interest step.
  - `createAccount` and `updateAccount` reject owed kinds and group changes.
  - `createOwedAccount` accepts only `.creditCard` and `.payLater`; loans come from
    `createLoan` (Task 5).
  - `setInterest` and `applySetup` throw `.wrongAccountGroup` for owed kinds.
  - `awaitingDue`: let `c = schedule.cycle(dueOnOrAfter: today)`. Return `dueDate(in: c)` when
    `statementClose(for: c) < today`, else `nil`.
- [ ] **Step 4: Run them to make sure they pass, then run the whole suite.**
- [ ] **Step 5: Commit**: `Add credit card, pay later and loan accounts`.

### Task 4: Due calculator

**Files:**
- Create: `Ledger/Services/DueCalculator.swift`
- Modify: `Ledger/Services/BalanceCalculator.swift`: `Movement` gains `origin: EntryOrigin =
  .app` and `planID: UUID? = nil`, both as defaulted `init` parameters.
- Modify: `Ledger/Services/LedgerService+Balances.swift`: `Movement.init?(LedgerTransaction)`
  fills them.
- Test: `LedgerTests/DueCalculatorTests.swift`

**Interfaces:**
- Consumes: `DueSchedule`, `CalendarMonth`, `AccountBalance`, `Movement`.
- Produces:

```swift
struct PlanSlice: Hashable, Sendable { let cycle: CalendarMonth; let amountMinor: Int64 }
struct PlanSnapshot: Hashable, Sendable {
    let id: UUID; let accountID: UUID
    let monthlyMinor: Int64; let lastMinor: Int64; let months: Int; let paidAtStart: Int
    let firstDue: CalendarDay
    /// The `months − paidAtStart` unpaid slices, one per cycle from firstDue's month; the final one is `lastMinor`.
    var slices: [PlanSlice]
}
struct DueOverrideSnapshot: Hashable, Sendable {
    let ownerID: UUID; let cycle: CalendarMonth; let movedTo: CalendarDay?; let amountMinor: Int64?
}
enum DueOwner: Hashable, Sendable { case account(UUID), bill(UUID) }
struct DueStatus: Hashable, Sendable {
    let owner: DueOwner
    let cycle: CalendarMonth
    let dueDate: CalendarDay          // after any move
    let originalDueDate: CalendarDay
    let left: Money?                  // nil: amount not known (opening unset, or a varying bill without an amount)
    let isOverdue: Bool
    let isStatementClosed: Bool       // false while a card or pay later cycle is still open
    var isPaid: Bool { left?.isZero == true }
}
struct OwedDueInput: Sendable {
    let balance: AccountBalance       // this account's
    let schedule: DueSchedule
    let startedAt: Date               // Account.createdAt; dues before this day are ignored
    let plans: [PlanSnapshot]
    let movements: [Movement]         // posted movements involving this account
    let overrides: [DueOverrideSnapshot]
}
enum DueCalculator {
    static func left(in cycle: CalendarMonth, _ input: OwedDueInput, calendar: Calendar) -> Money?
    static func status(_ input: OwedDueInput, today: CalendarDay, calendar: Calendar) -> DueStatus?
    static func monthsPaid(_ plan: PlanSnapshot, _ input: OwedDueInput, today: CalendarDay, calendar: Calendar) -> Int
    static func availableCredit(limitMinor: Int64?, balance: AccountBalance) -> Money?
}
```

- **The algorithm**, which the signatures don't determine (spec "Due schedule"):
  - **`left(c)`** = `max(0, owedNow − nextCycleCharges(c) − Σ slices with cycle > c)`.
    - `nextCycleCharges(c)` counts movements whose local day (`CalendarDay(containing:
      occurredAt, calendar:)`) is after `statementClose(for: c)`. It's the sum of expenses with
      `planID == nil` and `origin != .planFees`, minus `.cashback` incomes. It's zero when
      there's no statement day.
    - **Setup exception:** when an override for `c` has `amountMinor` and
      `statementClose(for: c) < startDay ≤ dueDate(in: c)`, then `left = max(0, amount −
      transfers into the account dated on or after startedAt)`.
    - `nil` when the opening balance is unset.
  - **Effective due**: `override.movedTo ?? dueDate(in: c)`. The first eligible cycle is
    `cycle(dueOnOrAfter: startDay)`.
  - **`status`**:
    - **Upcoming**: the first cycle from `max(eligible, cycle(dueOnOrAfter: today) − 1)` whose
      effective due ≥ today.
    - **Previous**: `upcoming − 1`. If it's ≥ eligible and `left(previous) > 0`, return it with
      `isOverdue = true`. Otherwise return upcoming.
    - `isStatementClosed` = no statement day, or `statementClose(for: c) < today`.
  - **`monthsPaid`**: find the latest cycle P from eligible through upcoming with
    `left(P) == 0`. The result is `paidAtStart` + the plan's slices with cycle ≤ P, capped at
    `months`.

- [ ] **Step 1: Write the failing tests**. Pure snapshots, Manila calendar, made-up amounts:
  - `testLoanLeftIsThisMonthsSlice`:
    - A loan with schedule (nil, 8), opening −14,400, and a plan of 12 × ₱2,400 with
      `paidAtStart` 6 and `firstDue` 2026-04-08.
    - `left(2026-04) == 2_400`.
    - On 2026-03-15, `status` gives cycle 2026-04, due 2026-04-08, not overdue, statement
      closed.
  - `testEarlyAndOverPaymentCount`: the same loan plus a ₱3,000 transfer in.
    `left(2026-04) == 0` and `left(2026-05) == 1_800`.
  - `testCardLeftExcludesNextCycleCharges`:
    - A card with statement 5, due 25, started 2026-02-01, opening 0.
    - Expenses: ₱1,000 on 2026-03-02 and ₱400 on 2026-03-10.
    - `left(2026-03) == 1_000`.
  - `testCashbackOnNextCycleChargesIsNetted`: add a ₱4.00 `.cashback` income on 2026-03-10.
    `left(2026-03)` is still 1_000, and `owedNow` is 1_396.
  - `testUnpaidDueBecomesOverdueAndCarries`: today is 2026-03-26.
    - `status`: cycle 2026-03, overdue, left 1_000.
    - `left(2026-04) == 1_396`.
  - `testDuesBeforeTheStartAreIgnored`: started 2026-03-26. `status` is cycle 2026-04 and not
    overdue.
  - `testStillDueCoversTheFirstDue`:
    - Started 2026-03-10, opening −5,000, override `(2026-03, 120_000)`.
    - `left(2026-03) == 1_200`.
    - After a ₱1,200 transfer on 2026-03-12, it's 0, and `left(2026-04) == 3_800`.
  - `testPayLaterSplitSlicesStayOutOfTheCurrentDue`:
    - Pay later with statement 31, due 5.
    - A plan of 3 × ₱1,050 with first due 2026-04-05, whose plan expenses are ₱3,000 and ₱150
      fees on 2026-03-10.
    - A ₱500 one-time expense on 2026-03-12.
    - `left(2026-04) == 1_550`. After a ₱1,550 payment, `left(2026-05) == 1_050`.
  - `testMonthsPaidDoesNotShareOnePaymentBetweenPlans`:
    - Two plans of 2 × ₱500 each, first due 2026-04-05, on one pay later.
    - After a ₱1,000 payment, `monthsPaid` is 1 for each.
  - `testMovedDueIsNotOverdueUntilTheNewDate`:
    - An override moves 2026-03 to 2026-03-30, and today is 2026-03-27.
    - `status` is not overdue, with `dueDate` 2026-03-30 and `originalDueDate` 2026-03-25.
  - `testPurchaseLateOnStatementDayInLocalTimeBelongsToClosingCycle` (Review Focus 1):
    - Statement 5, due 25.
    - A ₱300 expense at 2026-03-05 23:30 Manila is 15:30 UTC on the same day, so use the
      Manila calendar. A ₱200 expense at 2026-03-06 00:30 Manila is still March 5 in UTC.
    - `left(2026-03) == 300`, so the ₱200 belongs to the next cycle.
  - `testAvailableCredit`: limit 10,000 and owed 2,500 give 7_500. A `nil` limit gives `nil`.
  - `testUnsetOpeningHasNoAmount`: opening `nil` gives `left == nil` and `status?.left == nil`.
- [ ] **Step 2: Run them to make sure they fail.**
- [ ] **Step 3: Implement** `Movement`'s new fields and `DueCalculator`.
- [ ] **Step 4: Run them to make sure they pass, then run the whole suite.**
- [ ] **Step 5: Commit**: `Add due calculator for owed accounts`.

### Task 5: Payment plans

**Files:**
- Create: `Ledger/Services/LedgerService+Plans.swift`
- Modify: `Ledger/Services/LedgerService+Transactions.swift`: `delete(_:)` on an entry with a
  `planID` deletes the whole plan.
- Modify: `Ledger/Services/LedgerService+Accounts.swift`: `deleteAccount` also deletes its
  `DueOverride`s (plans cascade).
- Modify: `Ledger/Domain/LedgerError.swift`
- Create: `Ledger/Services/LedgerService+Dues.swift`, with only the model-to-snapshot helpers
  for now.
- Test: `LedgerTests/PaymentPlanTests.swift`

**Interfaces:**
- Consumes: `DueCalculator`, `PlanSnapshot`, `OwedDueInput` (Task 4); `awaitingDue` (Task 3).
- Produces:

```swift
struct SplitPurchase: Equatable, Sendable {
    var amount: Decimal; var accountID: UUID; var categoryID: UUID; var occurredAt: Date
    var note: String?; var months: Int; var monthly: Decimal; var last: Decimal?   // nil: same as monthly
}
struct PlanTerms: Equatable, Sendable {
    var title: String; var monthly: Decimal; var last: Decimal?; var months: Int
    var paidAtStart: Int; var nextDue: CalendarDay
}
struct LoanPurchase: Equatable, Sendable { var price: Decimal; var categoryID: UUID; var occurredAt: Date }
extension LedgerService {
    static let splitMonths = 2...60
    static let loanMonths = 1...60
    /// One save: the purchase (planID), a `.planFees` expense when fees > 0 (planID, category nil),
    /// and the plan. First slice: `dueDate(in: billingCycle(for: purchase day))`.
    @discardableResult func recordSplitPurchase(_ split: SplitPurchase, origin: EntryOrigin = .app) throws -> PaymentPlan
    /// Pay later only; records no entries.
    @discardableResult func addExistingPlan(_ terms: PlanTerms, to account: Account) throws -> PaymentPlan
    /// A loan account (dueDay = terms.nextDue.day, no statement) and its plan. Without a purchase
    /// the opening balance is −(remaining slices); with one it is 0 and the purchase and fees are
    /// recorded, which requires paidAtStart == 0.
    @discardableResult func createLoan(name: String, terms: PlanTerms, purchase: LoanPurchase?) throws -> Account
    func plans(for account: Account) throws -> [PaymentPlan]
    func deletePlan(_ plan: PaymentPlan) throws
    func monthsPaid(_ plan: PaymentPlan) throws -> Int
    // LedgerService+Dues.swift
    func owedDueInput(for account: Account) throws -> OwedDueInput?   // nil without a dueSchedule
    func dueStatus(for account: Account) throws -> DueStatus?
}
extension PlanSnapshot { @MainActor init?(_ plan: PaymentPlan) }
extension DueOverrideSnapshot { @MainActor init?(_ override: DueOverride) }
```

- New `LedgerError` cases and their messages:
  - `.splitNotOffered`: "Only pay later purchases can be split."
  - `.planMonthsOutOfRange(range: ClosedRange<Int>)`: "Choose from \(lower) to \(upper) months."
  - `.planTotalBelowPrice`: "The payments add up to less than the price. Check the monthly
    amount."
  - `.paidMonthsOutOfRange`: "Months paid must be fewer than the total months."
  - `.dueDateNotOnSchedule`: "Choose one of this account's due dates."

- [ ] **Step 1: Write the failing tests.** `PaymentPlanTests` uses a Manila harness with now
  2026-03-15. The pay later account has statement 31 and due 5:
  - `testSplitRecordsPriceFeesAndPlanInOneSave`: split ₱3,000 Shopping into 3 × ₱1,050. Then:
    - There are 2 transactions. The purchase is 3_000, category Shopping, with `planID` set.
    - The fees entry is 150, `origin == .planFees`, category `nil`.
    - The plan's `firstDue` is 2026-04-05 and its `total` is 3_150.
    - `owed == 3_150`, and the month's expenses are 3_150.
  - `testUnevenLastSlice`: ₱1,000 in 3, monthly 333.33, last 333.34. Then:
    - There is no fees entry.
    - `PlanSnapshot.slices.map(\.amountMinor) == [33_333, 33_333, 33_334]`.
  - `testPlanBelowPriceIsRefused`: ₱3,000 in 3 × ₱900 throws `.planTotalBelowPrice`. There are
    0 transactions and 0 plans.
  - `testSplitOnlyOnPayLater`: a split on a card throws `.splitNotOffered`. 1 month throws
    `.planMonthsOutOfRange(range: 2...60)`.
  - `testExistingPlanCreatesNoEntries`: 6 × ₱500, `paidAtStart` 2, next due 2026-04-05. Then:
    - There are 0 transactions.
    - There are 4 slices.
    - `owed` is unchanged.
  - `testExistingPlanDueMustBeOnSchedule`: next due 2026-04-06 throws `.dueDateNotOnSchedule`.
  - `testLoanPartwaySetsOpeningFromRemainingSlices`: `createLoan("Phone loan", 12 × ₱2,400,
    paidAtStart 6, next 2026-04-08, purchase nil)`. Then:
    - `openingBalanceMinor == -1_440_000`.
    - `dueDay == 8` and `statementDay == nil`.
    - `monthsPaid == 6`.
  - `testNewLoanRecordsItemAndFees`: price ₱25,000 Gadgets, 12 × ₱2,400. Then:
    - There's an expense of 25_000 and fees of 3_800.
    - `owed == 28_800` and the opening balance is 0.
    - Adding `paidAtStart: 1` with a purchase throws `.paidMonthsOutOfRange`.
  - `testMonthsPaidAfterAPayment`: on the partway loan, a ₱2,400 transfer in makes
    `monthsPaid == 7`.
  - `testDeletingAPlanEntryDeletesThePlan`: `delete(purchase)` removes the plan and both
    entries, and `owed == 0`.
  - `testPlanEntriesAreNotEditable`: `purchase.isEditable` is `false`, and
    `update(purchase, …)` throws `.entryNotEditable`.
  - `testDeletingAnAccountRemovesItsPlansAndOverrides` (Review Focus 3): a partway loan (no
    entries) plus a `DueOverride` for it. After `deleteAccount`, there are 0 plans and 0
    overrides.
  - `testFailedSplitSavesNothing`: the failing ledger throws `.persistenceFailed`, leaving 0
    transactions and 0 plans.
- [ ] **Step 2: Run them to make sure they fail.**
- [ ] **Step 3: Implement.** Validate everything before inserting anything. Use one
  `commit()`. Plan amounts go through `AmountRules.transactionMinorUnits`.
- [ ] **Step 4: Run them to make sure they pass, then run the whole suite.**
- [ ] **Step 5: Commit**: `Add payment plans for splits and loans`.

### Task 6: Cashback

**Files:**
- Create: `Ledger/Services/CashbackCalculator.swift`
- Modify: `Ledger/Services/LedgerService+Transactions.swift`: `record`, `update` and `delete`
  keep cashback in the same save.
- Test: `LedgerTests/CashbackTests.swift`

**Interfaces:**
- Consumes: `Account.cashbackRate` (Task 2), `EntryOrigin.cashback`.
- Produces:

```swift
enum CashbackCalculator {
    /// purchase × rate, rounded down to the minor unit.
    static func cashbackMinor(forPurchaseMinor purchase: Int64, rate: Rate) -> Int64
}
extension LedgerService {
    func cashback(for purchase: LedgerTransaction) throws -> LedgerTransaction?   // by sourceTransactionID
}
```

- **Rules:**
  - **Gets cashback:** an expense on a `.creditCard` with `cashbackRatePPM`, recorded with
    origin `.app` or `.appIntent`, with no `planID`, when the result is > 0. Its cashback entry
    is:
    - an `income`, `origin .cashback`, category `nil`, the same `occurredAt` as the purchase
    - `basisMinor` = purchase, `basisRatePPM` = the rate, `sourceTransactionID` = the purchase's
      ID
  - **`update`:**
    - Same card: recalculate the amount at the cashback entry's own `basisRatePPM`. If the
      result is 0, delete the entry.
    - Moved off the card: delete the entry.
    - Moved onto a cashback card with no entry yet: add one at that card's current rate.
    - Changed to a non-expense kind: delete the entry.
  - **`delete(purchase)`** deletes its cashback. Deleting the cashback entry on its own is
    allowed.

- [ ] **Step 1: Write the failing tests.** `CashbackTests` uses a card at 1%:
  - `testCashbackRoundsDown`: `cashbackMinor(12_345, 1%) == 123`, and `cashbackMinor(49, 2%)
    == 0`.
  - `testPurchaseRecordsCashbackInTheSameSave`: a ₱500 expense gives 2 transactions. The
    cashback is 500 minor units (₱5.00), `.cashback`, with `basisMinor` 50_000, `basisRatePPM`
    10_000, `sourceTransactionID` equal to the purchase's ID, and the same `occurredAt`.
    `owed == 495`.
  - `testEditRecalculatesAtTheRateItWasLoggedAt`: set the card to 2% after logging, then edit
    the purchase to ₱800. The cashback is ₱8.00.
  - `testMovingThePurchaseOffTheCardRemovesCashback` and
    `testMovingThePurchaseOntoACashbackCardAddsIt`, the second at the current rate.
  - `testDeletingThePurchaseDeletesItsCashback`.
  - `testNoCashbackOnTransfersIncomeOrTinyPurchases`: a transfer into the card, a Refund
    income, and a ₱0.49 purchase at 2% record no cashback entries.
  - `testCashbackIsNotEditable`: `cashbackEntry.isEditable` is `false`.
  - `testIntentPurchasesGetCashbackToo`: `record(draft, origin: .appIntent)` adds cashback.
  - `testFailedSaveKeepsPurchaseAndCashbackTogether`:
    - A failing `record` saves 0 transactions.
    - A failing `update` to ₱800 leaves the purchase at 500 and the cashback at 5.00.
- [ ] **Step 2: Run them to make sure they fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run them to make sure they pass, then run the whole suite.** The 12 required
  `LedgerServiceTests` cases must still pass.
- [ ] **Step 5: Commit**: `Add cashback on credit card purchases`.

### Task 7: Regular bills and moving a due

**Files:**
- Create: `Ledger/Services/LedgerService+Bills.swift`
- Modify: `Ledger/Services/DueCalculator.swift` (bill status)
- Modify: `Ledger/Services/LedgerService+Dues.swift` (`moveDue`, bill snapshots)
- Modify: `Ledger/Domain/LedgerError.swift`
- Test: `LedgerTests/BillTests.swift`

**Interfaces:**
- Consumes: `DueSchedule`, `DueStatus`, `DueOverrideSnapshot`.
- Produces:

```swift
struct BillTerms: Equatable, Sendable {
    var name: String; var categoryID: UUID; var dueDay: Int
    var amount: Decimal?          // nil: varies
    var arrivesDay: Int?          // varying bills only
    var payFromAccountID: UUID?
}
struct BillDueInput: Sendable {
    let billID: UUID; let schedule: DueSchedule; let startCycle: CalendarMonth
    let amountMinor: Int64?; let paidByCycle: [CalendarMonth: Int64]; let overrides: [DueOverrideSnapshot]
}
extension DueCalculator {
    /// Bills aren't cumulative: each cycle's left = (override amount ?? bill amount) − its tagged payments.
    /// Upcoming and previous cycles are picked as for owed accounts.
    static func status(_ input: BillDueInput, today: CalendarDay) -> DueStatus
}
extension LedgerService {
    func bills(includeArchived: Bool = false) throws -> [Bill]
    @discardableResult func createBill(_ terms: BillTerms) throws -> Bill   // startCycle = cycle(dueOnOrAfter: today)
    func updateBill(_ bill: Bill, with terms: BillTerms) throws
    func archiveBill(_ bill: Bill) throws
    func unarchiveBill(_ bill: Bill) throws
    func deleteBill(_ bill: Bill) throws             // only without payments
    func setAmount(_ amount: Decimal, for bill: Bill, cycle: CalendarMonth) throws
    @discardableResult func payBill(_ bill: Bill, cycle: CalendarMonth, amount: Decimal, from accountID: UUID,
                                    occurredAt: Date, origin: EntryOrigin = .app) throws -> LedgerTransaction
    /// Bills and owed accounts. Allowed from today up to the day before the next cycle's due date.
    func moveDue(of owner: DueOwner, cycle: CalendarMonth, to day: CalendarDay) throws
    func dueStatus(for bill: Bill) throws -> DueStatus
}
```

- New `LedgerError` cases and their messages:
  - `.billHasPayments(name:)`: "\(name) has payments, so it can't be deleted. Archive it
    instead."
  - `.arrivalDayNotApplicable`: "Only bills whose amount varies have an arrival day."
  - `.moveDateOutOfRange`: "Choose a date from today up to the day before next month's due
    date."
- `payBill` records an `expense` in the bill's category, with `billID` and `billCycle`. It goes
  through `resolve` (so the usual validation applies) and saves once. Names are unique among
  bills. `setAmount` and `moveDue` update or insert one `DueOverride` per (owner, cycle) and keep
  its other field.

- [ ] **Step 1: Write the failing tests.** `BillTests` uses a Manila harness with now
  2026-03-15, and a Rent category:
  - `testFixedBillIsDueThenPaid`: Rent ₱8,000, due 25.
    - Status: cycle 2026-03, due 2026-03-25, left 8_000.
    - `payBill(8_000 from bank)` marks it paid. The expense has category Rent, `billID`, and
      `billCycle == 202603`. The bank's balance falls by 8,000.
  - `testVaryingBillHasNoAmountUntilEntered`: Electricity, due 30, arrives 19. `left == nil`.
    After `setAmount(2_350, cycle 2026-03)`, `left == 2_350`.
  - `testPartialPaymentLeavesTheRest`: pay ₱5,000 of ₱8,000. `left == 3_000`.
  - `testDeletingThePaymentMakesItUnpaid`.
  - `testUnpaidBillBecomesOverdue`: today 2026-03-26. Cycle 2026-03, overdue, left 8_000.
  - `testMoveThisDueOnlyMovesThisMonth`: move 2026-03 to 2026-03-30. Status due 2026-03-30.
    The `DueCalculator` due for 2026-04 is still 2026-04-25.
  - `testMoveOutOfRangeIsRefused`: 2026-03-14 (before today) and 2026-04-25 (the next due)
    throw `.moveDateOutOfRange`.
  - `testMoveRangeUsesClampedDueDates` (Review Focus 4): a bill due on the 31st, today
    2026-03-31. Moving to 2026-04-29 is allowed. Moving to 2026-04-30, the clamped April due,
    throws.
  - `testBillsStartAtTheFirstUpcomingDue`: created 2026-03-26 with due 25 gives
    `startCycle == 202604`.
  - `testArrivalDayOnlyForVaryingBills`: a fixed amount with `arrivesDay` throws
    `.arrivalDayNotApplicable`. Day 32 throws `.dayOutOfRange`.
  - `testBillWithPaymentsCantBeDeleted`: throws `.billHasPayments(name: "Rent")`.
  - `testFailedPaymentRecordsNothing`.
- [ ] **Step 2: Run them to make sure they fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run them to make sure they pass, then run the whole suite.**
- [ ] **Step 5: Commit**: `Add regular bills and moving a due date`.

### Task 8: Coming up and total owed

**Files:**
- Modify: `Ledger/Services/LedgerService+Dues.swift`
- Create: `Ledger/Formatting/DueStatusCopy.swift`
- Test: `LedgerTests/ComingUpTests.swift`, `LedgerTests/DueStatusCopyTests.swift`

**Interfaces:**
- Produces:

```swift
extension LedgerService {
    /// Active owed accounts with a due schedule, and active bills: overdue first, then unpaid by
    /// due date, then paid by due date; ties by name.
    func comingUp() throws -> [DueStatus]
    static func comingUp(accounts: [Account], transactions: [LedgerTransaction], plans: [PaymentPlan],
                         bills: [Bill], overrides: [DueOverride], today: CalendarDay, calendar: Calendar) -> [DueStatus]
    func totalOwed() throws -> Money
}
enum DueStatusCopy {
    /// "₱1,050.00 left", "Paid", "Amount not set", "₱3,980.00 so far" (statement still open).
    static func amountText(_ status: DueStatus, formatter: MoneyFormatter) -> String
    /// "Due today", "Due tomorrow", "Due Nov 5", "1 day overdue", "3 days overdue".
    static func dateText(_ status: DueStatus, today: CalendarDay, calendar: Calendar) -> String
}
```

- [ ] **Step 1: Write the failing tests:**
  - `testComingUpOrdersOverdueThenUnpaidThenPaid`: on 2026-03-26, a set with:
    - an overdue bill
    - a loan due 2026-04-08
    - a paid card due 2026-04-05
    - a pay later due 2026-04-05

    The order is overdue bill, pay later, loan, then paid card.
  - `testArchivedAccountsAndBillsLeaveComingUp` (Review Focus 2): after archiving the loan and
    the bill, neither is in `comingUp()`, and `totalOwed()` leaves the loan out.
  - `testTotalOwedCountsKnownOwedBalancesOnly`: ₱2,500 + ₱640, plus a pay later with ₱100
    credit, gives 3_040.
  - `DueStatusCopyTests`: each string above for fixed statuses. A status with an open statement
    says "so far".
- [ ] **Step 2: Run them to make sure they fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run them to make sure they pass.**
- [ ] **Step 5: Commit**: `Add coming up dues and total owed`.

### Task 9: Bills tab and owed account screens

**Files:**
- Modify: `Ledger/App/AppLaunchConfiguration.swift`: `AppTab.bills`, so `-LedgerInitialTab
  bills` works.
- Modify: `Ledger/App/RootView.swift`: `Tab("Bills", systemImage: "calendar", value: .bills)`
  between Accounts and Settings.
- Modify: `Ledger/Components/AppRouter.swift`:
  - `LedgerRoute.bill(UUID)`.
  - `.account(id)` shows `OwedAccountDetailView` when the account is owed.
- Modify: `Ledger/Features/Accounts/AccountsView.swift`: the Active section lists
  `moneyBalances` only, and the Archived section lists money kinds only.
- Modify: `Ledger/Features/Onboarding/OnboardingBalancesStep.swift`: list money kinds only.
  Its `applySetup` would refuse owed accounts.
- Modify: `Ledger/Features/Accounts/AccountEditorView.swift`: the type picker offers
  `AccountKind.moneyKinds`.
- Create: `Ledger/Features/Bills/BillsView.swift`:
  - Coming up
  - the Credit cards, Pay later and Loans groups (and Bills, filled in Task 11)
  - Total you owe
  - an Add menu: Credit card, Pay later, Loan, Bill
  - an Archived section (owed accounts now, bills from Task 11) that opens each item so it can
    be unarchived
- Create: `Ledger/Features/Bills/DueStatusRow.swift`
- Create: `Ledger/Features/Bills/OwedAccountEditorView.swift`:
  - name, statement day (pay later defaults to 31, shown as "Last day of the month"), due day,
    limit, and cashback % on cards
  - on create only: **Total you owe now** and **Still due on <date>**, the second shown only
    when `awaitingDue` isn't `nil`
- Create: `Ledger/Features/Bills/OwedAccountDetailView.swift`:
  - owed (or credit), limit, available
  - this period's spending
  - current due with `DueStatusCopy`
  - recent entries via `HistoryItemLink`
  - **Pay**, **Update what you owe**, Edit, Archive
- Create: `Ledger/Features/Bills/PayDueView.swift`: a from-account picker (`moneyBalances`), an
  amount prefilled with `left`, and a date. It records a transfer through `record(_:)`.
- Create: `Ledger/Features/Bills/UpdateOwedView.swift`, modeled on `UpdateBalanceView` and
  using `owedCorrection` / `updateOwed`.
- Modify: `.scratch/TempScreensUITests.swift` (local, never committed): add `testBillsScreens`.

**Interfaces:**
- Consumes: `createOwedAccount`, `updateOwedAccount`, `awaitingDue`, `owedCorrection`,
  `updateOwed` (Task 3); `comingUp`, `totalOwed`, `DueStatusCopy` (Task 8); `dueStatus(for:)`
  (Task 5).
- Produces: `BillsView`, `OwedAccountDetailView(accountID: UUID)`,
  `PayDueView(accountID: UUID)`. Later tasks add sections to these.

- [ ] **Step 1: Build.** It must compile with zero new warnings, and the whole unit suite must
  pass.
- [ ] **Step 2: Add sample data.** In Debug-only `Support/SampleData.swift`, add a "Visa card"
  (statement 5, due 25, limit ₱20,000, 1% cashback, owed ₱2,400, with two purchases) and a
  "PayLater" account (statement 31, due 5, limit ₱8,000, owed ₱1,500). Use made-up amounts, and
  skip either one if its name exists.
- [ ] **Step 3: Screenshots.** Run `.scratch/run_shots.sh light testBillsScreens` and
  `… dark testBillsScreens`. The test launches with `-LedgerInitialTab bills` and opens the
  card, the pay later and the Add menu. Look at every screenshot: owed amounts, Coming up order,
  no clipped text, and correct dark mode.
- [ ] **Step 4: Check symbols.** `python3 scripts/check_sf_symbols.py` passes.
- [ ] **Step 5: Commit**: `Add Bills tab and owed account screens`.

### Task 10: Splits and loans in the app

**Files:**
- Create: `Ledger/Features/Bills/SplitPlanSection.swift`: in `TransactionEditorView`, for a new
  expense on a pay later account, a **Split into months** toggle with months (2–60), the monthly
  amount, and an optional different last payment.
- Modify: `Ledger/Features/Transactions/TransactionEditorView.swift`: when splitting, Save calls
  `recordSplitPurchase`.
- Create: `Ledger/Features/Bills/ExistingPlanView.swift` (pay later screen, "Add a split you're
  already paying"):
  - title, monthly, last, months, months paid
  - next due, chosen from the account's next 12 due dates
- Create: `Ledger/Features/Bills/LoanEditorView.swift`:
  - name, item title, monthly, last, months, next due date
  - a "New loan" / "Already paying" choice: price and category for new, months paid for
    already paying
- Create: `Ledger/Features/Bills/PlanRow.swift`: "3 of 6 paid", the finish month ("Last
  payment Aug 2026"), and Delete plan with a confirmation that says it removes the plan's
  entries.
- Create: `Ledger/Formatting/PlanCopy.swift`
- Modify: `OwedAccountDetailView`: a Plans section.
- Test: `LedgerTests/PlanCopyTests.swift`

**Interfaces:**
- Consumes: `recordSplitPurchase`, `addExistingPlan`, `createLoan`, `deletePlan`, `monthsPaid`,
  `plans(for:)` (Task 5).
- Produces:
  `PlanCopy.progress(paid: Int, months: Int) -> String` ("3 of 6 paid", "Paid off") and
  `PlanCopy.finish(_ last: CalendarMonth) -> String` ("Last payment Aug 2026").

- [ ] **Step 1: Write the failing `PlanCopyTests`**: `progress(3, 6) == "3 of 6 paid"`,
  `progress(6, 6) == "Paid off"`, and `finish(2026-08) == "Last payment Aug 2026"`.
- [ ] **Step 2: Run them to make sure they fail, implement `PlanCopy`, and run them to make
  sure they pass.**
- [ ] **Step 3: Build the views.** Add a "Phone loan" to sample data: 12 × ₱2,400, 6 paid.
- [ ] **Step 4: Screenshots.** In `.scratch/TempScreensUITests.swift`, add `testPlanScreens`,
  which taps keys and never calls `typeText`. Run it light and dark and look at every
  screenshot: the split section in the expense editor, the loan editor, plan rows.
- [ ] **Step 5: Commit**: `Add splits and loans to the app`.

### Task 11: Bill screens

**Files:**
- Create: `Ledger/Features/Bills/BillEditorView.swift`:
  - name, expense category, due day
  - a "Fixed" / "Varies" choice, with an amount for fixed and an arrival day for varies
  - pay from
- Create: `Ledger/Features/Bills/BillDetailView.swift`:
  - the current due with `DueStatusCopy`
  - **Set this month's amount** (varying bills)
  - **Paid**: `PayBillView`, which asks for the amount first when none is set
  - **Move this due**: a date picker limited to the range `moveDue` accepts
  - the payment history, filtered to the bill's `billID`
  - Edit, Archive, Delete
- Create: `Ledger/Features/Bills/PayBillView.swift`: a from-account picker (defaults to
  `payFrom`), the amount (prefilled with what's left), and a date. It calls `payBill`.
- Create: `Ledger/Features/Bills/MoveDueView.swift`, shared with `OwedAccountDetailView`
  (which gets **Move this due** too).
- Modify: `BillsView`: the Bills group. `AppRouter`: `.bill(id)` → `BillDetailView`.

**Interfaces:**
- Consumes: Task 7's bill API and `moveDue(of:cycle:to:)`; Task 8's copy.
- Produces: `BillDetailView(billID: UUID)`, `MoveDueView(owner: DueOwner, cycle: CalendarMonth)`.

- [ ] **Step 1: Build.** It compiles and the unit suite passes.
- [ ] **Step 2: Add sample data** "Rent" (₱8,000, due 25) and "Electricity" (varies, due 30,
  arrives 19).
- [ ] **Step 3: Screenshots.** Add `testBillScreens` (taps keys only) and run it light and dark.
  Look at every screenshot: the bill detail fixed and varying, Paid, Move this due.
- [ ] **Step 4: Commit**: `Add regular bill screens`.

### Task 12: Overview, Activity rows and labels

**Files:**
- Modify: `Ledger/Features/Dashboard/DashboardView.swift`:
  - the Accounts section uses `moneyBalances`
  - a new Bills section shows **You owe** (`totalOwed`) and **Next due**: the first `comingUp()`
    item, with `DueStatusCopy`
  - tapping the section selects the Bills tab
  - it's hidden when there are no owed accounts and no bills
- Modify: `Ledger/Formatting/HistoryItem.swift`:
  - `case transaction(LedgerTransaction, cashback: LedgerTransaction?)`
  - `items(from:)` pairs each `.cashback` entry with its purchase when both are in the list; a
    cashback without its purchase stays a row
  - update the two `case .transaction` matches (`TransactionListView.swift:38`,
    `InterestPostingRow.swift:38`)
- Modify: `Ledger/Components/TransactionRow.swift`: a secondary "₱5.00 back" line when paired.
- Modify: `Ledger/Formatting/TransactionSummary.swift`: titles `cashbackTitle = "Cashback"` and
  `planFeesTitle = "Fees and interest"`, the way interest is handled at lines 43–45.
- Modify: `Ledger/Features/Transactions/TransactionDetailView.swift`:
  - a cashback row on card purchases
  - a "Part of a 3-month plan" row on plan entries
  - delete confirmation copy for plan entries: "Deleting this also deletes its plan and fees."
- Test: `LedgerTests/CashbackHistoryTests.swift`, plus extend `TransactionSummary` tests.

**Interfaces:**
- Consumes: `comingUp`, `totalOwed`, `DueStatusCopy`, `cashback(for:)`.

- [ ] **Step 1: Write the failing tests:**
  - `testCashbackJoinsItsPurchaseRow`: [purchase, cashback] becomes one `.transaction(purchase,
    cashback: cashback)`.
  - `testCashbackWithoutItsPurchaseStaysARow`: [cashback] alone becomes one row, with the
    summary title "Cashback".
  - `testPlanFeesAreLabelled`: the summary title is "Fees and interest".
- [ ] **Step 2: Run them to make sure they fail, implement, and run them to make sure they
  pass. Then run the whole suite.**
- [ ] **Step 3: Screenshots.** Use `scripts/screenshot.sh` with sample data on `dashboard` and
  `transactions`, light and dark. Look at them: the You owe line, the next due, the "back" line,
  and no owed accounts in Overview's Accounts section.
- [ ] **Step 4: Commit**: `Add debts, cashback and fees to lists`.

### Task 13: Ledger Menu for owed accounts

**Files:**
- Modify: `Ledger/Intents/IntentFlows.swift`:
  - `updateBalance`: when the target `kind.isOwed`:
    - The prompt is "What do you owe on \(name)?" through `resolveAmount`, so 0 means not
      supplied.
    - It uses `owedCorrection` and `updateOwed`.
    - Confirmation: "Change what you owe on \(name) to \(owed)?"
    - The result's headline is "Updated what you owe", with a row "\(name) · You owe" and the
      amount.
  - `balances`: rows for `moneyBalances` only, then a "You owe" row (`totalOwed`) and a "Next
    due" row (title "Next due", subtitle "\(name) · \(dateText)", value `amountText`). Each is
    added only when there's something to show. The headline is unchanged.
- Test: `LedgerTests/IntentFlowTests.swift`

**Interfaces:**
- Consumes: Task 3 and Task 8 APIs. No new `@Parameter`, so `parameterSummary` is unchanged.

- [ ] **Step 1: Write the failing tests:**
  - `testUpdateWhatYouOweAsksAndConfirms`:
    - A card owing ₱2,000. The scripted account is the card and the amount is 2150.
    - The prompt text is "What do you owe on Visa card?".
    - One confirmation contains "Change what you owe".
    - `owed == 2_150`, and the adjustment's origin is `.appIntent`.
  - `testUpdateWhatYouOweTreatsZeroAsNotSupplied` (Review Focus 5): a preset amount of 0
    prompts for the amount.
  - `testCheckBalancesListsMoneyAccountsThenOwedAndNextDue`:
    - A bank, a card owing ₱2,500 due 2026-03-25, and today 2026-03-15.
    - The row titles are `["Bank", "You owe", "Next due"]`.
    - The "You owe" value contains "2,500".
    - The headline total excludes the card.
  - Extend `testCheckingBalancesChangesNothing` to include an owed account.
- [ ] **Step 2: Run them to make sure they fail, implement, and run them to make sure they
  pass. Then run the whole suite.**
- [ ] **Step 3: Run the UI check.** Run `test03_CheckBalances` light and dark per `CLAUDE.md`
  and look at the result list screenshot.
- [ ] **Step 4: Commit**: `Add owed accounts to the Ledger Menu`.

### Task 14: Docs and final verification

**Files:**
- Modify: `README.md`: a "Bills and debts" section (cards, cashback, pay later and splits,
  loans, regular bills, the Bills tab, how dues are worked out), plus the test count.
- Modify: `PROJECT_STATUS.md`: date, test count, verification evidence, decisions, known
  limitations.
  - The limitations include: Action Button expenses aren't matched to bills, there are no
    card installments, monthly bills only, and reminders come in Part B.
- Local only, never committed: `CLAUDE.md` (architecture notes for owed accounts, dues, plans,
  cashback, bills, V3; the 181/249 test note) and `HANDOFF.md`.

- [ ] **Step 1: Run the full unit suite.**
  `xcodebuild … test > .scratch/test-bills.log 2>&1`. Then
  `grep -E "Executed [0-9]+ tests" .scratch/test-bills.log | tail -1` shows 0 failures. Record
  the count.
- [ ] **Step 2: Clean build.** `xcodebuild … clean build > .scratch/build-bills.log 2>&1; grep
  -c "warning:" .scratch/build-bills.log` prints `0`. Also build for the device with
  `CODE_SIGNING_ALLOWED=NO`.
- [ ] **Step 3: Check symbols.** `python3 scripts/check_sf_symbols.py` passes.
- [ ] **Step 4: Update the docs** with the verified numbers.
- [ ] **Step 5: Commit**: `Update docs for bills and debts`. Then report to the user and ask
  before any push or PR.
