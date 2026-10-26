# Pay later limit and fees

_Design, 2026-10-26._

## Why

A pay later account shows two numbers in its own app: what the user has to repay, and how much
of the spending limit is left. Ledger shows only one. It works out "Available" as the limit less
everything owed (`DueCalculator.availableCredit`), so the fees a pay later service adds to a
purchase lower the available limit in Ledger but not in the service's app. The user saw the two
disagree by exactly the fee on their first TikTok PayLater purchase.

What the services do, from checkout screens the user compared:

- The fee is charged on top of the price and doesn't use the limit. The available limit falls by
  the item's price only.
- TikTok PayLater charges a fee each month of about 5% of the price, whatever the number of
  months: each payment is the price split evenly (rounded to the centavo) plus the same monthly
  fee. "1×" is the whole price plus one month's fee.
- The fee isn't exactly 5% rounded one way: one price's fee rounds up and another's rounds down.
  No rate reproduces every payment to the centavo, so payments must be entered as the app shows
  them, not worked out from a rate.
- Everything bought in a statement period is due on the same date. With the statement closing on
  the last day of the month and payments due on the 16th, a purchase on October 26 is due
  November 16 and one on November 1 is due December 16. A 1× purchase is one payment on that
  date. `DueSchedule.billingCycle` already does this.

Ledger also can't record a 1× purchase with a fee as a split today: splits start at 2 months.

## Goals

- A pay later account's **available limit** matches the service's: the limit less what's owed,
  not counting fees that aren't paid yet.
- **What's owed** stays the full amount to repay, fees included, everywhere it's shown or used.
- A purchase paid in full next month with a fee (1×) can be logged as a split, so its fee is
  known.
- A split already under way, added with Add a Split, can say what the item cost, so its fees are
  known too.
- While splitting a purchase, the user sees the fee per month and as a share of the price, to
  catch a typo against the service's checkout screen.
- Services differ: the user tracks several pay later services (TikTok PayLater, SPayLater) and
  only TikTok's behavior is known. Each pay later account has a **Fees Use the Limit** switch,
  off by default, for a service that does count its fees or interest against the limit.

## Non-goals

- Storing a fee rate, or filling in payments from one.
- Late fees and other charges outside a split. They keep counting against the limit, as today.
- Credit cards. Banks count interest and fees against a card's limit, so cards keep limit less
  owed. Cards can't have splits, so nothing about them changes.
- Loans. They have no limit.
- A utilization percentage, or available limit in Shortcuts.

## Anti-goals (failures even if the code works)

- Any change to what's owed, Total You Owe, dues, Coming Up, reminders, payments, cashback,
  spending totals or any other account.
- A due left at ₱0.01 after paying what the service asked, so a strict reminder never goes away.
- An available limit made from a guess. If Ledger doesn't know a split's fees, they count
  against the limit, as today.
- An available limit above the limit while something is still owed.

## Constraints

From the project: iOS 26 API only, Swift 6 strict concurrency, zero warnings. Money is `Int64`
centavos calculated as `Decimal`, never `Double`. Dues stay stateless: nothing stored about
payments. `LedgerService` is the only writer. Schema changes get a new `VersionedSchema` and a
lightweight stage, and keep every record. Test fixtures use made-up amounts, never the user's
real purchases or limit. No amounts in logs.

## Design

### Limit used

For a pay later account with a limit and Fees Use the Limit off (every other account, and a pay
later account with the switch on, keeps limit used = owed):

- **Unpaid fees of a plan** = its fees − its fees × months paid ÷ months, in centavos, with the
  paid part rounded down. That's all of the fees before any payment and zero once every
  payment is made. Months paid is `DueCalculator.monthsPaid`, which already counts payments
  made before the plan was added.
- **Limit used** = owed − the plans' unpaid fees, but the fees taken off never exceed what's
  owed, so limit used never drops below zero because of fees. When owed is zero or less (a
  credit), nothing is taken off.
- **Available** = limit − limit used. `nil` without a limit or a known balance, as today.

Each paid month gives back its share of the price, the same way the service is assumed to (see
Open questions). Paying part of a due lowers what's owed and so raises the available limit by
that amount; the fees stay counted until the due is fully paid.

### Where a plan's fees come from

- A split logged in Ledger: its fees entry (`EntryOrigin.planFees`, `PaymentPlan.feesID`), the
  difference between its payments and the price. None means zero fees.
- A split added with Add a Split with an item price: its payments' total less that price, stored
  on the plan.
- A split added without a price, a loan, or any plan from before this change without a fees
  entry: unknown, treated as zero, so its whole amount counts against the limit as today.

### Schema

`LedgerSchemaV4` adds two fields, with a lightweight stage V3 → V4; the type aliases move to V4:

- `PaymentPlan.feesMinor: Int64? = nil`: the fees of a plan that has no fees entry, worked out
  from the item price entered when it was added. `nil` means not known.
- `Account.feesUseLimit: Bool = false`: whether the service counts fees against the limit. Read
  only for pay later accounts.

### Fees Use the Limit

- When on, limit used is everything owed, the same as today and as a credit card. Unpaid fees
  aren't taken off and the account screen's fees footer doesn't show.
- A switch in the pay later account editor (adding and editing), under the limit, with a footer
  such as: "Turn on if this service's available limit goes down by its fees or interest too."
  Credit cards and loans don't show it.
- Changing it changes only the available limit; plans and their fees stay as they are, so
  turning it off again restores the earlier figure.

### Splitting a purchase (transaction editor)

- Months go from 1 to 60 for pay later, in the editor and in `LedgerService.splitMonths`. At 1
  month the only payment is due on the account's next due date for the purchase's statement, as
  for any split.
- Each payment is entered as the service shows it, as today. At 1 month there's no "last payment
  is different".
- The footer adds the fee per month and as a share of the price when the payments cost more than
  the price, for example: "You'll pay ₱1,100.00 in all: ₱100.00 more than the price, recorded as
  fees and interest. That's ₱50.00 a month, 5% of the price." The share is rounded to one
  decimal place and drops a trailing ".0". When the fees don't divide evenly by month, the
  monthly figure is the average.
- The prompt before splitting mentions paying next month as well as 3, 6, or more months.

### Add a Split (pay later only)

- Months go from 1 to 60.
- A new optional **Item Price** field. When filled, the plan's fees are the payments' total less
  the price, and it's rejected with the existing `planTotalBelowPrice` error if the payments add
  up to less than the price. When left empty, fees are unknown.
- The footer says the price lets Ledger work out the available limit, since fees don't use it.
- Loans' Add Payments sheet doesn't show the field.

### Account screen and Bills tab

- The limit section shows the limit and Available from the new calculation. When unpaid fees
  are taken off, its footer says how much of what's owed is fees that don't use the limit, for
  example: "₱100.00 of what you owe is fees, which don't use your limit."
- The Bills tab's "₱X left of limit" line uses the same calculation.
- The header still shows the full amount owed.

## Tests

Made-up amounts only. At least:

- A card with no plans: available is limit − owed, unchanged.
- A split with fees: available is limit − price; after the first of three dues is paid, two
  thirds of the fees are still taken off; after the last, available equals the limit.
- A 1× split records the price and fees entries and one payment on the right due date, and
  available is limit − price.
- Fees that don't divide evenly by month reach exactly zero on the last payment.
- Add a Split with a price stores its fees and lowers limit used; above the total it throws
  `planTotalBelowPrice`; without a price nothing changes.
- Unpaid fees larger than what's owed (after Update What You Owe lowers it) never make limit
  used negative; a credit balance takes nothing off.
- Deleting a split brings available back to limit − owed.
- With Fees Use the Limit on, available is limit − owed even with unpaid fees; turning it off
  takes them off again. Creating and editing a pay later account saves the switch.
- The V3 → V4 migration keeps every record, with `feesMinor` empty on existing plans.
- Existing due, payment, cashback and reminder tests keep passing unchanged.

## Calls made in this design (not the user's)

- Each paid month gives back its share of the price (pro-rata), rather than nothing until the
  plan is fully paid.
- Fees of a split logged in Ledger come from its fees entry; `feesMinor` is only for plans with
  no fees entry, so each plan has one source.
- Unknown fees count against the limit, matching today's behavior.
- Item Price is optional and shown for pay later only, whatever the Fees Use the Limit switch
  says, so the fees are known if the switch is turned off later.
- Fees Use the Limit is off by default, matching the one service whose behavior is known.
- The share of the price is shown to one decimal place.

## Open questions

- How the service gives back the limit on a split of several months: by each payment's share of
  the price (assumed), or only when the whole split is paid. The user will check after a real
  multi-month purchase. If it's the latter, the per-plan rule changes: limit used would also add
  back the price of months already paid until the split is done. Builder's call: keep the
  per-plan calculation in one function so that switch stays small.
- Whether the service puts the price's leftover centavo in the last payment. The editor already
  has "last payment is different" for that.

## Fixing purchases already in Ledger

Not code; for the user after the update:

- A purchase logged as one expense of the full amount: delete it and log it again as a split,
  1× or more, with the price and the payment the service shows.
- A purchase included in the account's opening "Total You Owe Now": add it with Add a Split, with
  its item price and next payment date.
