# Pay Later Limit and Fees Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A pay later account's available limit leaves out unpaid split fees, as the service's
own app does, while what's owed stays the full amount to repay.

**Architecture:** One pure calculation in `DueCalculator` (`limitStatus`) works out limit used
from what's owed less each plan's unpaid fees, using months paid from the existing due math.
Plan fees come from a split's fees entry, or from a new stored `PaymentPlan.feesMinor` for
splits already under way. A new `Account.feesUseLimit` switch turns the rule off per account.
Both fields arrive in `LedgerSchemaV4`.

**Tech Stack:** Swift 6.4 (Swift 6 mode), SwiftUI, SwiftData, XCTest. iOS 26.0 deployment.

**Spec:** `docs/superpowers/specs/2026-10-26-pay-later-limit-design.md`

## Global Constraints

- iOS 26 API only; Swift 6 strict concurrency; `MemberImportVisibility` (import every module a
  file uses).
- Zero warnings on a clean build (`grep -c "warning:"` on the build log is 0).
- Money is `Int64` centavos calculated as `Decimal`; never `Double`.
- Dues stay stateless; nothing stored about payments.
- `LedgerService` is the only code that writes models; every change commits before returning.
- Schema change: new `VersionedSchema` plus a lightweight stage; never drop records.
- Test fixtures use made-up amounts only, never the user's real purchases or limit.
- No amounts, names or notes in logs.
- User-facing text in sentence case for sentences, title case for control labels (matching
  "Split Into Months", "Last Payment Is Different").
- Comments describe what the code does; never narrate history.
- Commit subjects start with Add, Update, Fix, Implement, Remove, Refactor or Improve, at most
  50 characters, no prefixes, no `Co-Authored-By` trailer.

## Review Focus

- **A due paid in part.** Paying less than the due lowers what's owed but keeps that plan's fees
  off the limit until the due is fully paid → test in Task 2
  (`testPartPaymentKeepsFeesOffUntilTheDueIsPaid`).
- **Owed below the unpaid fees, or a credit.** After Update What You Owe lowers the balance, the
  fees taken off never exceed what's owed. A credit balance takes nothing off → Task 2
  (`testFeesTakenOffNeverExceedWhatsOwed`).
- **Several splits on one account.** Their unpaid fees add up → Task 2
  (`testTwoSplitsAddTheirUnpaidFees`).
- **Months stepped down to 1 after turning on a different last payment.** The stale last
  payment must not be saved or block Save → Task 5 (`SplitPlanInputTests`).
- **A split under way, partly paid, with a price.** Only the unpaid months' share of its fees is
  taken off → Task 2 (`testStoredFeesOfAPlanUnderWay`).

---

## Setup

- [ ] Commit the spec and this plan on `feature/pay-later-limit`:

```bash
git add docs/superpowers/specs/2026-10-26-pay-later-limit-design.md docs/superpowers/plans/2026-10-26-pay-later-limit.md
git commit -m "Add pay later limit design and plan"
```

Test command used below, with `<Test>` replaced:

```sh
xcodebuild -project Ledger.xcodeproj -scheme Ledger \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' \
  -derivedDataPath .scratch/DerivedData test -only-testing:LedgerTests/<Test> 2>&1 | tail -20
```

---

### Task 1: Schema version 4

**Files:**
- Create: `Ledger/Persistence/LedgerSchemaV4.swift`
- Modify: `Ledger/Persistence/LedgerSchemaV3.swift` (remove `LedgerMigrationPlan` and the
  type aliases at the end, lines ~324–344)
- Modify: `Ledger/Persistence/LedgerStore.swift:41` (`LedgerSchemaV3` → `LedgerSchemaV4`)
- Test: `LedgerTests/SchemaMigrationTests.swift`

**Interfaces:**
- Produces: `Account.feesUseLimit: Bool` (default `false`); `PaymentPlan.feesMinor: Int64?`
  (default `nil`). Type aliases `Account`, `LedgerCategory`, `LedgerTransaction`, `PaymentPlan`,
  `Bill`, `DueOverride` now point at `LedgerSchemaV4`.

- [ ] **Step 1: Write the failing test** `testVersion3StoreOpensWithEveryRecordAndDefaults` in
  `SchemaMigrationTests`, shaped like `testVersion2StoreOpensWithEveryRecordAndDefaults`.
  Write a V3 store holding a pay later account and a plan, then open it with
  `LedgerStore.makeContainer(storage: .onDisk(url))`:

```swift
let account = LedgerSchemaV3.Account(
    name: "PayLater", kind: .payLater, openingBalanceMinor: -150_000,
    createdAt: TestClock.referenceDate, sortOrder: 0
)
account.statementDay = 31
account.dueDay = 5
account.creditLimitMinor = 1_000_000
let plan = LedgerSchemaV3.PaymentPlan(
    title: "Headphones", account: account, monthlyMinor: 50_000, lastMinor: 50_000,
    months: 3, paidAtStart: 0, firstDue: 20260405, createdAt: TestClock.referenceDate
)
// insert both, save; then after reopening:
XCTAssertFalse(payLater.feesUseLimit)
XCTAssertEqual(payLater.creditLimitMinor, 1_000_000)
let reopened = try XCTUnwrap(try ledger.plans(for: payLater).first)
XCTAssertNil(reopened.feesMinor)
XCTAssertEqual(reopened.monthlyMinor, 50_000)
XCTAssertEqual(reopened.months, 3)
XCTAssertEqual(try ledger.balance(of: payLater)?.owed?.amount, 1_500)
```

- [ ] **Step 2: Run it.** `<Test>` = `SchemaMigrationTests`. Expected: build failure,
  `value of type 'Account' has no member 'feesUseLimit'`.

- [ ] **Step 3: Add `LedgerSchemaV4`.** Copy every model from V3 unchanged into
  `enum LedgerSchemaV4: VersionedSchema` (`Schema.Version(4, 0, 0)`, same six models). Add the
  two fields below. Move `LedgerMigrationPlan` and the type aliases into this file. Add
  `LedgerSchemaV4.self` to `schemas`, and add
  `.lightweight(fromVersion: LedgerSchemaV3.self, toVersion: LedgerSchemaV4.self)` to `stages`.
  The header comment says version 4 adds the per-account fee switch and stored plan fees.

```swift
// Account, after strictReminder:
/// Whether the pay later service counts fees against the limit. Read only for pay later accounts.
var feesUseLimit: Bool = false

// PaymentPlan, after feesID:
/// Fees of a plan with no fees entry, in minor units: its payments' total less the item price
/// entered when it was added. `nil` when not known.
var feesMinor: Int64? = nil
```

- [ ] **Step 4: Point `LedgerStore` at V4**, then run the whole suite (`<Test>` = empty, drop
  `-only-testing`). Expected: all tests pass, including the three migration tests.

- [ ] **Step 5: Commit**

```bash
git add Ledger/Persistence LedgerTests/SchemaMigrationTests.swift
git commit -m "Add schema version 4 for pay later fees"
```

---

### Task 2: Limit status calculation

**Files:**
- Modify: `Ledger/Services/DueCalculator.swift`
- Modify: `Ledger/Services/LedgerService+Dues.swift:121-132` (`PlanSnapshot.init?(_:)`)
- Test: `LedgerTests/DueCalculatorTests.swift`

**Interfaces:**
- Consumes: `PaymentPlan.feesMinor` (Task 1).
- Produces:
  - `PlanSnapshot.feesMinor: Int64` (declared `var feesMinor: Int64 = 0` as the last stored
    property, so existing memberwise calls still compile). It holds fees stored on the plan;
    `PlanSnapshot.init?(_ plan:)` sets it to `plan.feesMinor ?? 0`.
  - `struct LimitStatus: Hashable, Sendable { let limit: Money; let available: Money?; let feesOffLimit: Money }`
    in `DueCalculator.swift`. `available` is `nil` while the balance is unknown. `feesOffLimit`
    is the unpaid fees actually taken off (zero when none).
  - `DueCalculator.fees(of plan: PlanSnapshot, _ input: OwedDueInput) -> Int64`: the sum of
    `input.movements` with `planID == plan.id` and `origin == .planFees`, plus `plan.feesMinor`.
  - `DueCalculator.unpaidFees(feesMinor: Int64, months: Int, monthsPaid: Int) -> Int64`
  - `DueCalculator.limitStatus(limitMinor: Int64?, balance: AccountBalance, input: OwedDueInput?, feesUseLimit: Bool, today: CalendarDay, calendar: Calendar) -> LimitStatus?`

- [ ] **Step 1: Write the failing tests.** Give the `plan(...)` fixture a
  `feesMinor: Decimal = 0` parameter (passed through `minor`). Then add a `MARK: Limits`
  group. All cases use the `payLater` schedule (statement 31, due 5), started `try at(2, 1)`, a
  limit of `minor(10_000)`, and the `limit(...)` helper below. Splits use
  `plan(monthly: 1_050, months: 3, firstDue: day(2026, 4, 5))` with entries
  `expense(3_000, at: try at(3, 10), planID:)` and
  `expense(150, at: try at(3, 10), planID:, origin: .planFees)`.

```swift
private func limit(_ input: OwedDueInput, feesUseLimit: Bool = false, today: CalendarDay) -> LimitStatus? {
    DueCalculator.limitStatus(limitMinor: minor(10_000), balance: input.balance, input: input,
                              feesUseLimit: feesUseLimit, today: today, calendar: calendar)
}
```

| Test | Setup | Assertions |
|---|---|---|
| `testUnpaidFeesShareRoundsThePaidPartDown` | pure | `unpaidFees(feesMinor: 10_000, months: 3, monthsPaid:)` for 0, 1, 2, 3 → `10_000, 6_667, 3_334, 0`; `(5_000, 1, 0)` → `5_000`; `(5_000, 1, 1)` → `0`; `(5_000, 1, 2)` → `0` |
| `testLimitStatusLeavesUnpaidSplitFeesOut` | split, opening 0 | today `day(2026, 3, 20)`: available 7_000, feesOffLimit 150, limit 10_000. Add `payment(1_050, at: try at(4, 1))`, today `day(2026, 4, 2)`: available 8_000, feesOffLimit 100. Add payments at `(5, 1)` and `(6, 1)`, today `day(2026, 6, 2)`: available 10_000, feesOffLimit 0 |
| `testPartPaymentKeepsFeesOffUntilTheDueIsPaid` | split, opening 0, `payment(500, at: try at(4, 1))` | today `day(2026, 4, 2)`: available 7_500, feesOffLimit 150 |
| `testFeesUseTheLimitKeepsLimitLessOwed` | split, opening 0 | `feesUseLimit: true`, today `day(2026, 3, 20)`: available 6_850, feesOffLimit 0 |
| `testTwoSplitsAddTheirUnpaidFees` | the split above plus a second `plan(monthly: 530, months: 2, firstDue: day(2026, 4, 5))` with `expense(1_000…)` and `expense(60…, origin: .planFees)` | today `day(2026, 3, 20)`: feesOffLimit 210 |
| `testStoredFeesOfAPlanUnderWay` | opening −1_500, no movements, `plan(monthly: 500, months: 6, paidAtStart: 3, firstDue: day(2026, 4, 5), feesMinor: 300)` | today `day(2026, 3, 20)`: feesOffLimit 150, available 8_650 |
| `testFeesTakenOffNeverExceedWhatsOwed` | opening −100, `plan(monthly: 500, months: 3, firstDue: day(2026, 4, 5), feesMinor: 300)` | today `day(2026, 3, 20)`: available 10_000, feesOffLimit 100. Same with opening +50: available 10_050, feesOffLimit 0 |
| `testCardLimitStatusIsLimitLessOwed` | `.creditCard`, `card` schedule, opening −2_500, plus a `plan(..., feesMinor: 300)` to prove cards ignore fees | available 7_500, feesOffLimit 0. With `limitMinor: nil` → `nil`. With opening `nil`: limit 10_000, available `nil` |

- [ ] **Step 2: Run it.** `<Test>` = `DueCalculatorTests`. Expected: build failure on
  `limitStatus` / `unpaidFees`.

- [ ] **Step 3: Implement.** `unpaidFees` returns
  `feesMinor - feesMinor * Int64(min(monthsPaid, months)) / Int64(months)`, so the paid share is
  rounded down and reaches zero on the last month. `limitStatus`:
  1. Returns `nil` without `limitMinor`.
  2. With an unknown balance, `available` is `nil` and `feesOffLimit` is zero.
  3. Takes fees off only when `balance.account.kind == .payLater`, `!feesUseLimit` and `input`
     is non-nil. Unpaid fees are the sum over `input.plans` of
     `unpaidFees(feesMinor: fees(of: plan, input), months: plan.months, monthsPaid: monthsPaid(plan, input, today:, calendar:))`.
  4. Takes off `min(unpaid, max(owed, 0))`.
  5. Sets `available` = limit − (owed − taken off).

  Leave `availableCredit` in place; Task 6 removes it.

- [ ] **Step 4: Run it.** `<Test>` = `DueCalculatorTests`. Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Ledger/Services/DueCalculator.swift Ledger/Services/LedgerService+Dues.swift LedgerTests/DueCalculatorTests.swift
git commit -m "Add limit status leaving out unpaid split fees"
```

---

### Task 3: Fees Use the Limit switch

**Files:**
- Modify: `Ledger/Services/LedgerService+Owed.swift` (`OwedTerms`, `ValidatedOwedTerms`,
  `validatedTerms`)
- Modify: `Ledger/Features/Bills/OwedAccountEditorView.swift`
- Test: `LedgerTests/OwedAccountTests.swift`

**Interfaces:**
- Consumes: `Account.feesUseLimit` (Task 1).
- Produces: `OwedTerms.feesUseLimit: Bool`. `init` gains a trailing `feesUseLimit: Bool = false`
  parameter, so existing calls compile.

- [ ] **Step 1: Write the failing test** `testFeesUseLimitIsSavedForPayLaterOnly`:

```swift
let payLater = try h.ledger.createOwedAccount(
    name: "PayLater", kind: .payLater,
    terms: OwedTerms(statementDay: 31, dueDay: 5, creditLimit: 10_000, feesUseLimit: true),
    owedNow: 0, stillDue: nil
)
XCTAssertTrue(payLater.feesUseLimit)
try h.ledger.updateOwedAccount(payLater, name: "PayLater", terms: OwedTerms(statementDay: 31, dueDay: 5, creditLimit: 10_000))
XCTAssertFalse(payLater.feesUseLimit)
let card = try h.ledger.createOwedAccount(
    name: "Visa card", kind: .creditCard,
    terms: OwedTerms(statementDay: 5, dueDay: 25, feesUseLimit: true), owedNow: 0, stillDue: 0
)
XCTAssertFalse(card.feesUseLimit)
```

  Use the class's harness and calendar. If a statement is waiting on the reference date, pass a
  `stillDue` as the existing tests there do.

- [ ] **Step 2: Run it.** `<Test>` = `OwedAccountTests`. Expected: build failure on the
  `feesUseLimit:` argument.

- [ ] **Step 3: Implement.** `ValidatedOwedTerms` gains `let feesUseLimit: Bool`, set to
  `kind == .payLater && terms.feesUseLimit`, and `apply(to:)` writes it. In the editor:
  - Add `feesUseLimit` state and include it in the snapshot used by `hasChanges`, starting
    from `account?.feesUseLimit ?? false`.
  - For `.payLater` only, add `Toggle("Fees Use the Limit", isOn: $feesUseLimit)` under the
    limit field, with the footer
    `"Turn on if this service's available limit goes down by its fees or interest too."`
  - Pass the value in `terms`.

- [ ] **Step 4: Run it.** `<Test>` = `OwedAccountTests`. Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Ledger/Services/LedgerService+Owed.swift Ledger/Features/Bills/OwedAccountEditorView.swift LedgerTests/OwedAccountTests.swift
git commit -m "Add a fees use the limit switch to pay later"
```

---

### Task 4: Item price for splits under way

**Files:**
- Modify: `Ledger/Services/LedgerService+Plans.swift` (`PlanTerms`, `addExistingPlan`)
- Modify: `Ledger/Features/Bills/PlanFields.swift` (`PlanPaymentsInput`)
- Modify: `Ledger/Features/Bills/ExistingPlanView.swift`
- Test: `LedgerTests/PaymentPlanTests.swift`

**Interfaces:**
- Consumes: `PaymentPlan.feesMinor` (Task 1); `PlanSnapshot.feesMinor` (Task 2).
- Produces:
  - `PlanTerms.price: Decimal?`, the last property, defaulting to `nil`. Documented as: "The
    item's price, for a split already under way. The payments' total less this is the plan's
    fees."
  - `PlanPaymentsInput.price: Decimal?`, passed through by `terms(nextDue:)`.

- [ ] **Step 1: Write the failing tests:**
  - `testExistingSplitWithPriceStoresItsFees`: `addExistingPlan` with
    `PlanTerms(title: "Headphones", monthly: 550, last: nil, months: 2, paidAtStart: 0, nextDue: day(2026, 4, 5), price: 1_000)`.
    Expect `plan.feesMinor == 10_000`, `PlanSnapshot(plan)?.feesMinor == 10_000`, and no
    entries recorded.
  - `testExistingSplitPriceAboveItsPaymentsIsRefused`: `monthly: 450`, `months: 2`,
    `price: 1_000` throws `.planTotalBelowPrice`, and no plan is saved.
  - `testExistingSplitWithoutPriceHasUnknownFees`: no price gives `plan.feesMinor == nil`.

- [ ] **Step 2: Run it.** `<Test>` = `PaymentPlanTests`. Expected: build failure on `price:`.

- [ ] **Step 3: Implement.** In `addExistingPlan`, when `terms.price` is set:
  - convert it with `AmountRules.transactionMinorUnits(_:currency:)`;
  - compute fees = `validated.amounts.totalMinor` − price;
  - throw `LedgerError.planTotalBelowPrice` below zero;
  - set `plan.feesMinor` before the commit.

  In `ExistingPlanView`, for `.payLater` only, add a section with
  `AmountField("Item Price", amount: $input.price, accessibilityLabel: "Item price")` and this
  footer:
  `"Optional. With the price, Ledger knows which part is fees, which most pay later services leave out of your available limit."`

- [ ] **Step 4: Run it.** `<Test>` = `PaymentPlanTests`. Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Ledger/Services/LedgerService+Plans.swift Ledger/Features/Bills/PlanFields.swift Ledger/Features/Bills/ExistingPlanView.swift LedgerTests/PaymentPlanTests.swift
git commit -m "Add item price to splits under way"
```

---

### Task 5: One-month splits and fee summary

**Files:**
- Modify: `Ledger/Services/LedgerService+Plans.swift:41` (`splitMonths = 1...60`)
- Modify: `Ledger/Features/Bills/SplitPlanSection.swift`
- Modify: `Ledger/Features/Bills/PlanFields.swift` (`PlanPaymentsInput`, `PlanPaymentRows`)
- Modify: `Ledger/Formatting/PlanCopy.swift`
- Test: `LedgerTests/PaymentPlanTests.swift`, `LedgerTests/PlanCopyTests.swift`,
  create `LedgerTests/SplitPlanInputTests.swift`

**Interfaces:**
- Produces:
  - `SplitPlanInput.usesDifferentLast: Bool` and `PlanPaymentsInput.usesDifferentLast: Bool`
    (`hasDifferentLast && months > 1`).
  - `PlanCopy.splitSummary(price: Decimal, months: Int, monthly: Decimal, last: Decimal, formatter: MoneyFormatter) -> String`

- [ ] **Step 1: Write the failing tests.**
  - `PaymentPlanTests`: change `testSplitOnlyOnPayLater`'s months-1 case to `months: 0`,
    expecting `.planMonthsOutOfRange(range: 1...60)`.
  - `PaymentPlanTests.testOneMonthSplitIsDueOnTheStatementsDueDate`:
    `split(1_000, …, months: 1, monthly: 1_050, at: h.clock.now)`. Expect `plan.months == 1`,
    `plan.firstDueDay == day(2026, 4, 5)`, `PlanSnapshot(plan)?.slices.count == 1`, a fees
    entry of `5_000` minor units, and owed of `1_050`.
  - `SplitPlanInputTests`:

```swift
let split = SplitPlanInput(isOn: true, months: 1, monthly: 1_050, hasDifferentLast: true, last: nil)
XCTAssertTrue(split.isComplete)
let draft = TransactionDraft.expense(amount: 1_000, accountID: UUID(), categoryID: UUID(), occurredAt: TestClock.referenceDate, note: nil)
XCTAssertEqual(split.purchase(from: draft)?.months, 1)
XCTAssertNil(split.purchase(from: draft)?.last)
var payments = PlanPaymentsInput(title: "Earbuds", monthly: 1_050, hasDifferentLast: true, last: 900, months: 1)
XCTAssertNil(payments.terms(nextDue: CalendarDay(year: 2026, month: 4, day: 5))?.last)
payments.months = 2
XCTAssertEqual(payments.terms(nextDue: CalendarDay(year: 2026, month: 4, day: 5))?.last, 900)
```

  - `PlanCopyTests.testSplitSummary` with `fixedFormatter()`, comparing through the same
    space-normalising helper `MoneyFormatterSignTests` uses, if one is needed:

| price, months, monthly, last | Expected |
|---|---|
| 1_000, 2, 550, 550 | `You'll pay ₱1,100.00 in all: ₱100.00 more than the price, recorded as fees and interest. That's ₱50.00 a month, 5% of the price.` |
| 1_000, 3, 383.33, 383.34 | `You'll pay ₱1,150.00 in all: ₱150.00 more than the price, recorded as fees and interest. That's ₱50.00 a month, 5% of the price.` |
| 300, 1, 314.70, 314.70 | `You'll pay ₱314.70 in all: ₱14.70 more than the price, recorded as fees and interest. That's 4.9% of the price.` |
| 1_000, 2, 500, 500 | `The payments add up to the price, so there are no fees.` |
| 1_000, 2, 450, 450 | `The payments add up to less than the price. Check the amount of each payment.` |

- [ ] **Step 2: Run them.** `<Test>` = `PaymentPlanTests`, then `SplitPlanInputTests`, then
  `PlanCopyTests`. Expected: failures (range assertion, missing `usesDifferentLast`, missing
  `splitSummary`).

- [ ] **Step 3: Implement.**
  - `splitMonths = 1...60`.
  - `isComplete`, `purchase(from:)` and `terms(nextDue:)` use `usesDifferentLast`.
  - `SplitPlanSection` and `PlanPaymentRows` show the different-last toggle and field only when
    months > 1.
  - `splitSummary` builds the text as in the table:
    - total = monthly × (months − 1) + last; extra = total − price.
    - The monthly fee is extra ÷ months, rounded to the centavo. It's left out at 1 month.
    - The share is extra ÷ months ÷ price × 100, rounded half up to one decimal place and
      formatted with `formatter.locale`, with no trailing ".0".
    - Leave out the share sentence when price ≤ 0.
  - `SplitPlanSection`'s footer calls `splitSummary` once the price and payment are entered.
    The prompt shown while the split is off becomes
    `"Paying next month or in 3, 6, or more months? Split it to track each payment on its due date."`

- [ ] **Step 4: Run all three.** Expected: all pass.

- [ ] **Step 5: Commit**

```bash
git add Ledger/Services/LedgerService+Plans.swift Ledger/Features/Bills Ledger/Formatting/PlanCopy.swift LedgerTests
git commit -m "Add one-month splits and a fee summary"
```

---

### Task 6: Available limit on the account screen and Bills tab

**Files:**
- Modify: `Ledger/Services/LedgerService+Owed.swift` (add `limitStatus(of:)`)
- Modify: `Ledger/Features/Bills/OwedAccountDetailView.swift:213-223` (`limitSection`)
- Modify: `Ledger/Features/Bills/BillsView.swift:191-195` (`available(for:)`; share the input
  building with `loanProgress`)
- Modify: `Ledger/Features/Bills/BillsCopy.swift` (footer copy)
- Modify: `Ledger/Services/DueCalculator.swift` (remove `availableCredit`)
- Modify: `Ledger/Support/SampleData.swift` (a sample split with fees on "PayLater")
- Test: `LedgerTests/PaymentPlanTests.swift`, `LedgerTests/DueCalculatorTests.swift` (remove
  `testAvailableCredit`), `LedgerTests/DueStatusCopyTests.swift`

**Interfaces:**
- Consumes: `DueCalculator.limitStatus` and `LimitStatus` (Task 2); `OwedTerms.feesUseLimit`
  (Task 3).
- Produces:
  - `LedgerService.limitStatus(of account: Account) throws -> LimitStatus?`: it uses
    `owedDueInput(for:)`, falls back to `balance(of:)` with no input when there's no schedule,
    and uses `today`.
  - `BillsCopy.feesOffLimitFooter(_ fees: Money, formatter: MoneyFormatter) -> String`

- [ ] **Step 1: Write the failing tests** (`PaymentPlanTests`). The account is a pay later account
  created with `OwedTerms(statementDay: 31, dueDay: 5, creditLimit: 10_000)`, plus
  `split(3_000, months: 3, monthly: 1_050, at: h.clock.now)`.
  - `testAvailableLimitLeavesSplitFeesOut`:
    1. Right after the split: available 7_000, feesOffLimit 150.
    2. After
       `record(.transfer(amount: 1_050, fromAccountID: bank.id, toAccountID: payLater.id, occurredAt: h.clock.now))`,
       where `bank = try h.account("Bank", opening: 10_000)`: available 8_000, feesOffLimit 100.
    3. After `updateOwedAccount` with `feesUseLimit: true`: available 7_900. Turning it off
       again gives 8_000.
  - `testDeletingASplitBringsBackTheLimit`: delete the plan (no payment); available 10_000,
    feesOffLimit 0.
  - `DueStatusCopyTests.testFeesOffLimitFooter`:
    `BillsCopy.feesOffLimitFooter(Money(dec("150")), formatter: fixedFormatter())` gives
    `"₱150.00 of what you owe is fees, which don't use your limit."`

- [ ] **Step 2: Run them.** `<Test>` = `PaymentPlanTests`, then `DueStatusCopyTests`.
  Expected: build failure on `limitStatus(of:)` / `feesOffLimitFooter`.

- [ ] **Step 3: Implement.**
  - `limitSection(account:balance:input:today:)` shows the limit and `Available` from
    `DueCalculator.limitStatus(... feesUseLimit: account.feesUseLimit ...)`. It shows
    `feesOffLimitFooter` when `feesOffLimit.isPositive`.
  - `BillsView.available(for:)` uses the same calculation, with an input built the way
    `loanProgress` builds it.
  - Remove `DueCalculator.availableCredit` and `testAvailableCredit`.
  - In `SampleData.loadOwedAccounts`, right after creating "PayLater", record
    `SplitPurchase(amount: 1_200, …, categoryID: expenses["Shopping"], occurredAt: hoursAgo(48), note: "Earbuds", months: 3, monthly: 420, last: nil)`
    when the Shopping category exists.

- [ ] **Step 4: Run the whole suite.** Expected: all pass. Then do a clean build and confirm
  `grep -c "warning:"` is 0, and that `python3 scripts/check_sf_symbols.py` passes.

- [ ] **Step 5: Look at the screens.** Add a throwaway `testPayLaterLimit` to
  `.scratch/TempScreensUITests.swift`, following `testPlanScreens`. It relaunches with
  `-LedgerInitialTab bills`, captures the Bills tab, opens "PayLater", and captures the limit
  section after scrolling. It taps rather than typing. Then:
  1. Run `.scratch/run_shots.sh light testPayLaterLimit` and
     `.scratch/run_shots.sh dark testPayLaterLimit`.
  2. Open every screenshot. Check "left of limit", Available and the fees footer.
  3. Check the split sheet at 1 month: no "Last Payment Is Different", and the summary
     sentence present.

- [ ] **Step 6: Commit**

```bash
git add Ledger LedgerTests
git commit -m "Show available limit without unpaid split fees"
```

---

### Task 7: Wrap-up

- [ ] Run the full unit suite and the Shortcuts UI tests 01 and 03 (Shortcuts UI tests command
  in CLAUDE.md, `-only-testing:LedgerShortcutsUITests/<…>/test01…` and `test03…`). Expected:
  all pass.
- [ ] Update `HANDOFF.md` (local only, not committed) with the branch, what shipped, and the
  open questions from the spec. Also give the user the two steps for fixing their current
  pay later purchase.
