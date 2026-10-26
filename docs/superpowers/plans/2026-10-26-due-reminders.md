# Due Reminders (Part B) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remind the user of every due: plain notifications, or, in strict mode, a Live Activity in
the Dynamic Island and on the Lock Screen that comes back until paid. Snooze and Move This Due work
from the Live Activity itself.

**Architecture:**
- A pure `ReminderPlanner` turns each unpaid due into the notifications and Live Activity starts
  to schedule. It takes the dues (`DueStatus` from Part A), strict settings, snoozes, the current
  time and the calendar.
- A thin `ReminderScheduler` applies the plan:
  - through `UNUserNotificationCenter`
  - through `Activity<DueActivityAttributes>`, using `request(…, start:)` to schedule starts
  - after every save, on scene activation, and from intents
- A new widget extension (`LedgerWidgets`) draws the Live Activity.
- The activity attributes and the button intents live in a synchronized folder (`LedgerShared/`)
  compiled into both targets.

**Tech Stack:** Swift 6.4, SwiftUI, SwiftData, ActivityKit, WidgetKit, UserNotifications, App
Intents, XCTest. iOS 26.0 deployment target.

**Spec:** `docs/superpowers/specs/2026-10-26-bills-debts-and-reminders-design.md` (section
"Reminders (Part B)").

## Global Constraints

- **Platform:** iOS 26.0 deployment target, no iOS 27-only API. No network, no push server: every
  reminder is scheduled on the device.
- **No amounts** on the Lock Screen, in the Live Activity, in its alert, or in notifications. Names
  and dates only ("Rent · due today", "PayLater · 2 days overdue").
- **Strict mode** applies when the Settings switch is on (default on) and the item's own
  `strictReminder` is on (default on). Off means plain notifications: a heads-up, the due day, and
  one each overdue day.
- **Varying bills:** "Check if your <name> bill came in" on `arrivesDay`, repeated daily until the
  amount is entered.
- **Live Activity buttons:**
  - Paid opens the app to the prefilled payment; it never moves money itself.
  - Snooze is 1 hour or 3 hours.
  - Move This Due opens the app to the date picker.
- **Writes** still go through `LedgerService`. Logs never contain names or amounts. Comments
  describe what code does.
- **Build rules:**
  - `MemberImportVisibility` is on: import `ActivityKit`, `WidgetKit`, `UserNotifications` and
    `AppIntents` wherever they're used.
  - New files in `Ledger/`, `LedgerTests/`, `LedgerShared/` and `LedgerWidgets/` join their
    targets through synchronized folders. Only the new target itself is added to
    `project.pbxproj`, in Task 4.
- **Copy and symbols:** sentence case and plain words; SF Symbols available on iOS 26 only.
- **Tests:** XCTest with made-up names and amounts, using
  `LedgerHarness(calendar: try fixedCalendar("Asia/Manila"))` with `TestClock.referenceDate`
  (2026-03-15 10:00 Manila).
- **Builds:** zero warnings on a clean build.
- **Commits:** start with Add, Update, Fix, Implement, Remove, Refactor or Improve, ≤ 50
  characters, no trailers, one task per commit.

## Review Focus

1. **A due is paid while its Live Activity is showing.** The activity ends at once, and no later
   start or notification for it fires. Test: `testPayingRemovesEveryFutureReminder` (Task 1).
2. **Snooze runs past midnight into the next overdue day.** The comeback shows the new day's
   wording ("2 days overdue"). Test: `testSnoozePastMidnightUsesTheNewDaysWording` (Task 1).
3. **Reminder time changed to 23:30**, so the second start (8 hours later) falls on the next day.
   It's still planned once, not duplicated. Test: `testLateReminderTimeSecondStartNextDay`
   (Task 1).
4. **The Settings strict switch is off but an item's own toggle is on.** It gets notifications
   only. Test: `testStrictNeedsBothSwitches` (Task 1).
5. **A snooze for an item that's since been paid** leaves no stale entry behind. Test:
   `testExpiredAndPaidSnoozesAreDropped` (Task 1).

---

### Task 1: Reminder planner, copy and preferences

**Files:**
- Create: `Ledger/Reminders/ReminderPlanner.swift`
- Create: `Ledger/Reminders/ReminderCopy.swift`
- Create: `Ledger/Reminders/ReminderPreferences.swift`
- Create: `Ledger/Services/LedgerService+Reminders.swift`
- Test: `LedgerTests/ReminderPlannerTests.swift`, `LedgerTests/ReminderPreferencesTests.swift`
- Also commit this plan.

**Interfaces:**
- Consumes: `DueStatus`, `DueOwner`, `LedgerService.comingUp()` (Part A).
- Produces:

```swift
extension DueOwner {
    var key: String                 // "account-<UUID>" / "bill-<UUID>"
    init?(key: String)
}
struct ReminderItem: Hashable, Sendable {
    let status: DueStatus
    let name: String
    let symbolName: String
    let isStrict: Bool              // the item's own toggle
    let arrivesDay: CalendarDay?    // this cycle's arrival day, only while a varying bill's amount isn't set
}
struct ReminderSettings: Hashable, Sendable {
    var isStrictEnabled = true
    var minutesAfterMidnight = 540  // 9:00
}
struct ReminderLine: Hashable, Sendable, Codable {   // also the Live Activity's row (Task 4)
    let ownerKey: String; let name: String; let symbolName: String
    let dateText: String            // "Due today", "Due tomorrow", "2 days overdue"
    let isOverdue: Bool
}
struct PlannedNotification: Hashable, Sendable {
    let id: String                  // "ledger.reminder.<ownerKey>.<headsup|due|arrives>.<yyyymmdd>"
    let date: Date; let title: String; let body: String
}
struct PlannedActivityStart: Hashable, Sendable { let date: Date; let lines: [ReminderLine] }
struct ReminderPlan: Hashable, Sendable {
    let notifications: [PlannedNotification]   // by date, at most 60
    let activityStarts: [PlannedActivityStart] // by date, at most 3
    let showNow: [ReminderLine]                // strict items due today or overdue, not snoozed
}
enum ReminderPlanner {
    static let horizonDays = 14
    static let secondStartDelay: TimeInterval = 8 * 3_600
    static func plan(items: [ReminderItem], settings: ReminderSettings, snoozedUntil: [String: Date],
                     now: Date, calendar: Calendar) -> ReminderPlan
}
enum ReminderCopy {
    static func line(_ line: ReminderLine) -> String         // "Rent · due today"
    static func activityTitle(_ lines: [ReminderLine]) -> String   // "Rent is due today" / "2 bills need paying"
    static func arrivalBody(name: String) -> String          // "Check if your Electricity bill came in"
}
enum ReminderPreferences {
    enum Keys { static let strictEnabled = "reminders.strictEnabled"; static let minutes = "reminders.minutes"; static let snoozes = "reminders.snoozes" }
    static func settings(in defaults: UserDefaults = .standard) -> ReminderSettings
    static func snoozes(in defaults: UserDefaults = .standard, now: Date) -> [String: Date]   // drops expired
    static func snooze(_ keys: [String], until date: Date, in defaults: UserDefaults = .standard)
    static func clearSnoozes(except keys: Set<String>, in defaults: UserDefaults = .standard)
}
extension LedgerService {
    /// Unpaid dues as reminder items, in Coming Up order.
    func reminderItems() throws -> [ReminderItem]
    func setStrictReminder(_ isOn: Bool, for owner: DueOwner) throws
}
```

- **Algorithm** (the signatures don't determine it). Let `at(d)` be day d's start plus
  `minutesAfterMidnight`, in the calendar's time zone. For each item with `!status.isPaid`, and
  `due = status.dueDate`:
  - **Heads-up:** `at(due − 1)`, title = name, body "Due tomorrow".
  - **Each day d** from `max(due, today)` to `today + horizonDays`, with a line saying "Due today"
    when d == due, else "N day(s) overdue":
    - **Strict:** the item's line joins the activity slots at `at(d)` and
      `at(d) + secondStartDelay`.
    - **Otherwise:** one notification at `at(d)`, title = name, body = the date text.
  - **Varying bills** (`arrivesDay` set): from `max(arrivesDay, today)` to `due − 1`, a
    notification at `at(d)` with `ReminderCopy.arrivalBody`.
  - **Snooze:** with `s = snoozedUntil[key]` and `s > now`, drop the item from slots before s.
    Add it to a slot at s, with the line for the day s falls on, when that day ≥ due.
  - Only times after `now` are kept.
- **Slot order:** each slot lists overdue lines first, then by name.
- **`showNow`:** strict, unsnoozed items with `today ≥ due`, in the same order.
- `strict` means `settings.isStrictEnabled && item.isStrict`.

- [ ] **Step 1: Write the failing tests.** In `ReminderPlannerTests`, Manila, `now` 2026-03-15
  10:00, each item built from a `DueStatus` fixture:
  - `testHeadsUpTheDayBeforeAtReminderTime`: non-strict Rent, due Mar 20.
    - Notification ids include `…headsup.20260319` at 2026-03-19 09:00 Manila, `…due.20260320` at
      Mar 20 09:00, and `…due.20260321`.
    - There are no activity starts.
  - `testStrictItemGetsTwoActivityStartsPerDay`: strict Rent, due Mar 20.
    - The activity starts are at Mar 20 09:00, Mar 20 17:00 and Mar 21 09:00 (capped at 3).
    - There's no `…due…` notification, but the heads-up is there.
  - `testStrictNeedsBothSwitches` (Review Focus 4): `isStrictEnabled = false` with
    `item.isStrict = true` gives 0 activity starts, and due notifications are present.
  - `testPayingRemovesEveryFutureReminder` (Review Focus 1): the same item with `left == 0` gives
    an empty plan.
  - `testOverdueShowsNow`: strict, due Mar 13. `showNow.map(ReminderCopy.line) ==
    ["Rent · 2 days overdue"]`.
  - `testSnoozeHidesUntilItEnds`: strict, due Mar 15, snoozed until 11:00.
    - `showNow` is empty.
    - The first start is at 11:00, with "Due today".
  - `testSnoozePastMidnightUsesTheNewDaysWording` (Review Focus 2): due Mar 15, snoozed until
    Mar 16 00:30. That start's line reads "1 day overdue".
  - `testOneActivityHoldsEverythingDueThatDay`: strict Rent due Mar 20 and strict PayLater due
    Mar 18.
    - The Mar 20 09:00 slot lines are `["PayLater", "Rent"]`.
    - PayLater is overdue.
  - `testLateReminderTimeSecondStartNextDay` (Review Focus 3): minutes 1_410 (23:30), strict,
    due Mar 20.
    - Starts at Mar 20 23:30 and Mar 21 07:30.
    - Each date appears once.
  - `testVaryingBillAsksUntilTheAmountIsSet`: Electricity due Mar 30, arrives Mar 19, left `nil`.
    - Arrival notifications Mar 19…Mar 29 with body "Check if your Electricity bill came in".
    - With left 2,350 there are none.
  - `testNothingInThePastAndNoAmounts`:
    - Every date in the plan is > now.
    - No title or body contains "₱" or a digit except in "N days overdue".
  - `testCaps`: 10 strict items due today give `activityStarts.count <= 3` and
    `notifications.count <= 60`.
- [ ] **Step 2: Write the failing preferences and service tests.**
  - `ReminderPreferencesTests` (with `withScratchDefaults`):
    - The defaults are strict on and 540 minutes.
    - `snooze(["a"], until:)` round-trips.
    - `testExpiredAndPaidSnoozesAreDropped` (Review Focus 5): `snoozes(now:)` drops a past date,
      and `clearSnoozes(except: [])` removes the rest.
  - In `ReminderPlannerTests`, harness-based, `testReminderItemsFollowComingUp`:
    - A strict card due Mar 25 (still due 1,000) and a varying Electricity bill (arrives 19,
      due 30) give `reminderItems().map(\.name) == ["Visa card", "Electricity"]`.
    - Electricity's `arrivesDay` is 2026-03-19.
    - After `setStrictReminder(false, for: .account(card.id))`, the card's `isStrict` is false.
- [ ] **Step 3: Run them to make sure they fail** (they don't compile).
- [ ] **Step 4: Implement.**
- [ ] **Step 5: Run them to make sure they pass, then run the full suite.**
- [ ] **Step 6: Commit**: `Add reminder planner and preferences`, with this plan.

### Task 2: Notifications and refresh

**Files:**
- Create: `Ledger/Reminders/ReminderScheduler.swift`, with `@MainActor final class
  ReminderScheduler`:
  - `static let shared`
  - `func start(container: ModelContainer)` observes `ModelContext.didSave`
  - `func refresh() async`
  - `func requestPermissionIfNeeded() async`
- Create: `Ledger/Reminders/NotificationRequests.swift`, with `enum NotificationRequests {
  static func requests(for plan: ReminderPlan, calendar: Calendar) -> [UNNotificationRequest] }`.
  Each request uses a `UNCalendarNotificationTrigger` with year, month, day, hour and minute.
- Modify: `Ledger/App/LedgerApp.swift`: in `init`, start the scheduler with the shared container.
- Modify: `Ledger/App/RootView.swift`: `.refreshingReminders()` refreshes on scene activation (a
  modifier in `Ledger/App/ReminderRefresh.swift`, mirroring `InterestCatchUp`).
- Modify: `Ledger/Features/Settings/SettingsView.swift`: a Reminders section with:
  - the **Strict reminders** toggle
  - **Reminder time** (an hour-and-minute picker)
  - permission status, with **Allow notifications** when undetermined, or **Open Settings** when
    denied
- Modify: `OwedAccountDetailView`, `BillDetailView`: a **Strict reminder** toggle that calls
  `setStrictReminder`.
- Test: `LedgerTests/NotificationRequestsTests.swift`

**Interfaces:**
- Consumes: Task 1 (`ReminderPlanner`, `ReminderPreferences`, `reminderItems()`,
  `setStrictReminder`).
- Produces: `ReminderScheduler.shared.refresh()`, used by Task 5.
- **Refresh:**
  - Plan from `reminderItems()`, `ReminderPreferences.settings()`, and `snoozes(now:)`, after
    `clearSnoozes(except:)` drops keys no longer due.
  - Remove every pending request whose id starts with `ledger.reminder.`, then add the new ones.
  - Without notification permission, skip notifications silently.
- **Permission** is asked once, when `reminderItems()` is first non-empty and the status is
  `.notDetermined`, and only while the app is in the foreground.

- [ ] **Step 1: Write the failing `NotificationRequestsTests`**:
  - Identifiers equal the plan's ids.
  - The trigger's date components match 2026-03-19 09:00 in Manila.
  - Content title and body equal the plan's.
  - `content.sound` is `.default`.
- [ ] **Step 2: Run it to make sure it fails, implement, and run it to make sure it passes.**
- [ ] **Step 3: Implement the scheduler**, the refresh triggers, the Settings section and the
  toggles. Build it.
- [ ] **Step 4: Screenshots.** Use a throwaway test `testReminderSettings` (Settings tab → the
  Reminders section, and the bill screen toggle) in light and dark. Look at every screenshot.
- [ ] **Step 5: Run the full suite, then commit**: `Add due reminder notifications`.

### Task 3: Widget extension target and Live Activity UI

**Files:**
- Create: `LedgerShared/DueActivityAttributes.swift`: `struct DueActivityAttributes:
  ActivityAttributes` with `struct ContentState: Codable, Hashable { var lines: [ReminderLine] }`
  and no static attributes.
  - `ReminderLine` (Task 1) moves here so both targets see it.
- Create: `LedgerShared/ReminderStyle.swift`: an `emerald` color matching the app's AccentColor
  (read it from `Ledger/Resources/Assets.xcassets/AccentColor.colorset`).
- Create: `LedgerWidgets/LedgerWidgetsBundle.swift`: `@main struct LedgerWidgetsBundle:
  WidgetBundle { var body: some Widget { DueActivityWidget() } }`.
- Create: `LedgerWidgets/DueActivityWidget.swift`: `ActivityConfiguration(for:
  DueActivityAttributes.self)` with:
  - **Lock Screen and banner:** up to 3 lines, each with its symbol, name and date text (overdue
    marked in red with an icon), plus a "+N more" line. It holds the buttons added in Task 4.
  - **Dynamic Island:**
    - compact leading: the first line's symbol
    - compact trailing: the "due today" or overdue count, such as "2 due"
    - minimal: a symbol
    - expanded: the lines and the buttons
  - `.supplementalActivityFamilies([.small])`.
- Create: `LedgerWidgets/Info.plist`, holding `NSExtension` →
  `NSExtensionPointIdentifier = com.apple.widgetkit-extension`.
- Modify: `Ledger.xcodeproj/project.pbxproj`. IDs continue the `4C1E000000000000000000xx` pattern
  from `0x40`.
  - Synchronized groups:
    - `LedgerShared`, added to both the Ledger and LedgerWidgets targets.
    - `LedgerWidgets`, with an exception set that keeps `Info.plist` out of resources.
  - The `LedgerWidgets` target: `com.apple.product-type.app-extension`.
    - Product `LedgerWidgets.appex`.
    - Bundle id `ph.personal.Ledger.Widgets`, team `TQ9J4W7YHY`.
    - `INFOPLIST_FILE = LedgerWidgets/Info.plist` with `GENERATE_INFOPLIST_FILE = YES` and
      `INFOPLIST_KEY_CFBundleDisplayName = Ledger`.
    - `SKIP_INSTALL = YES`.
    - `LD_RUNPATH_SEARCH_PATHS` `@executable_path/Frameworks` and
      `@executable_path/../../Frameworks`.
    - `SWIFT_ACTIVE_COMPILATION_CONDITIONS = "$(inherited) LEDGER_WIDGET"`.
    - The same Swift settings as the app.
  - The app target:
    - an "Embed Foundation Extensions" copy phase (`dstSubfolderSpec = 13`)
    - a target dependency on LedgerWidgets
    - `INFOPLIST_KEY_NSSupportsLiveActivities = YES`
  - The project's `targets` list gains LedgerWidgets.
- Move `ReminderLine` from `ReminderPlanner.swift` into `LedgerShared/DueActivityAttributes.swift`.

**Interfaces:**
- Produces: `DueActivityAttributes`, `DueActivityAttributes.ContentState(lines:)`, and the widget
  views. Task 4 adds the buttons.

- [ ] **Step 1: Edit `project.pbxproj`** with the objects above. `plutil -lint` doesn't apply,
  so check with `xcodebuild -list` (it lists target LedgerWidgets).
- [ ] **Step 2: Build for the simulator and for a device** (`CODE_SIGNING_ALLOWED=NO`). Both
  succeed with 0 warnings, and
  `.scratch/DerivedData/Build/Products/Debug-iphonesimulator/Ledger.app/PlugIns/LedgerWidgets.appex`
  exists.
- [ ] **Step 3: Run the full unit suite** and confirm it passes.
- [ ] **Step 4: Commit**: `Add Live Activity widget extension`.

### Task 4: Live Activity scheduling and buttons

**Files:**
- Create: `LedgerShared/ReminderIntents.swift`. Each intent has `isDiscoverable = false` and a
  `parameterSummary` covering every `@Parameter`. In `perform()`, the widget target
  (`#if LEDGER_WIDGET`) returns `.result()`; the app calls `ReminderActions`.
  - `SnoozeReminderIntent: LiveActivityIntent`, with `@Parameter minutes: Int`.
  - `PayDueFromReminderIntent: AppIntent`, with `supportedModes = .foreground` and `@Parameter
    ownerKey: String`.
  - `MoveDueFromReminderIntent: AppIntent`, the same.
- Create: `Ledger/Reminders/ReminderActions.swift`, `@MainActor enum ReminderActions`:
  - `snooze(minutes: Int)` snoozes every line of the current activity until now + minutes, then
    refreshes.
  - `openPayment(ownerKey:)` and `openMove(ownerKey:)` set `ReminderRouting.shared.pending`.
- Create: `Ledger/Reminders/ReminderRouting.swift`, `@MainActor @Observable final class
  ReminderRouting`:
  - `static let shared`
  - `var pending: ReminderRoute?`
  - `enum ReminderRoute: Identifiable { case pay(DueOwner), move(DueOwner) }`
- Modify: `ReminderScheduler.refresh()` for activities:
  - End activities whose lines are all paid or snoozed.
  - Update or start one activity for `showNow`. `Activity.request` runs only when the app is
    active or inside a `LiveActivityIntent`; otherwise it's skipped.
  - Replace pending scheduled activities (`activityState == .pending`) with `request(…,
    style: .standard, alertConfiguration:, start:)` for each `activityStarts` entry.
  - The `AlertConfiguration` title is `ReminderCopy.activityTitle` and the body is the joined
    `ReminderCopy.line`s, with no amounts.
  - When `ActivityAuthorizationInfo().areActivitiesEnabled` is false, strict items fall back to
    the due-day notification.
- Modify: `Ledger/App/RootView.swift`: present `PayDueView` / `PayBillView` / `MoveDueView` for
  `ReminderRouting.shared.pending`.
- Modify: `LedgerWidgets/DueActivityWidget.swift`: the buttons are `Button(intent:
  PayDueFromReminderIntent(ownerKey:))` for the first line, `Button(intent:
  SnoozeReminderIntent(minutes: 60))` / `(minutes: 180)`, and `Button(intent:
  MoveDueFromReminderIntent(ownerKey:))`.
- Modify: `Ledger/Intents/LedgerIntents.swift`: `LedgerMenuIntent` and the logging intents also
  conform to `LiveActivityIntent`. Their `perform` calls `await
  ReminderScheduler.shared.refresh()` after a save.
  - If metadata extraction or the Shortcuts UI tests (01, 03) break because of it, remove the
    conformance and ledger the ruling.
- Test: `LedgerTests/ReminderActionsTests.swift`

- [ ] **Step 1: Write the failing tests:**
  - `testOwnerKeyRoundTrips`: `DueOwner(key: owner.key) == owner` for both cases, and `nil` for
    `"junk"`.
  - `testSnoozeStoresEveryShownLine` (scratch defaults): `ReminderActions.snooze(lines:minutes:now:
    defaults:)`, a testable overload, stores both keys until now + 3,600.
  - `testRoutesFromKeys`: `openPayment(ownerKey: "bill-<id>")` sets `.pay(.bill(id))`, and a
    junk key sets nothing.
- [ ] **Step 2: Run them to make sure they fail, implement, and run them to make sure they pass.**
- [ ] **Step 3: Simulator check.** With sample data plus a strict bill due today, launch, press
  Home, and capture:
  - the Dynamic Island (compact)
  - Notification Center pulled down (Lock Screen presentation)
  - the app reopened through the Pay button, if tappable from XCUITest

  Run it in light and dark and look at each screenshot. Then run Shortcuts UI tests 01 and 03.
- [ ] **Step 4: Run the full suite and a clean build** (0 warnings). Commit: `Add strict due
  reminders in the Dynamic Island`.

### Task 5: Docs and final checks

- [ ] **Step 1: Update docs.**
  - `README.md`: a Reminders section (notifications, strict mode, snooze, move this due, no amounts
    on the Lock Screen) and the test count.
  - `PROJECT_STATUS.md`: evidence, decisions, outstanding work.
    - Outstanding: on the iPhone, a scheduled start while the app is closed, the 8-hour comeback,
      snooze, move, the Pay button, and swipe-away.
    - Limitation: a Live Activity can only be scheduled while Ledger or one of its shortcuts runs.
  - Local only: `CLAUDE.md` and `HANDOFF.md`.
- [ ] **Step 2: Verify.** Full suite, clean simulator and device builds with 0 warnings, and the
  symbol check.
- [ ] **Step 3: Commit**: `Update docs for due reminders`.
