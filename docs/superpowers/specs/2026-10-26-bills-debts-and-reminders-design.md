# Bills, debts and due-date reminders

_Design, 2026-10-26._

## Why

Ledger tracks only money the user has: cash, bank accounts and e-wallets. The user also owes
money and pays regular bills, and wants all of it in one place:

- **Credit cards**, with a billing period, a due date, a credit limit and cashback. One card pays
  1% back on every purchase, credited right after the purchase; promos sometimes raise it to 2%.
- **Pay later** services such as SPayLater and TikTok PayLater, several at once. Each has a
  spending limit and a fixed due day. Some purchases are paid in full next month; others are
  split into monthly payments (3x, 6x).
- **Loans** for an item bought in a store, paid monthly over a fixed term (for example 12
  months, of which 6 are already paid).
- **Regular bills**: rent and internet at a fixed amount, and electricity and water, whose
  amount changes. Those bills arrive on a predictable day: the meter is read on the 17th, the
  bill comes on the 18th or 19th, and it's due on the 30th.

And it wants reminders that can't be missed. On the due day a Live Activity appears in the
Dynamic Island and on the Lock Screen. It can be snoozed, or the due can be moved for this month
only (rent due on the 25th, paid on the 30th this time), but it keeps coming back until the bill
is paid.

Much of this predates Ledger: the user already owes money and is partway through loans and
splits. Setting all of that up must be quick and must not count old spending twice.

## Goals

- One **Bills** tab lists everything owed and everything coming due, in separate groups: credit
  cards, pay later, loans and bills.
- Purchases on a card or a pay later account are logged like any expense, from the app or the
  Action Button, and count as spending in their category.
- Paying a card, pay later or loan is a transfer, and any transfer into it counts toward the due.
  No separate "mark paid" step is needed.
- Cashback is added automatically for every purchase on a card that has it.
- Existing debts, splits partway through and loans partway through can be entered as they are
  today.
- Due-date reminders that come back until paid, with snooze and move-this-due. They can be
  switched to plain notifications.

## Non-goals

- Connecting to banks or reading statements. Ledger stays offline.
- Minimum amount due, statement PDFs, credit scores.
- Credit card installment conversions (splits on a card). Only pay later and loans split.
- Cash loans as their own flow. A transfer from a loan into a bank account records one, but
  there's no setup screen for them in this round.
- Bills that repeat other than monthly (yearly subscriptions, quarterly dues).
- Matching an Action Button expense to a bill automatically.
- Reminders sent from a server. Everything is scheduled on the device.

## Anti-goals (failures even if the code works)

- A bill payment counted as spending, so a purchase and its payment count twice.
- An amount owed, a due amount or a bill amount Ledger made up.
- A reminder about a due date from before the account was added.
- An amount shown on the Lock Screen or in a notification.
- A purchase whose cashback outlives it, or a purchase edited without its cashback following.
- A failed save that records half of a split, half of a cashback change, or a payment without
  its bill link, or reports success anyway.

## Delivery

Two parts, each on its own branch and pull request:

- **Part A, bills and debts**: owed accounts, the due schedule, payment plans, cashback,
  regular bills, schema version 3, and the Bills tab.
- **Part B, reminders**: notifications, the Live Activity, snooze, move this due and strict
  mode. It needs Part A's due math.

Schema version 3 (Part A) includes the fields Part B needs, so Part B adds no schema version.
The deployment target stays iOS 26.0, and no iOS 27-only API is used.

## Owed accounts

Decided with the user:

- Three new account kinds: **Credit card**, **Pay later** and **Loan**. They hold what the user
  owes, not what they have.
- A purchase on a card or pay later account is an **expense** in its category (Food, Shopping).
  It counts as spending, and what the user owes rises.
- Paying the bill is a **transfer** from a money account into the owed account. It isn't
  spending.
- Owed accounts live in the Bills tab and stay out of the total balance.

Builder's calls:

- `AccountKind` gains `.creditCard`, `.payLater` and `.loan`. They're stored as raw values, so
  the kind itself needs no migration. `countsTowardLiquidTotal` is `false` for them. A new
  `isOwed` property groups them.
- **The balance math doesn't change.** `BalanceCalculator` stays as it is. An owed account's
  balance is negative while money is owed, and screens show `owed = −balance`. A positive
  balance shows as a credit ("₱120.00 credit"). Refunds are income into the card.
- The Accounts tab lists only money-you-have accounts. Owed accounts appear in the Bills tab.
- Every account picker, in the app and in App Intents, includes owed accounts.
  `AccountEntityQuery` doesn't filter them out. A transfer *from* an owed account records a
  card cash advance or a cash loan paid into the bank: what's owed rises, and it isn't income.
- An account can't switch between a money kind and an owed kind after it's created.
- Daily interest isn't offered on owed kinds. Finance charges and late fees are logged by hand
  as expenses on the owed account.

### Setting one up

Cards and pay later ask for two numbers that their apps already show:

- **Total you owe now.** This sets the opening balance: `opening = −total − recorded activity`.
  It's the same calculation Update Balance uses on an account with no opening balance, with the
  sign flipped.
- **Still due on <next due date>**: the unpaid part of the bill already issued, or zero. It's
  stored as that cycle's `DueOverride.amountMinor`. For that first due,
  `left = max(0, amount − payments since setup)`. Later dues use the normal formula (below).

Due dates from before the account was added are ignored. They're never overdue and never
reminded. Loans don't ask for these numbers; their plan sets the opening balance. A `nil`
opening balance still means "not set" and is never treated as zero.

Three helpers refuse a negative balance today:
- `AmountRules.openingBalanceMinorUnits` throws `openingBalanceNegative`.
- `openingBalanceMinorUnits(forCurrentBalance:of:activity:)` throws `balanceBelowRecordedActivity`.
- `balanceCorrection(toReach:for:)` throws `balanceNegative`.

For owed kinds they become sign-aware: the user enters an amount owed of zero or more, and it's
stored negated. A result past zero is allowed, and shows as a credit. Money-you-have accounts
keep today's rules.

Old purchases logged after setup move the total, as backdated entries already do for every
account. The owed account's screen has **Update what you owe**, a sign-aware
`balanceCorrection` / `updateBalance`, to match the bank again.

## Due schedule

Cards, pay later and loans share one schedule.

- **Fields on `Account`:**
  - `statementDay: Int?` (1–31), for cards and pay later. Pay later defaults to the last day of
    the month.
  - `dueDay: Int?` (1–31).
  - `creditLimitMinor: Int64?`, labeled "Credit limit" on cards and "Spending limit" on pay
    later.
- **Day 31** in a shorter month means the month's last day. A due date is the first `dueDay`
  strictly after its statement date.
- **Days** are `CalendarDay`: Gregorian calendar days in the device's time zone, whatever
  calendar system the phone uses.

**Amount left for a due date D.** It's computed without storing anything, so a payment made
from the Action Button counts as soon as it's logged:

```
left(D) = max(0, owedNow − nextCycleCharges(D) − scheduledSlicesAfter(D))
```

- `owedNow` is the account's current balance, negated.
- `nextCycleCharges(D)` is the net of expenses that aren't part of a plan, and their cashback,
  dated after D's statement closed. It's zero for loans.
- `scheduledSlicesAfter(D)` is the plan slices due after D.

Example: a loan of 12 × ₱2,400 with 6 paid is owed ₱14,400. The 5 slices after the next due
come to ₱12,000, so ₱2,400 is left for this due. Paying early or overpaying needs no stored
"paid" flags.

**Overdue**: today is past the due date (or its moved date) and `left > 0`. An unpaid amount
also carries into the next due, because `owedNow` still includes it.

**Available credit** = limit − owed. For pay later, owed includes future slices.

## Payment plans

Pay later splits and loans are payment plans.

- **New model `PaymentPlan`:**
  - `id`, `account`, `title`, `createdAt`
  - `monthlyMinor`, `months`, `paidAtStart`
  - `lastMinor`: defaults to the monthly amount, and is set when the app's last payment
    differs (₱1,000 in 3 is ₱333.34, ₱333.33, ₱333.33)
  - `firstDue`, as yyyymmdd
  - the IDs of its purchase and fee entries
- **Slices**: the `months − paidAtStart` remaining payments, on the account's due dates from
  `firstDue`.
- **Total** = `monthly × (months − 1) + last`.
- **Fees** = total − price. If that's zero there's no fee entry. Below zero, the plan is
  refused with a plain error.

**New split.** The pay later expense editor offers **Split into N months** and asks for the
monthly amount the app showed. One save records:
- the price as the expense in its category
- the fees as a **Fees and interest** expense (category `nil`, `EntryOrigin.planFees`, not
  editable)
- the plan, whose first slice falls on the next due date after the purchase's statement closes

**Existing split or loan partway** (6 of 12 paid, ₱2,400 a month, next due Nov 8):
- It creates the plan only, with no expense, because that spending happened before Ledger.
- A new loan account's opening balance is the remaining slices, negated.
- On pay later, the total entered at setup already includes it.

**New loan for an item.** A loan account and a plan. The price is the expense in its category
and the extra is fees. The opening balance is zero.

**Months paid.** These come from the due math rather than from payments, so two plans on the
same pay later account never share credit for one payment.
- Find the latest due date P, past or upcoming, with `left(P) = 0`.
- Months paid = `paidAtStart` + this plan's slices due on or before P.
- This works because `left` is cumulative: if a due is paid, every earlier one is too.
- The finish month is the date of the last slice.

**Editing.** A plan can't be edited, only deleted. Deleting it deletes its own purchase and fee
entries in the same save.

## Cashback

Decided with the user: 1% of every purchase (2% during a promo), credited right after the
purchase, rounded down to the centavo. Ledger adds it automatically.

Builder's calls:

- Cards have `cashbackRatePPM: Int64?` (`Rate`, `RateRules`; 1% is 10_000). `nil` means no
  cashback.
- **Logging a purchase** on a card with cashback records an `income` entry in the same save:
  - origin `EntryOrigin.cashback`, the same `occurredAt`, category `nil`
  - `basisMinor` = the purchase amount, `basisRatePPM` = the rate, `sourceTransactionID` = the
    purchase
  - amount = purchase × rate, rounded down
- **Changing the purchase**, each in one save, with the usual rollback and refresh:
  - Editing it recalculates the cashback at the rate stored on the cashback entry.
  - Moving it to another account removes the cashback.
  - Deleting it deletes the cashback.
- **Promos**: changing the rate applies to purchases logged after the change.
- **No cashback** on plan purchases, fees and transfers.
- **Reporting**: cashback counts as income, as interest does. Lists show it inside the
  purchase's row ("₱5.00 back") rather than as a row of its own. It isn't editable.

## Regular bills

Decided with the user:
- Bills are rent, internet, electricity, water and subscriptions, monthly.
- A bill's amount is either fixed or varies. A varying bill has a usual arrival day.
- **Paid** records the payment.
- A due can be moved for one month only.

Builder's calls:

- **New model `Bill`:**
  - `id`, `name`, `category` (expense), `dueDay`, `payFrom: Account?`
  - `amountMinor: Int64?`, where `nil` means it varies
  - `arrivesDay: Int?`, for varying bills only
  - `isArchived`, `sortOrder`, `createdAt`, `startCycle`
- **New model `DueOverride`**, shared with owed accounts:
  - `ownerID`: an account or a bill
  - `cycle`: the yyyymm of the original due
  - `movedTo: Int?`, as yyyymmdd
  - `amountMinor: Int64?`: a varying bill's amount this month, or an owed account's "still due"
    at setup
- **Paid** records an expense in the bill's category from the chosen account, tagged with
  `billID` and `billCycle` on `LedgerTransaction`.
  - A cycle is paid once its tagged payments reach its amount.
  - Deleting the payment makes the bill unpaid again.
  - Nothing else is stored.
- **A varying bill** with no amount yet shows **Amount not set**. Ledger never guesses one.
- **Not debt.** Bills stay out of Total you owe and appear in Coming up.

## Schema version 3

`LedgerSchemaV3`, with a lightweight stage from version 2. Every new property is optional or has
a default.

- `Account`: `statementDay`, `dueDay`, `creditLimitMinor`, `cashbackRatePPM`,
  `strictReminder: Bool = true`.
- `LedgerTransaction`: `sourceTransactionID`, `planID`, `billID`, `billCycle`.
- New models: `PaymentPlan`, `Bill` (also with `strictReminder: Bool = true`), `DueOverride`.

The type aliases move to version 3. A migration test opens a real version 2 store, the way
`SchemaMigrationTests` opens version 1.

## Screens

Decided with the user: a fifth **Bills** tab. It has **Coming up** at the top, then credit cards,
pay later and loans, then **Total you owe**.

Builder's calls:

- **Bills tab** (`AppTab.bills`, between Accounts and Settings, `-LedgerInitialTab bills`):
  - **Coming up**: the next due of every owed account and bill, overdue first. Each shows "₱X
    left", "Paid" or "Amount not set".
  - Then four groups: Credit cards, Pay later, Loans and Bills.
  - **Total you owe** at the bottom.
  - An **Add** menu for each kind.
- **Owed account screen**:
  - what's owed, the limit and what's available
  - this period's spending
  - the last statement, with its due and what's left or paid
  - plans with "3 of 6 paid"
  - **Update what you owe**
  - **Pay**: a transfer prefilled with what's left
- **Bill screen**:
  - the amount, or **Set this month's amount** for a varying bill
  - the due date and the payment history
  - **Paid** and **Move this due**
- **Overview**: a "You owe" line and the next due.
- **App Intents**:
  - **Update Balance** in the Ledger Menu, on an owed account, asks "What do you owe on X?" and
    is sign-aware. ₱0 still means "not supplied" there.
  - **Check Balances** keeps its money-account rows and adds a **You owe** row and a **Next
    due** row.

## Reminders (Part B)

Decided with the user:

- **On the due day**, a Live Activity appears in the Dynamic Island and on the Lock Screen.
- **Snooze** hides it for a while. **Move this due** changes this month's due date only.
- **Not paid**: it comes back every day until the bill is paid. Only paying ends it.
- **Strict reminders are optional.** There's a switch in Settings and a toggle on each bill or
  debt. With strict off, the user gets plain notifications they can dismiss: a heads-up, the due
  day, and one each overdue day.
- **No amounts** on the Lock Screen or in notifications, only names and dates ("Rent · due
  today", "Pay later · 2 days overdue").
- **Varying bills** get a notification on their arrival day ("Check if your electricity bill
  came in"), repeated daily until the amount is entered.

Builder's calls:

- **One Live Activity** covers everything due that day ("2 bills due today", overdue marked).
  - It's scheduled ahead with `Activity.request(…, start:)` (iOS 26), so it starts even when
    Ledger isn't running.
  - It can only be scheduled from the foreground or from a `LiveActivityIntent`.
  - Its UI lives in a new widget extension in `LedgerWidgets/` (a synchronized folder), with
    `NSSupportsLiveActivities` set.
  - The activity attributes and the button intents are shared with the app target.
- **Buttons** are `LiveActivityIntent`s, which run in the app's process:
  - **Paid** opens the app to a prefilled payment. Nothing moves money in one tap from the Lock
    Screen.
  - **Snooze** offers 1 hour or 3 hours. It ends the activity and schedules it to come back.
  - **Move this due** opens the app to a date picker that writes a `DueOverride`.
- **Opening the app**: Paid and Move this due run in foreground mode (`supportedModes`) and set
  an `AppRouter` route. The fallback is a `Link` with a URL scheme and `onOpenURL`.
- **Alerts**: each scheduled start's `AlertConfiguration` carries no amounts either.
- **Coming back**: iOS lets the user swipe the activity away and ends any activity after about
  8 hours.
  - On each due or overdue day, the planner schedules a start at the reminder time (default
    9:00 AM, set in Settings) and another 8 hours later.
  - When the app becomes active, or an intent runs, while something is due and unpaid, it starts
    an activity right away.
  - The activity ends as soon as everything due is paid.
- **Intents**: the Ledger Menu and the logging intents adopt `LiveActivityIntent`, so a run can
  start or reschedule a reminder in the background. If that clashes with their current behavior,
  they only update or end the activity, and starts happen when the app becomes active.
- **Notifications**: local only (`UNUserNotificationCenter`).
  - one when each Live Activity starts, in case Live Activities are off
  - one the day before a due date
  - the arrival-day notification for varying bills
  - Permission is requested when the first due date is set.
- **Strict mode**: an item is strict when the Settings switch is on and its own toggle is on.
  Both default to on.
- **`ReminderPlanner`** is a pure function. It turns the dues, overrides, snoozes, strict
  settings, the current time and the calendar into the notifications and Live Activity starts
  to schedule.
  - A small `ReminderScheduler` applies the result.
  - It runs on the same triggers as the interest catch-up and `IntentLedger.service()`, and
    after any save that changes a due.
  - Snoozes are kept in `UserDefaults`.
- **iOS 27**: the landscape Dynamic Island on iOS 27 uses the same compact and minimal views. The
  Apple Watch Smart Stack and CarPlay come from `supplementalActivityFamilies([.small])`, which
  is iOS 18 API.

## Constraints

- No network, accounts, analytics or third-party code. Reminders are scheduled on the device.
- **Money** is `Int64` centavos and calculated as `Decimal`. **Rates** are parts per million.
  Never `Double`.
- **Writes**: every financial write goes through `LedgerService` and commits before returning.
  A failed save rolls back, refreshes loaded models and throws.
- **Logs**: never log amounts, balances, names, notes or references.
- **Tests**: behavior changes come with tests, using made-up amounts. The 12 required ledger
  tests keep passing.
- **Builds**: zero warnings. SF Symbols available on iOS 26 only.

## Left to the builder

- The exact layout and wording of each screen, within the conventions (sentence case,
  `MoneyFormatter`).
- How plan-linked purchases are shown in lists, and whether they can be opened.
- How far ahead reminders are scheduled. Live Activity starts count toward the system's limit
  on ongoing activities.
- The Paid flow for a varying bill with no amount yet: ask for this month's amount first.
- Whether the statement day itself falls in the closing cycle. Inclusive is suggested.
