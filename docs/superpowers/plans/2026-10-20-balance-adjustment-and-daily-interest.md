# Balance Adjustment and Daily Interest Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let the user correct an account to its real balance with one adjustment entry, and have Ledger post each day's bank interest and withholding tax automatically, shown as one row per day, with Update Balance also in the Ledger Menu.

**Architecture:** A new schema version adds interest settings to `Account` and adjustment and calculation fields to `LedgerTransaction`. Adjustments are a new `TransactionKind` that changes balances but never income or spending. Interest is computed by a pure `InterestCalculator` and posted by `LedgerService.postDueInterest()`, which the app runs when it becomes active and at each 1:00 AM while open, and App Intents run before they read data. Lists turn each posting moment's interest and tax entries into one `HistoryItem.interest` row.

**Tech Stack:** Swift 6.4 (Swift 6 mode, strict concurrency), SwiftUI, SwiftData, App Intents, XCTest. iOS 26.0 deployment target.

**Spec:** `docs/superpowers/specs/2026-10-20-balance-adjustment-and-daily-interest-design.md`

## Global Constraints

- Read `CLAUDE.md` and `HANDOFF.md` first. Their rules apply to every task.
- iOS 26 API only (Xcode 27 / iOS 27 SDK). Zero build warnings.
- `MemberImportVisibility` is on: every file imports each module it uses (`Foundation`, `SwiftUI`, `SwiftData`, `AppIntents`, `os`).
- New files under `Ledger/` and `LedgerTests/` join their targets automatically. Never edit `project.pbxproj`.
- Only `LedgerService` writes data. Each mutation calls `commit()` before returning. A failed save throws `LedgerError.persistenceFailed` and leaves nothing pending.
- Money: `Int64` minor units stored, `Decimal` arithmetic, never `Double`. Rates: `Int64` parts per million, never `Double`.
- Formula (spec): gross = end-of-day balance × annual rate ÷ **360**, **rounded up** to the centavo; tax = gross × tax rate, rounded to the nearest centavo (`NSDecimalRound` `.plain`). Default tax rate **20%**. Interest for day D posts dated **1:00 AM on D+1**, device calendar.
- Log with `Log`. Never log amounts, balances, rates, names, notes or references.
- User-facing copy: plain words, amounts through `MoneyFormatter`. Buttons and screen titles use Title Case like the existing screens ("Update Balance", "Set Opening Balance").
- SF Symbols must pass `python3 scripts/check_sf_symbols.py`.
- The repo is public: no real balances, account details or screenshots in code, tests or docs. Fixtures use made-up amounts.
- Git: branch `feature/balance-adjustment-and-interest` cut from `origin/develop`. Commit subjects start with Add, Update, Fix, Implement, Remove, Refactor or Improve, imperative, ≤ 50 characters, no `feat:` prefixes, **no `Co-Authored-By` trailer**. **Commit and push only with the user's authorization.**
- Test command (substitute the class): `xcodebuild -project Ledger.xcodeproj -scheme Ledger -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=26.5' -derivedDataPath .scratch/DerivedData test -only-testing:LedgerTests/<TestClass>`. Full suite: same without `-only-testing`. Keep logs in `.scratch/`.
- Interest test fixtures use `try fixedCalendar("Asia/Manila")` (in `LedgerTests/HardeningSupport.swift`). `TestClock.referenceDate` is 2026-03-15 10:00 Manila (02:00 UTC).

## Review Focus

1. **App left open across 1:00 AM.** Overview should gain the night's interest without relaunching. Pinned by `testNextPostingTimeIsTheComing1AM` (Task 4); the timer that uses it is checked by hand in Task 6.
2. **Time zone changes between catch-ups**, for example travelling. Days are calendar days in the current time zone, and a day already posted must never post again. Pinned by `testChangingTimeZoneNeverPostsADayTwice` (Task 5).
3. **Months without opening Ledger.** The catch-up must post every day in one save, in order and compounding. Pinned by `testSixtyDaysAwayPostEveryDayInOneSave` (Task 5).
4. **Rates typed as "3,25", "3.25%" or " 4 % "** in other locales. These must parse to the same rate. Pinned by `testRateParsingAcceptsLocaleAndPercentSign` (Task 4).
5. **Interest that falls due between opening Update Balance and saving it.** The adjustment must be measured after that interest posts, not against the earlier preview. Pinned by `testUpdateBalancePostsDueInterestBeforeMeasuring` (Task 5).

---

## Before Task 1: branch

- [ ] **Step 1: Get authorization.** `develop` exists only locally, and `origin/develop` is missing. Ask the user to authorize `git push -u origin develop`, and to authorize commits for this plan's tasks. Stop until they answer.
- [ ] **Step 2: Cut the branch**

```bash
git fetch origin
git branch --list 'feature/*'          # must be empty
git switch -c feature/balance-adjustment-and-interest origin/develop
git branch --unset-upstream
```

- [ ] **Step 3: Commit the spec and this plan**

```bash
git add docs/superpowers/specs/2026-10-20-balance-adjustment-and-daily-interest-design.md docs/superpowers/plans/2026-10-20-balance-adjustment-and-daily-interest.md
git commit -m "Add design and plan for adjustments and interest"
```

---

### Task 1: Schema version 2

**Files:**
- Create: `Ledger/Persistence/LedgerSchemaV2.swift`
- Modify: `Ledger/Persistence/LedgerSchemaV1.swift` (move `LedgerMigrationPlan` and the type aliases out of it; the V1 models stay byte-for-byte)
- Modify: `Ledger/Persistence/LedgerStore.swift` (`Schema(versionedSchema: LedgerSchemaV2.self)`)
- Test: `LedgerTests/SchemaMigrationTests.swift`

**Interfaces:**
- Produces: `LedgerSchemaV2` (version 2.0.0) with the same three models plus these stored properties:
  - `Account.interestRatePPM: Int64? = nil`: the annual rate in parts per million. `nil` means interest is off.
  - `Account.interestTaxRatePPM: Int64 = 200_000`
  - `Account.interestPaidThrough: Int? = nil`: the last calendar day whose interest has posted, as `CalendarDay.storedValue` (yyyymmdd).
  - `LedgerTransaction.directionRaw: String? = nil`: an adjustment's `AdjustmentDirection` raw value.
  - `LedgerTransaction.basisMinor: Int64? = nil`: the amount an automatic entry was calculated from. For interest, the end-of-day balance; for tax, the gross interest.
  - `LedgerTransaction.basisRatePPM: Int64? = nil`: the rate applied to `basisMinor`.
- `LedgerMigrationPlan.schemas == [LedgerSchemaV1.self, LedgerSchemaV2.self]`, `stages == [.lightweight(fromVersion: LedgerSchemaV1.self, toVersion: LedgerSchemaV2.self)]`. `typealias Account = LedgerSchemaV2.Account` and likewise for the others.

- [ ] **Step 1: Write the failing test** `testVersion1StoreOpensWithEveryRecordAndDefaults`

Inside a `do {}` scope, create an on-disk store at a temporary URL (follow `PersistenceRoundTripTests`) with `ModelContainer(for: Schema(versionedSchema: LedgerSchemaV1.self), configurations: ModelConfiguration(schema:url:allowsSave:true,cloudKitDatabase:.none))`. Insert `LedgerSchemaV1.Account(name: "Savings", kind: .bank, openingBalanceMinor: 1_250_050, createdAt: TestClock.referenceDate, sortOrder: 0)`, a `LedgerSchemaV1.LedgerCategory` "Food", and an expense of 25_000 minor units on that account. Save, then leave the scope. Then:

```swift
let container = try LedgerStore.makeContainer(storage: .onDisk(url))
let ledger = LedgerService(context: container.mainContext, clock: { TestClock.referenceDate })
let savings = try XCTUnwrap(try ledger.accounts().first)
XCTAssertEqual(savings.name, "Savings")
XCTAssertEqual(savings.openingBalanceMinor, 1_250_050)
XCTAssertNil(savings.interestRatePPM)
XCTAssertEqual(savings.interestTaxRatePPM, 200_000)
XCTAssertNil(savings.interestPaidThrough)
let expense = try XCTUnwrap(try ledger.transactions().first)
XCTAssertEqual(expense.amountMinor, 25_000)
XCTAssertNil(expense.directionRaw)
XCTAssertNil(expense.basisMinor)
XCTAssertEqual(try ledger.balance(of: savings)?.currentBalance?.amount, dec("12250.50"))
```

- [ ] **Step 2: Run it.** Expected: compile failure, because `interestRatePPM` doesn't exist.
- [ ] **Step 3: Add `LedgerSchemaV2`.** Copy the V1 models into `enum LedgerSchemaV2: VersionedSchema`, add the properties above with their doc comments, update the migration plan and aliases, and point `makeContainer` at V2. Keep the "never edit a shipped version" header comment on both schemas.
- [ ] **Step 4: Run the new test and the full suite.** Expected: everything passes (181 existing + 1).
- [ ] **Step 5: Commit:** `git commit -m "Add schema version 2 for interest and adjustments"`

---

### Task 2: Balance adjustments in the ledger engine

**Files:**
- Modify: `Ledger/Domain/LedgerKinds.swift`, `Ledger/Domain/LedgerError.swift`, `Ledger/Persistence/ModelAccessors.swift`
- Modify: `Ledger/Services/BalanceCalculator.swift`, `Ledger/Services/LedgerService+Balances.swift` (`Movement.init`), `Ledger/Services/LedgerService+Transactions.swift`, `Ledger/Services/LedgerService+Accounts.swift` (make `openingBalanceMinorUnits(forCurrentBalance:of:activity:)` internal)
- Modify: `Ledger/Formatting/TransactionSummary.swift`, `Ledger/Components/LedgerTheme.swift`, and every exhaustive `switch` over `TransactionKind` the compiler flags: `TransactionEditorComponents.swift`, `TransactionSharedViews.swift`, `TransactionEditorView.swift`, `TransactionDetailView.swift`, `IntentFlows.swift`, `Support/SampleData.swift`
- Create: `Ledger/Services/LedgerService+Adjustments.swift`
- Test: `LedgerTests/BalanceAdjustmentTests.swift`

**Interfaces:**
- Produces:
  - `TransactionKind.adjustment`: title "Adjustment", `systemImage` "plus.forwardslash.minus", `requiredCategoryKind` `nil`. `static let loggable: [TransactionKind] = [.expense, .income, .transfer]`. Replace `TransactionKind.allCases` with `loggable` in the editor's type picker and `AddTransactionMenu`.
  - `enum AdjustmentDirection: String, Codable, Sendable { case increase, decrease }`
  - `LedgerTransaction.adjustmentDirection: AdjustmentDirection?` (from `directionRaw`)
  - `LedgerTransaction.isEditable: Bool`: `false` for `.adjustment` and for `origin == .interest` (Task 5 adds that origin; until then, adjustments only).
  - `Movement.direction: AdjustmentDirection?`. `Movement.init?(_:)` returns `nil` for an adjustment without a readable direction.
  - `AccountBalance.adjustments: Money`, signed (increases − decreases). `netActivity` includes it. `periodSummary` ignores adjustments.
  - `LedgerError.balanceNegative` ("A balance can't be negative.") and `LedgerError.entryNotEditable` ("Ledger keeps this entry as it is. Use Update Balance to correct a balance.")
  - `enum BalanceCorrection: Equatable, Sendable { case alreadyMatches; case setOpeningBalance(Money); case adjustment(Money) }`. `adjustment` holds the signed difference.
  - `LedgerService.balanceCorrection(toReach actual: Decimal, for account: Account) throws -> BalanceCorrection`: read-only.
  - `@discardableResult LedgerService.updateBalance(of account: Account, to actual: Decimal, origin: EntryOrigin = .app) throws -> BalanceCorrection`: records the correction in one save and returns what it did.
  - `TransactionDraft.init?(_:)` returns `nil` for adjustments. `resolve` throws `.entryNotEditable` for `.adjustment`.
  - `TransactionSummary` for adjustments: title "Balance adjustment", symbol "plus.forwardslash.minus", `signedAmountText` "+₱4.00" or "-₱7.00" by direction. Add `let adjustmentDirection: AdjustmentDirection?` to the summary.

- [ ] **Step 1: Write failing tests** in `BalanceAdjustmentTests` (harness accounts; income source "Salary"):

```swift
func testHigherRealBalanceAddsAnIncreaseAdjustment()      // opening 117 → updateBalance(to: 121) == .adjustment(Money(4)); one .adjustment entry, direction .increase, amountMinor 400, origin .app; balance 121
func testLowerRealBalanceAddsADecreaseAdjustment()        // 117 → 110 == .adjustment(Money(-7)); direction .decrease, amountMinor 700; balance 110
func testMatchingBalanceRecordsNothing()                  // 117 → 117 == .alreadyMatches; transactionCount unchanged
func testUnsetOpeningBalanceIsSetInstead()                // opening nil, income 50 → updateBalance(to: 121) == .setOpeningBalance(Money(71)); openingBalanceMinor 7_100; no adjustment entry
func testUnsetOpeningBelowActivityIsRefused()             // opening nil, income 50 → to 20 throws .balanceBelowRecordedActivity(name:)
func testInvalidRealBalancesAreRefused()                  // -1 → .balanceNegative; dec("1.005") → .amountTooPrecise; AmountRules.maximum + 1 → .amountTooLarge
func testArchivedAccountIsRefused()                       // → .accountArchived(name:)
func testAdjustmentsAreNeitherIncomeNorExpenses()         // updateBalance to 121 then to 114 (+4, -7): periodSummary(h.allTime) income/expenses/counts unchanged; AccountBalance.adjustments == Money(-3); liquid total includes it
func testDeletingAnAdjustmentRestoresTheBalance()
func testAdjustmentsCantBeEditedThroughDrafts()           // TransactionDraft(adjustment) == nil; resolve(TransactionDraft(kind: .adjustment, …)) throws .entryNotEditable
func testFailedAdjustmentLeavesNoTrace()                  // h.assertSaveFails { try $0.updateBalance(of: a, to: 121) }; balance still 117
func testPreviewDoesNotWrite()                            // balanceCorrection(toReach: 121) == .adjustment(Money(4)); transactionCount unchanged; context.hasChanges false
func testAdjustmentSummaryShowsDirection()                // TransactionSummary title "Balance adjustment"; signed text contains "+" / "-" (use fixedFormatter())
```

Write each body with the values in its comment.

- [ ] **Step 2: Run** `-only-testing:LedgerTests/BalanceAdjustmentTests`. Expected: compile failure.
- [ ] **Step 3: Implement** the interfaces above. `updateBalance` validates `actual` like an opening balance, but negative throws `.balanceNegative`. With no opening balance, it sets the opening through `openingBalanceMinorUnits(forCurrentBalance:of:activity:)`. Otherwise it inserts one `.adjustment` transaction (`occurredAt: now`, `category: nil`, `amountMinor` = |difference| validated with `AmountRules.transactionMinorUnits`, `directionRaw` set) and commits. In `LedgerTheme`, adjustments use `.secondary` for both the amount color and the badge tint. `TransactionLogging.canLog(.adjustment, …)` returns `false`. `SampleData` doesn't generate adjustments.
- [ ] **Step 4: Run the class, then the full suite.** Expected: all pass.
- [ ] **Step 5: Commit:** `git commit -m "Add balance adjustments"`

---

### Task 3: Update Balance screen

**Files:**
- Create: `Ledger/Features/Accounts/UpdateBalanceView.swift`
- Modify: `Ledger/Features/Accounts/AccountDetailView.swift`, `Ledger/Features/Accounts/AccountsCopy.swift`, `Ledger/Features/Transactions/TransactionListView.swift`, `Ledger/Features/Transactions/TransactionDetailView.swift`
- Test: `LedgerTests/AccountsFeatureTests.swift` (copy)

**Interfaces:**
- Consumes: `balanceCorrection(toReach:for:)`, `updateBalance(of:to:origin:)`, `BalanceCorrection`, `LedgerTransaction.isEditable`, `AccountBalance.adjustments`.
- Produces: `UpdateBalanceView(account: Account)`, a sheet. `AccountsCopy.correctionPreview(_ correction: BalanceCorrection, accountName: String, formatter: MoneyFormatter) -> String` returns:
  - `.adjustment(+4)`: "Ledger will add a balance adjustment of +₱4.00."
  - `.adjustment(-7)`: "Ledger will add a balance adjustment of -₱7.00."
  - `.setOpeningBalance(71)`: "Ledger will set GCash's opening balance to ₱71.00."
  - `.alreadyMatches`: "This matches Ledger's balance. Nothing will change."
- `AccountsCopy.balanceFormula` becomes "Current balance = opening balance + income + transfers in − expenses − transfers out ± adjustments."

- [ ] **Step 1: Write the failing test** `testCorrectionPreviewCopy`, asserting the four strings above with `fixedFormatter()`.
- [ ] **Step 2: Run it.** Expected: compile failure.
- [ ] **Step 3: Implement.**
  - `UpdateBalanceView`: a `NavigationStack` `Form` with `AmountField("Real Balance", amount:currency:)` focused on appear, and a footer showing `correctionPreview` for the typed amount (or a validation message from the thrown `LedgerError`). The toolbar has Cancel and "Update", disabled while the amount is empty or matches. Saving calls `updateBalance` and dismisses only on success, or shows `LedgerAlert`. Follow `AccountEditorView` for the save and discard pattern.
  - `AccountDetailView`: an "Update Balance" button (`plus.forwardslash.minus`) in the actions section for active accounts, above Add Transaction. An "Adjustments" `LabeledContent` row in Breakdown, after Transfers Out.
  - `TransactionListView`: the Edit swipe action and context-menu item appear only when `transaction.isEditable`. `TransactionDetailView`: the Edit toolbar button only when `live.isEditable`.
- [ ] **Step 4: Verify.** Run the class and confirm it passes. Build the app, then take screenshots in light and dark with `scripts/screenshot.sh` (sample data, initial tab `accounts`) of the account detail and the Update Balance sheet. Use a temporary XCUITest under `LedgerUITests/` to navigate, then delete it. **Look at the images** before claiming the UI works.
- [ ] **Step 5: Commit:** `git commit -m "Add Update Balance screen"`

---

### Task 4: Daily interest calculator

**Files:**
- Create: `Ledger/Domain/CalendarDay.swift`, `Ledger/Domain/InterestTerms.swift`, `Ledger/Services/InterestCalculator.swift`
- Modify: `Ledger/Domain/LedgerError.swift`
- Test: `LedgerTests/InterestCalculatorTests.swift`

**Interfaces:**
- Consumes: `AccountSnapshot`, `Movement`, `BalanceCalculator` (Task 2).
- Produces:

```swift
/// A calendar date independent of time zone, stored as yyyymmdd (20260315).
struct CalendarDay: Hashable, Comparable, Sendable {
    let year: Int; let month: Int; let day: Int
    init(year: Int, month: Int, day: Int)
    init(containing date: Date, calendar: Calendar)
    init?(storedValue: Int)
    var storedValue: Int
    func start(in calendar: Calendar) -> Date
    func adding(days: Int, calendar: Calendar) -> CalendarDay
}

/// A percentage stored exactly as parts per million: 3.25% is 32_500.
struct Rate: Hashable, Sendable {
    let partsPerMillion: Int64
    var percent: Decimal
    /// "3.25", "3,25" (where comma is the decimal separator), "3.25%", " 4 % " → the percent value; nil when unreadable.
    static func parse(_ text: String, locale: Locale = .autoupdatingCurrent) -> Decimal?
}

enum RateRules {
    static func annualRate(percent: Decimal) throws -> Rate   // 0 < p ≤ 100, ≤ 4 decimals
    static func taxRate(percent: Decimal) throws -> Rate      // 0 ≤ p ≤ 100, ≤ 4 decimals
}

struct InterestTerms: Hashable, Sendable {
    let annualRate: Rate
    let taxRate: Rate
    static let defaultTaxRate = Rate(partsPerMillion: 200_000)
}

struct DailyInterest: Hashable, Sendable {
    let accountID: UUID
    let day: CalendarDay
    let postedAt: Date          // 1:00 on the following day
    let balanceMinor: Int64     // end-of-day balance
    let annualRate: Rate
    let taxRate: Rate
    let grossMinor: Int64
    let taxMinor: Int64
}

enum InterestCalculator {
    static let dayCountBasis = 360
    static func grossMinor(balanceMinor: Int64, annualRate: Rate) -> Int64
    static func taxMinor(grossMinor: Int64, taxRate: Rate) -> Int64
    static func postingTime(for day: CalendarDay, calendar: Calendar) -> Date
    /// The latest day whose posting time is at or before `now`.
    static func lastPostableDay(asOf now: Date, calendar: Calendar) -> CalendarDay
    /// The first posting time after `now`.
    static func nextPostingTime(after now: Date, calendar: Calendar) -> Date
    /// Interest for each day after `paidThrough` through `lastDay`, in order. Each day uses the
    /// balance at the end of that day: opening + movements before the next day's start, plus the
    /// interest and tax computed earlier in this call. Days with an unknown, zero or negative
    /// balance produce nothing.
    static func dailyInterest(account: AccountSnapshot, terms: InterestTerms, after paidThrough: CalendarDay, through lastDay: CalendarDay, movements: [Movement], calendar: Calendar) -> [DailyInterest]
}
```

- New `LedgerError` cases: `.interestRateOutOfRange` ("Enter an interest rate above 0% and up to 100%."), `.taxRateOutOfRange` ("Enter a tax rate from 0% to 100%."), `.rateTooPrecise` ("Rates can have at most four decimal places.").
- `grossMinor`: compute `Decimal(balanceMinor) × Decimal(ppm) ÷ (1_000_000 × 360)` in `Decimal`, then `NSDecimalRound(…, 0, .up)`. Never use `Int64` multiplication, which overflows at the maximum balance.

- [ ] **Step 1: Write failing tests** (Manila calendar):

```swift
func testGrossIsRoundedUpAndTaxToNearest() {
    let rate = Rate(partsPerMillion: 32_500), tax = InterestTerms.defaultTaxRate
    XCTAssertEqual(InterestCalculator.grossMinor(balanceMinor: 4_000_000, annualRate: rate), 362)   // 361.11 → 362
    XCTAssertEqual(InterestCalculator.taxMinor(grossMinor: 362, taxRate: tax), 72)                  // 72.4 → 72
    XCTAssertEqual(InterestCalculator.grossMinor(balanceMinor: 2_500_000, annualRate: rate), 226)   // 225.69 → 226
    XCTAssertEqual(InterestCalculator.taxMinor(grossMinor: 226, taxRate: tax), 45)
}
func testExactCentavosAreNotRoundedUp()      // 3_600_000 at 36_000 ppm → 360 exactly
func testTinyBalancesEarnACentavoAndNoTax()  // 100 at 32_500 → 1; taxMinor(1, 20%) == 0
func testMaximumBalanceDoesNotOverflow()     // AmountRules max minor 99_999_999_999_999 at 1_000_000 ppm → 277_777_777_778
func testTaxTiesRoundAwayFromZero()          // taxMinor(4, Rate(125_000)) == 1
func testPostingTimeIsOneAMNextDay()         // day 2026-03-15 → instant("2026-03-15T17:00:00Z")
func testLastPostableDayFlipsAtOneAM()       // now 2026-03-15T16:59:59Z → 2026-03-14; 2026-03-15T17:00:00Z → 2026-03-15
func testNextPostingTimeIsTheComing1AM()     // 2026-03-15T16:30Z → 17:00Z same day; 2026-03-15T17:00Z → 2026-03-16T17:00Z; 2026-03-15T02:00Z → 2026-03-15T17:00Z
func testCalendarDayStoresAndSteps()         // 20260315 round trip; 2026-02-28 + 1 == 2026-03-01; containing 2026-03-15T16:30Z (Manila) == 2026-03-16; init?(storedValue: 20261340) == nil
func testRateParsingAcceptsLocaleAndPercentSign()  // en_US "3.25", de_DE "3,25", "3.25%", " 4 % " → 3.25 / 4; "abc", "" → nil
func testRateRules()                         // annual 0 → .interestRateOutOfRange; 100.0001 → out of range; 3.12345 → .rateTooPrecise; 3.25 → 32_500; tax 0 → 0; tax 20 → 200_000; tax -1 → .taxRateOutOfRange
func testDailyInterestUsesEndOfDayBalanceAndCompounds()
    // opening 40_000; expense 10_000 at 2026-03-15T08:00Z (16:00 Manila) and expense 1_000 at 2026-03-15T16:30Z (00:30 on the 16th);
    // after 2026-03-14 through 2026-03-17 at 3.25%/20%:
    // balances [3_000_000, 2_900_217, 2_900_427], gross [271, 262, 262], tax [54, 52, 52],
    // postedAt [2026-03-15T17:00Z, 2026-03-16T17:00Z, 2026-03-17T17:00Z]
func testDaysWithoutAPositiveKnownBalanceEarnNothing()  // opening nil → []; opening 0 → []; opening 100 with expense 150 on day 15 → []
```

The working for `testDailyInterestUsesEndOfDayBalanceAndCompounds`:
- **Day 15:** the balance is 3_000_000. The 00:30 expense belongs to day 16. Gross is 270.83, rounded up to 271; tax is 54.2, rounded to 54; net 217.
- **Day 16:** the balance is 3_000_000 − 100_000 + 217 = 2_900_217. Gross is 261.82, rounded up to 262; tax is 52; net 210.
- **Day 17:** the balance is 2_900_427. Gross is 261.84, rounded up to 262.

- [ ] **Step 2: Run** `-only-testing:LedgerTests/InterestCalculatorTests`. Expected: compile failure.
- [ ] **Step 3: Implement** the interfaces. `dailyInterest` appends synthetic income and expense `Movement`s at `postedAt` for each day it computes, so later days compound.
- [ ] **Step 4: Run the class.** Expected: all pass.
- [ ] **Step 5: Commit:** `git commit -m "Add daily interest calculator"`

---

### Task 5: Posting daily interest

**Files:**
- Modify: `Ledger/Services/LedgerService.swift` (add `let calendar: Calendar`, init parameter `calendar: Calendar = .current` after `clock`)
- Modify: `Ledger/Domain/LedgerKinds.swift` (`EntryOrigin.interest`), `Ledger/Persistence/ModelAccessors.swift`, `Ledger/Services/LedgerService+Accounts.swift` (`archiveAccount`), `Ledger/Formatting/TransactionSummary.swift`, `Ledger/Features/Transactions/TransactionFiltering.swift` (search matches summary title)
- Create: `Ledger/Services/LedgerService+Interest.swift`
- Modify: `LedgerTests/TestSupport.swift` (`LedgerHarness.init(clock: TestClock = TestClock(), calendar: Calendar = .current)`, passed to `ledger` and `failingLedger()`)
- Test: `LedgerTests/InterestPostingTests.swift`

**Interfaces:**
- Consumes: Task 4's `InterestCalculator`, `InterestTerms`, `RateRules` and `CalendarDay`; Task 2's `updateBalance`.
- Produces:
  - `EntryOrigin.interest`: "/// Posted by Ledger: daily interest and its withholding tax."
  - `Account.interestTerms: InterestTerms?`: `nil` when `interestRatePPM` is `nil`.
  - `LedgerService.setInterest(_ terms: InterestTerms?, for account: Account) throws`. It first posts due interest (`postDueInterest()`), then: if turning on, sets the rates and `interestPaidThrough = CalendarDay(containing: now).adding(days: -1)`; if changing, sets the rates only; if `nil`, clears `interestRatePPM` and `interestPaidThrough`. Then it commits.
  - `@discardableResult LedgerService.postDueInterest() throws -> Int` returns the number of entries inserted. For every account with interest on whose `interestPaidThrough` is before `lastPostableDay(asOf: now)`, it inserts each `DailyInterest` as an income entry (gross; `basisMinor` = balance, `basisRatePPM` = annual rate) and, when `taxMinor > 0`, an expense entry (tax; `basisMinor` = gross, `basisRatePPM` = tax rate). Both have `origin: .interest`, `category: nil`, `occurredAt: postedAt`. It advances `interestPaidThrough`, commits once, and returns 0 without saving when nothing is due.
  - `archiveAccount` posts due interest first and turns interest off in the same save as archiving.
  - `updateBalance(of:to:origin:)` calls `postDueInterest()` before measuring.
  - `TransactionSummary`: for `origin == .interest`, title "Interest" (income) or "Withholding tax" (expense), symbol "percent". `LedgerTransaction.isEditable` is `false` for these entries too.

- [ ] **Step 1: Write failing tests.** Use `LedgerHarness(calendar: try fixedCalendar("Asia/Manila"))`, an account "Savings" with opening 40_000, `terms = InterestTerms(annualRate: Rate(partsPerMillion: 32_500), taxRate: InterestTerms.defaultTaxRate)`, and `setInterest(terms)` at the reference date (2026-03-15 10:00 Manila). Move the clock with `h.clock.now = try instant(…)`.

```swift
func testNothingPostsBeforeOneAM()                 // now 2026-03-15T16:59:00Z → postDueInterest() == 0
func testFirstDayPostsInterestAndTaxAtOneAM()      // now 2026-03-15T17:00:00Z → == 2; income 3.62 origin .interest occurredAt 2026-03-15T17:00:00Z basisMinor 4_000_000 basisRatePPM 32_500;
                                                   // expense 0.72 basisMinor 362 basisRatePPM 200_000; balance 40_002.90; interestPaidThrough 20260315
func testCatchUpPostsEveryMissedDayCompounding()   // now 2026-03-18T17:00:00Z → == 8; interest basisMinor [4_000_000, 4_000_290, 4_000_580, 4_000_870]; balance dec("40011.60")
func testRunningTwiceNeverPostsTwice()             // second call == 0
func testUnknownZeroAndNegativeBalancesEarnNothingButCountAsDone()
func testBackdatedEntriesDontChangePostedInterest() // after day 15 posts, record an expense at 2026-03-15T08:00Z → interest entries and amounts unchanged
func testRateChangePostsEarlierDaysAtTheOldRate()  // now 2026-03-17T01:00Z → setInterest(4%) posts days 15, 16 at 32_500; at 2026-03-17T17:00Z day 17 posts at 40_000
func testRateChangeBeforeOneAMAppliesToTheDayThatJustEnded() // now 2026-03-15T16:30Z setInterest(4%) posts nothing; at 17:00Z day 15 posts at 40_000
func testTurningOffPostsDueDaysThenStops()
func testTurningBackOnNeverFillsSkippedDays()      // off at 2026-03-17T01:00Z, on at 2026-03-20T01:00Z → at 2026-03-20T17:00Z only day 20 posts
func testArchivingTurnsInterestOffAndUnarchivingLeavesItOff()
func testFailedCatchUpLeavesNoTraceAndRetries()    // at 2026-03-15T17:00Z: h.assertSaveFails { try $0.postDueInterest() }; count unchanged; paidThrough 20260314; then h.ledger.postDueInterest() == 2
func testZeroTaxPostsOnlyInterest()                // tax rate 0: at 2026-03-15T17:00Z == 1; the single entry is income 3.62
func testSixtyDaysAwayPostEveryDayInOneSave()      // now 2026-05-13T17:00:00Z (days Mar 15–May 13) → == 120; paidThrough 20260513
func testChangingTimeZoneNeverPostsADayTwice()     // after day 15 posts in Manila, a LedgerService on h.context with fixedCalendar("UTC") at 2026-03-17T02:00:00Z posts only UTC day 16 (2 entries); no second day-15 posting
func testUpdateBalancePostsDueInterestBeforeMeasuring() // now 2026-03-15T17:00Z, updateBalance(to: dec("40010")) == .adjustment(Money(dec("7.10")))
func testInterestEntriesAreNotEditableAndNamed()   // isEditable false; summary titles "Interest" / "Withholding tax"
```

- [ ] **Step 2: Run** `-only-testing:LedgerTests/InterestPostingTests`. Expected: compile failure.
- [ ] **Step 3: Implement** the interfaces. Fetch movements once per catch-up and pass them to `InterestCalculator.dailyInterest`.
- [ ] **Step 4: Run the class, then the full suite.** Expected: all pass, including `SaveFailureRollbackTests` and `LedgerServiceTests`.
- [ ] **Step 5: Commit:** `git commit -m "Add daily interest posting"`

---

### Task 6: Interest settings and catch-up triggers

**Files:**
- Create: `Ledger/Features/Accounts/AccountInterestEditorView.swift`, `Ledger/App/InterestCatchUp.swift`
- Modify: `Ledger/Features/Accounts/AccountDetailView.swift`, `Ledger/Features/Accounts/AccountsCopy.swift`, `Ledger/App/RootView.swift`, `Ledger/Intents/IntentSupport.swift`, `Ledger/Support/SampleData.swift`
- Test: `LedgerTests/AccountsFeatureTests.swift` (copy)

**Interfaces:**
- Consumes: `setInterest`, `postDueInterest`, `InterestCalculator.nextPostingTime`, `Rate.parse`, `RateRules`, `Account.interestTerms`.
- Produces:
  - `AccountsCopy.interestSummary(_ terms: InterestTerms?) -> String`: "3.25% a year, 20% tax" or "Off". Percent text trims trailing zeros ("4% a year, 20% tax").
  - `AccountsCopy.interestFooter` = "Ledger adds each day's interest at 1:00 AM the next day: the day's ending balance × rate ÷ 360, rounded up, minus withholding tax."
  - `extension View { func postingDueInterest() -> some View }`. While the scene is active, it posts due interest immediately, then sleeps until `nextPostingTime(after:)` + 1 second and repeats. It is cancelled when the scene leaves `.active` (`.task(id: scenePhase)`). Errors are logged with `Log.ledger.error` (no amounts), with no alert; the next run retries.
  - `IntentLedger.service()` calls `postDueInterest()` on the service it returns, logging any error and continuing.

- [ ] **Step 1: Write the failing test** `testInterestSummaryCopy`: `nil` → "Off"; 32_500/200_000 → "3.25% a year, 20% tax"; 40_000/200_000 → "4% a year, 20% tax"; 32_500/0 → "3.25% a year, no tax".
- [ ] **Step 2: Run it.** Expected: compile failure.
- [ ] **Step 3: Implement.**
  - `AccountInterestEditorView(account:)`: a `Form` with Toggle "Earns Interest", then (when on) "Interest Rate" and "Withholding Tax" text fields (decimal pad, "%" trailing label, tax prefilled 20). Footer: `interestFooter`. "Save" parses with `Rate.parse`, validates with `RateRules`, calls `setInterest`, and shows `LedgerAlert` on error. Follow `AccountEditorView` for the save and discard pattern.
  - `AccountDetailView`: an "Interest" section for active accounts, holding a row (`percent` symbol) with `interestSummary`. Tapping it opens the editor.
  - `RootView`: apply `.postingDueInterest()`.
  - `SampleData` (DEBUG only): turn interest on for one bank account at 3.25%, with `interestPaidThrough` three days before `now`, so the app posts sample interest at launch.
- [ ] **Step 4: Verify.** Run the class and confirm it passes. Build, then screenshot the account detail and the interest editor in light and dark with sample data. Look at the images. Then, by hand on the simulator with an on-disk store: turn interest on, set the simulator clock past 1:00 AM, bring Ledger to the foreground, and confirm the entries appear without relaunching.
- [ ] **Step 5: Commit:** `git commit -m "Add interest settings and daily catch-up"`

---

### Task 7: One row per day of interest

**Files:**
- Create: `Ledger/Formatting/HistoryItem.swift`, `Ledger/Components/InterestPostingRow.swift`, `Ledger/Features/Transactions/InterestPostingDetailView.swift`
- Modify: `Ledger/Components/AppRouter.swift`, `Ledger/Features/Dashboard/DashboardView.swift` (`recentSection`), `Ledger/Features/Transactions/TransactionListView.swift`, `Ledger/Features/Accounts/AccountDetailView.swift` (`transactionsSection`), `Ledger/Features/Accounts/AccountTransactionsView.swift`
- Test: `LedgerTests/InterestHistoryTests.swift`

**Interfaces:**
- Consumes: `EntryOrigin.interest`, `basisMinor`, `basisRatePPM`.
- Produces:

```swift
/// The automatic interest and tax entries posted at one moment, shown as one row.
struct InterestPosting: Identifiable {
    let postedAt: Date
    /// In the order given.
    let entries: [LedgerTransaction]
    var id: Date { postedAt }
    /// Income entries minus expense entries.
    var net: Money
}

enum HistoryItem: Identifiable {
    case transaction(LedgerTransaction)
    case interest(InterestPosting)
    var id: String
    /// Keeps the order of `transactions`, replacing every `.interest`-origin entry with one
    /// `InterestPosting` per `occurredAt`, placed where its first entry appears.
    @MainActor static func items(from transactions: [LedgerTransaction]) -> [HistoryItem]
}
```

- `LedgerRoute.interest(postedAt: Date, accountID: UUID?)` opens `InterestPostingDetailView(postedAt:accountID:)`.
- `InterestPostingRow(posting:showsDate:)` looks like `TransactionRow`: `percent` badge in the income tint, title "Interest", subtitle the account name (or "N accounts") with the time, value `net` signed. Accessibility label: "Interest, +₱2.90, Savings, <date>".
- `InterestPostingDetailView`: read-only. For each account in the posting, a section titled with the account name containing: "Balance" (the interest entry's `basisMinor`), "Rate" ("3.25% a year"), "Interest" (+gross), "Withholding Tax" (−tax), "Net". The footer is `AccountsCopy.interestFooter`. With an `accountID`, it shows only that account.

- [ ] **Step 1: Write failing tests.** Use the harness with the Manila calendar, two accounts with interest on (Savings 40_000, Reserve 25_000), and a third account, Wallet, with interest off. Record two Wallet expenses: one at 2026-03-16T01:00Z and one at 2026-03-15T04:00Z. Set the clock to 2026-03-16T02:00:00Z and call `postDueInterest()`, which posts day 15.

```swift
func testInterestAndTaxPostedTogetherFormOneItem()  // items(from: h.ledger.transactions()) kinds: [transaction, interest, transaction]; interest has 4 entries; net == Money(dec("2.90") + dec("1.81"))
func testAccountHistoryGroupsOnlyThatAccount()      // filtered to Savings → interest item with 2 entries, net 2.90
func testFilteredTypesKeepTheirSign()               // only expense entries → interest item net == Money(-(dec("0.72") + dec("0.45")))
func testDifferentDaysStaySeparate()                // after day 16 posts too → two interest items, newest first
```

Reserve's day 15: 2_500_000 → gross 226, tax 45, net 181.

- [ ] **Step 2: Run** `-only-testing:LedgerTests/InterestHistoryTests`. Expected: compile failure.
- [ ] **Step 3: Implement** the interfaces. Use `HistoryItem.items(from:)` in each list: Recent takes `prefix(recentLimit)` after grouping; Activity groups within each `TransactionDay`; the account screens group the account-filtered history (the account detail's limit counts items). Interest rows get no swipe actions or context menu.
- [ ] **Step 4: Verify.** Run the class and the full suite. Build, then screenshot Overview, Activity and the interest detail in light and dark with sample data. Look at them, and check that Recent is not flooded.
- [ ] **Step 5: Commit:** `git commit -m "Show daily interest as one row"`

---

### Task 8: Update Balance in the Ledger Menu

**Files:**
- Modify: `Ledger/Intents/LedgerEntities.swift` (`LedgerAction`), `Ledger/Intents/IntentFlows.swift`, `Ledger/Intents/LedgerIntents.swift` (`LedgerMenuIntent`)
- Test: `LedgerTests/IntentFlowTests.swift`

**Interfaces:**
- Consumes: `balanceCorrection`, `updateBalance`, `AccountsCopy`, `TransactionSummary`.
- Produces:
  - `LedgerAction.updateBalance`: title "Update Balance", subtitle "Match an account to its real balance", image "plus.forwardslash.minus", synonyms ["Adjust balance", "Real balance"]. Listed after `.balances`.
  - `IntentFlows.updateBalance(in ledger: LedgerService, account: AccountEntity?, amount: Double?, askAccount: Ask<AccountEntity>, askAmount: Ask<Double>, confirm: Confirm) async throws -> IntentOutcome`

The flow, in order:
1. `requireAccounts(1)`.
2. Account: use the given one or ask "Which account do you want to update?". An archived account throws `.ledger(.accountArchived)`.
3. Amount: `resolveAmount(amount, prompt: "What's <name>'s real balance?", …)`.
4. If `balanceCorrection` is `.alreadyMatches`, return headline "<name> already matches" with the account balance row, without confirming or saving.
5. Otherwise confirm with `.continue`: "Add a +₱4.00 balance adjustment to <name>?" or "Set <name>'s opening balance so its balance is ₱121.00?".
6. Call `updateBalance(of:to:origin: .appIntent)`.
7. Return headline "Balance updated". For an adjustment, the rows are the adjustment (title "Balance adjustment", subtitle "Adjustment · <name>", signed value) and "<name>" / "New balance". For an opening balance, only the account row. The body is the rows' text joined like `savedOutcome`.

- `LedgerMenuIntent`: add `Case(.updateBalance) { Summary("\(\.$action) of \(\.$account) to \(\.$amount)") { \.$resultRow } }`. The `DefaultCase` already lists every parameter. Add a `case .updateBalance` branch wiring `$account.requestValue` and `$amount.requestValue`. Change the description to: "Choose to log an expense, income, or a transfer, check your balances, or update a balance."

- [ ] **Step 1: Write failing tests** (GCash with opening 117 unless stated):

```swift
func testUpdateBalanceAsksAccountThenBalanceAndConfirms() // prompts ["Which account do you want to update?", "What's GCash's real balance?"]; confirmation contains "+₱4.00" and "GCash"; balance 121; headline "Balance updated"; rows titles ["Balance adjustment", "GCash"]; entry origin .appIntent
func testUpdateBalanceThatMatchesSavesNothing()          // amount 117 → no confirmation; headline "GCash already matches"; transactionCount 0
func testUpdateBalanceSetsAMissingOpeningBalance()       // opening nil → confirmation "Set GCash's opening balance so its balance is ₱121.00?"; openingBalanceMinor 12_100
func testDecliningAnUpdateSavesNothing()                 // confirm throws Declined → rethrows; transactionCount 0; balance 117
func testUpdateBalanceAsksAgainForAnEmptyAmount()        // amount 0 → asked once with the plain prompt
```

Match the existing tests' style: `UnexpectedPrompt` and `Declined`, with confirmation text checked by `contains` on the parts that don't depend on the formatter.

- [ ] **Step 2: Run** `-only-testing:LedgerTests/IntentFlowTests`. Expected: compile failure.
- [ ] **Step 3: Implement** the flow and the wiring.
- [ ] **Step 4: Verify.** Run the class and the full suite. Run `python3 scripts/check_sf_symbols.py`. Run the Shortcuts UI tests (`-scheme LedgerShortcutsUITests`), since the menu gained an item. They must pass as before.
- [ ] **Step 5: Commit:** `git commit -m "Add Update Balance to the Ledger Menu"`

---

### Task 9: Docs and final verification

**Files:**
- Modify: `README.md` (Features, Action Button flow, How it works → Balances), `PROJECT_STATUS.md` (Decisions, Verification evidence, Known limitations: the formula is inferred; ₱0 can't be entered from the menu)
- Modify, local only and never committed: `CLAUDE.md` (balance formula, `EntryOrigin.interest`, catch-up rule), `HANDOFF.md` (history, open item: confirm the rounding against more bank days)

- [ ] **Step 1: Update the docs** to describe what was built, in the docs' existing voice. Leave real balances out.
- [ ] **Step 2: Full verification.** Run a clean build and confirm zero warnings (`grep -c "warning:" .scratch/build.log` → 0). Run the full unit suite and confirm everything passes; report the count. Run `python3 scripts/check_sf_symbols.py` and the Shortcuts UI tests in light and dark (`test03_CheckBalances` screenshots). Look at every screenshot.
- [ ] **Step 3: Commit:** `git add README.md PROJECT_STATUS.md && git commit -m "Update docs for adjustments and interest"`
- [ ] **Step 4: Finish.** Use superpowers:finishing-a-development-branch. Pull requests go to `--base develop`, and only after the user approves the push.
