# Contributing

Ledger is a personal project, but issues and pull requests are welcome. For anything bigger than a
small fix, open an issue first so we can agree on the approach.

## Ground rules

- Ledger stays local-only. Changes that add network access, analytics, accounts or third-party
  dependencies won't be merged.
- Money is exact: `Decimal` in calculations and whole centavos (`Int64`) in storage, never
  `Double`.
- `LedgerService` is the only code that writes financial data or calculates balances.
- An opening balance that hasn't been set is never treated as zero.
- A SwiftData schema change needs a new schema version and a migration stage that keeps existing
  data.

The README's [How it works](README.md#how-it-works) section explains the architecture.

## Set up

1. Install Xcode 27 or later.
2. Clone the repository and open `Ledger.xcodeproj`.
3. To run on an iPhone, choose your own team and bundle identifier as described in the
   [README](README.md#run-on-your-iphone).

## Make a change

1. Branch from `develop` with a short descriptive name, for example `feature/csv-export`.
2. Keep each commit to one change. Start the subject with Add, Update, Fix, Implement, Remove,
   Refactor or Improve. Keep it imperative and under 50 characters, without prefixes such as
   `feat:`.
3. Add or update unit tests, then run the suite. Every test must pass, with no build warnings:

   ```sh
   xcodebuild -project Ledger.xcodeproj -scheme Ledger \
     -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
   ```

4. If you changed a screen, check it in light mode, dark mode and a large text size.
5. Open a pull request against `develop` that says what changed and how you tested it.

## Reporting a bug

Include the iOS version, the iPhone model, the steps to reproduce, and what you expected to happen.
Mask any real amounts or account details in screenshots.
