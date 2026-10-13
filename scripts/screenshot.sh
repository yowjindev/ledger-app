#!/bin/zsh
# Installs a built Ledger.app on a simulator, launches it, and saves a screenshot.
#
# Usage: scripts/screenshot.sh <simulator-name> <path/to/Ledger.app> <output.png> [launch arguments...]
# Example:
#   scripts/screenshot.sh Ledger-UI-A .dd/Build/Products/Debug-iphonesimulator/Ledger.app out/dashboard.png \
#     -LedgerInMemoryStore YES -LedgerSampleData YES -LedgerSkipOnboarding YES -LedgerInitialTab dashboard
#
# Appearance and text size: xcrun simctl ui <simulator-name> appearance dark|light
#                           xcrun simctl ui <simulator-name> content_size large|accessibility-extra-large
set -euo pipefail

if [[ $# -lt 3 ]]; then
  print -u2 "usage: $0 <simulator-name> <path/to/Ledger.app> <output.png> [launch arguments...]"
  exit 64
fi

device="$1"
app="$2"
output="$3"
shift 3
bundle_id="ph.personal.Ledger"

xcrun simctl bootstatus "$device" -b >/dev/null
xcrun simctl status_bar "$device" override --time 9:41 --batteryState charged --batteryLevel 100 >/dev/null 2>&1 || true
xcrun simctl install "$device" "$app"
xcrun simctl terminate "$device" "$bundle_id" >/dev/null 2>&1 || true
xcrun simctl launch "$device" "$bundle_id" "$@" >/dev/null

# Give the first frame time to render.
steps=0
until [[ $steps -ge ${LEDGER_SCREENSHOT_WAIT_STEPS:-8} ]]; do
  sleep 0.5
  steps=$((steps + 1))
done

mkdir -p "$(dirname "$output")"
xcrun simctl io "$device" screenshot "$output" >/dev/null
print "$output"
