# Balance adjustment and daily interest

_Design, 2026-10-20._

## Why

The user's savings accounts pay interest every day. The bank credits it around 1am the next
day as two lines: the gross interest and the 20% withholding tax. Small amounts like this, and
cashback, never get logged, so Ledger's balance drifts away from the real one.

Two features fix this:

1. **Balance adjustment.** The user types the real balance and Ledger records the difference
   as one adjustment entry. This is the general fix for any drift.
2. **Daily interest.** Ledger posts each day's interest and tax itself, so balances on
   interest-bearing accounts stay close to the bank's without any typing.

The two work together. Interest keeps the balance close, and an adjustment absorbs whatever
centavos the interest estimate gets wrong.

## Goals

- Typing the real balance of an account brings Ledger to exactly that balance in one step.
- Accounts that earn interest gain it automatically, day by day, matching the bank to the
  centavo on most days.
- Both work from the Action Button through the Ledger Menu, as well as inside the app.

## Non-goals

- Connecting to banks, reading statements, or fetching rates. Ledger stays offline.
- Guaranteeing an exact match with the bank. The formula is inferred from observation (below).
- Tiered rates, promo rates that depend on balance, and interest credited monthly or
  quarterly. Only a flat annual rate credited daily is supported.
- Recalculating interest that was already posted.
- Interest for days before the user turned it on.

## Anti-goals (failures even if the code works)

- An adjustment showing up as income or spending in the month's totals.
- Interest invented for an account whose balance Ledger doesn't know.
- The same day's interest posted twice, or an entry dated in the future.
- A failed save that leaves some days posted and others not, or reports success anyway.

## Balance adjustment

Decided with the user:

- The account screen gets an **Update balance** action. The user enters the real balance.
  Ledger compares it with its own current balance and records one entry for the difference,
  labeled **Balance adjustment**: +₱4.00 when the real balance is higher, −₱7.00 when it is
  lower.
- The entry is dated now and appears in the account's history like any other entry. Deleting
  it undoes the adjustment.
- Adjustments are **not income or spending**. They are left out of income, expense and net
  totals, and out of category breakdowns. They do change the account's balance and the liquid
  total.
- If the account has **no opening balance yet**, entering the real balance sets the opening
  balance instead (the same calculation first-run setup uses,
  `openingBalanceMinorUnits(forCurrentBalance:of:activity:)`), and no adjustment is recorded.
- If the real balance already matches, nothing is recorded and the user is told it matches.

Builder's calls: how the adjustment is modeled (a new transaction kind, a flag, or a new
origin), whether an adjustment can be edited or only deleted, the confirmation wording, and the
symbol for adjustment rows.

## Daily interest

Decided with the user:

- **Any account** can earn interest, not only banks (e-wallet savings pay daily interest too).
  It is off until the user turns it on in the account's settings.
- Settings per account: the **annual rate** (for example 3.25%) and the **withholding tax
  rate**, which defaults to 20%, the Philippine final tax on deposit interest.
- **Formula, per day:** gross interest = the account's balance at the end of that day ×
  annual rate ÷ **360**, **rounded up** to the centavo. Tax = gross × tax rate, rounded to the
  nearest centavo. The user can't get the bank's exact formula. One observed day matched
  "÷ 360, rounded up" and did not match "÷ 365". The user will compare more days against the
  bank, so keep the day-count and both rounding rules in one small, well-tested function that
  is easy to change.
  - Example: ₱40,000.00 × 3.25% ÷ 360 = 3.6111… → gross **₱3.62**; tax 20% = 0.724 →
    **₱0.72**; net ₱2.90.
- Each day's interest posts as **two entries**, matching the bank's two lines: **Interest**
  (+gross) as income and **Withholding tax** (−tax) as an expense. Both are dated **1:00am the
  next day** in the device's time zone. Both count in income and spending totals, since both
  are real money.
- Interest compounds the way the bank's does: day D's interest posts at 1am on day D+1, so it
  is part of D+1's ending balance.
- **Interest starts the day it is turned on.** That day's ending balance earns the first
  interest, posted at 1am the next day. No earlier days are filled in.
- **A rate change counts from the day it's made.** Earlier days keep the old rate.
- **No interest** on a day whose ending balance is zero, negative, or unknown (no opening
  balance). The day still counts as done.
- **Interest that's already posted stays as it is.** If the user logs a backdated entry after
  that day's interest has posted, Ledger doesn't recalculate. The next balance adjustment
  absorbs the difference.

### How interest shows up

Decided with the user: interest and tax **show as one row**, and tapping it opens a detail
view. The two entries still exist separately underneath, so totals keep counting interest as
income and tax as an expense.

My calls:

- **One row per day, in every list.** The row covers all of that day's interest across
  accounts, so it's one row in Overview's Recent and in Activity however many accounts earn
  interest. In an account's history it covers only that account. It shows the net amount
  (for example "Interest · +₱2.90") and is dated 1am like the entries.
- **The detail view** lists, per account: the balance the interest was calculated on, the rate,
  gross interest, withholding tax, and net. Seeing the balance used helps the user compare
  with the bank and confirm the formula.
- The detail view is read-only. Automatic entries can't be edited one by one; any difference
  from the bank is fixed with Update balance.

Builder's calls: whether the grouping is a stored record or computed when lists are built, and
the row and detail layouts (matching the existing rows and native iOS style).

### Catch-up

Ledger has no server or background job, so it can't post at 1am. It **catches up** instead:

- Each account with interest on remembers the last day it has posted interest for.
- Whenever Ledger opens or comes to the foreground, and before any App Intent reads or changes
  data, it posts every completed day since then, in order, each calculated on that day's
  balance (including the interest posted earlier in the same catch-up).
- Day D is complete, and can post, only once it's past 1:00am on D+1. Nothing is ever dated in
  the future.
- A catch-up is one save. If the save fails, nothing from it is kept, the failure is reported
  the usual way, and the next catch-up tries again. Re-running a catch-up never posts a day
  twice.
- Changing the rate, the tax rate, or turning interest off first catches up the completed days
  at the old settings, then applies the change to every day not yet posted. So a change made
  between midnight and 1am also covers the day that just ended, and turning interest off in
  that hour means that day earns nothing. (My call: it keeps one setting per account instead
  of a history of rates, for a one-hour window.)
- An Update balance runs a catch-up first, so the adjustment is measured against a balance that
  already includes the interest due.

My calls (made while writing this, not discussed with the user):

- **Archiving an account works like turning its interest off**: catch up first, then stop.
  Unarchiving leaves interest off until the user turns it on again, so no skipped days get
  filled in. An archived account's entries still count in totals, so leaving interest running
  would put entries from a hidden account into the month's income and spending.
- When the tax rounds to ₱0.00, only the Interest entry posts. Rounding up means a positive
  balance always earns at least ₱0.01 gross.
- On an account with no opening balance, a real balance lower than the recorded activity shows
  the existing `balanceBelowRecordedActivity` error.
- The existing Current Balances sheet on Overview stays as it is.

Builder's calls: where the "last day posted" marker lives, how interest and tax entries get
their income source and expense category (seeded names must not be relied on, per the project
rules), how they're marked as automatic, whether a catch-up spanning many months needs a cap,
and how balance-at-end-of-day is computed.

## Ledger Menu (Action Button)

Decided with the user: the **Ledger Menu** gains an **Update balance** action.

- Flow: choose the account, enter the real balance, confirm, then the system result list shows
  the account's new balance and the adjustment made (or that the opening balance was set, or
  that it already matched).
- It follows the existing intent rules in `CLAUDE.md`: logic in `IntentFlows` with scripted
  closures in tests, every parameter in every `parameterSummary` case, results through
  `ResultList.show`.
- Shortcuts passes 0 for an empty amount, and the project treats 0 as "not supplied". So a real
  balance of exactly ₱0 can't be entered from the menu; it can be from the app.

Builder's call: whether to also add a standalone Update Balance intent and App Shortcut next
to the existing Log Expense, Log Income and Transfer ones.

## Constraints

- All writes and balance calculations go through `LedgerService`. Each change commits before
  returning; a failed save rolls back, refreshes loaded models, and throws.
- Money is `Int64` centavos and `Decimal` maths. Rates are stored exactly too: no `Double` for
  rates or money.
- New stored fields need `LedgerSchemaV2` and a migration stage in `LedgerMigrationPlan`.
  Existing data must survive; never drop or delete the store.
- Log with `Log`, never logging amounts, balances, rates, names or notes.
- iOS 26 API only, SF Symbols checked by `scripts/check_sf_symbols.py`, zero warnings.
- Unit tests with `LedgerHarness` and `TestClock` cover the formula and rounding, multi-day
  catch-up and compounding, the 1am cutoff, rate changes, turning interest on and off, zero,
  negative and unknown balances, no double posting, rollback on a failed save, adjustments up,
  down, equal and on an account with no opening balance, totals excluding adjustments, and the
  menu flow. The required `LedgerServiceTests` cases keep passing.
- The repo is public: no real balances, account details or screenshots in code, tests or docs.

## Left to the builder

Everything marked "builder's call" above, the screen layouts (matching the existing account
screens and native iOS style), copy (sentence case, plain words, amounts through
`MoneyFormatter`), and the build order. Suggested order: balance adjustment, then daily
interest, then the menu action.
