# Project Status

_Last updated: 2026-10-13_

## Environment

- macOS 26.6.2, Xcode 27.0 (27A266a), iOS 27.0 SDK, Swift 6.4 in Swift 6 language mode with
  strict concurrency checking.
- iOS 26.5 simulator (iPhone 17 Pro). Simulator builds are signed without a team.
- An iPhone 16 Pro on iOS 26, with the author's development team.
- Deployment target iOS 26.0, iPhone only, portrait. No iOS 27-only APIs.

## Phases

| Phase | Status | Evidence |
|---|---|---|
| 1. Project foundation | Done | Native Xcode project with synchronized folders, app, unit-test and UI-test targets, shared schemes |
| 2. Ledger engine | Done | `LedgerService`, `BalanceCalculator`, versioned SwiftData schema; unit tests below |
| 3. Main application | Done | Overview, Activity, transaction detail and editor, Accounts, account detail and editor, onboarding, Settings, category management, Action Button guide, data and privacy page, credits |
| 4. App Intents and Shortcuts | Done; partly verified on a device | 5 App Shortcut intents plus Log From Message (bank emails through a Shortcuts automation), 3 entities, 1 enum, results in the system list |
| 5. Integration and validation | Done | Builds, tests, screenshots, two independent reviews, simulator end-to-end runs, runs on an iPhone 16 Pro |
| 6. Documentation | Done | `README.md`, `CONTRIBUTING.md`, `PRIVACY.md`, `LICENSE` (MIT), this file |

## Verification evidence

- **Unit tests:** 181 pass, 0 fail (`xcodebuild … -scheme Ledger test`). The 12 required cases
  are in `LedgerTests/LedgerServiceTests.swift`. Other suites cover rollback after a failed save
  for every kind of change, idempotency, time zones, parsing and formatting, onboarding setup,
  Activity search and filters, the bank-email reader, the App Intent flows and the result list.
- **Builds:** Debug and Release for the simulator and an arm64 iPhone build, all with zero
  warnings. App Intents metadata is extracted at build time.
- **Screens:** every screen checked in light mode, dark mode and at accessibility text sizes.
- **Reviews:**
  - A correctness and data-safety review found no critical or major defects. Its 4 minor findings
    are fixed: onboarding counting entries twice, a partial onboarding save, a missing removal
    confirmation, and the editor's default date.
  - A spec, UX and privacy audit found a critical runtime bug: Ledger Menu stopped after an action
    was chosen. That bug and the actionable smaller findings (contrast, Dynamic Type, copy,
    consistency) are fixed.
- **Simulator end to end:** the `LedgerShortcutsUITests` scheme drives Apple's Shortcuts app.
  Verified: shortcut registration; Check Balances and its result list in light and dark; amount
  entry, validation and exact centavos (19.99 and 0.10 accepted, 12.345 asked for again); Ledger
  Menu → amount; category and account lists appearing; cancelling saving nothing. Steps after
  choosing a category or account are skipped there, because iOS refuses entity prompts for builds
  signed without a team.
- **iPhone 16 Pro:** Ledger Menu, Log Expense and Check Balances ran from the Home Screen, and
  the expense saved with the right new balance.

## Decisions

- **Money:** stored as whole centavos (`Int64`) and calculated with `Decimal`. The Shortcuts amount
  field delivers a `Double`, which is converted exactly through its shortest decimal text.
- **Amount prompt:** a number field. A currency-typed field took 6 taps to log ₱250 instead of 4,
  and Shortcuts crashed once in its quantity-field code.
- **Results:** shown in the system's own list, the same one the Ledger Menu uses, so the text
  adapts to light and dark glass. Custom result views can't: iOS tells them only the device's
  appearance, not what's behind the glass. Tapping a row or outside the list closes it, and iOS
  offers no way to make rows untappable.
- **Transfers:** stored as one record holding both sides, so they're atomic by construction.
- **Opening balances:** `nil` means "not set" and is never treated as ₱0. Onboarding asks what
  each account holds now and subtracts entries already logged.
- **Archived accounts:** excluded from the total liquid balance; archiving warns when money remains.
  Archiving also turns the account's daily interest off.
- **Balance adjustments:** a separate transaction kind, so they change balances without ever
  counting as income or spending. Entering a real balance for an account with no opening balance
  sets the opening balance instead.
- **Daily interest:** end-of-day balance × annual rate ÷ 360, rounded up; withholding tax (20% by
  default) rounded to the nearest centavo; both dated 1:00 AM the next day. The formula matched an
  observed bank credit; ÷ 365 did not. Rates are stored exactly in parts per million. Posted days
  are tracked as calendar dates, so a time zone change never posts a day twice.
- **Intents require an unlocked iPhone** (`.requiresAuthentication`), because they read or
  change financial data. To allow logging from a locked phone, change the `authenticationPolicy`
  lines in `Ledger/Intents/LedgerIntents.swift` to `.alwaysAllowed`. That lets anyone holding the
  phone add entries.
- **Extra confirmations:** transfers always; an identical entry within 2 minutes (can be turned off
  in Settings); expenses and income of ₱100,000 or more.
- **Bundle ID:** `ph.personal.Ledger` is a placeholder. Contributors should use their own team and
  bundle ID.
- **License:** MIT.

## Outstanding work

1. On the iPhone, check the result list in light and dark, over the Home Screen and over a bright
   app.
2. On the iPhone, run Log Income and Transfer Money, and repeat a run from a locked phone. Confirm
   each entry appears in Activity with the right balance.
3. Set up the bank-email automation (README → Log from bank emails) and check that the first few
   entries are read correctly. Share a masked sample email if the amount, direction or reference
   number comes out wrong.
4. Try Siri voice input for amounts and names.
5. Optionally, with a team set on both targets, run the `LedgerShortcutsUITests` scheme on a
   simulator so its skipped tests run in full.
6. Turn on daily interest for a savings account and compare Ledger's daily interest and tax with
   the bank's for a few days. If they differ, note the balance, interest and tax the bank showed,
   so the rounding rule can be adjusted.

If a step fails on the device, look in Console.app for the app's messages in the `intents`
category.

## Known limitations

- Daily interest is posted only when Ledger runs, so balances catch up when the app opens or a
  shortcut runs. The rounding rule is inferred and may differ by a centavo on some days; Update
  Balance corrects it. A rate change made between midnight and 1:00 AM also covers the day that
  just ended.
- Update Balance from the Ledger Menu can't set a balance of exactly ₱0, because Shortcuts sends 0
  for an empty amount. The app can.
- Single currency (PHP); no export, import, sync, widgets or Apple Watch app; iPhone only.
- Search and filtering run in memory, which is fine at personal scale. Tens of thousands of
  records would call for predicate-based queries.
