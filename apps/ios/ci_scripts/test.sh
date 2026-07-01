#!/bin/sh
#
# iOS test lane: regenerate the (gitignored) Xcode project and run the unit
# tests on a simulator. Mirrors the documented local flow.
#
#   apps/ios/ci_scripts/test.sh
#
# IMPORTANT: do NOT pass CODE_SIGNING_ALLOWED=NO — it strips the iCloud
# entitlement and CloudKitService traps at launch, so the test host dies with
# zero tests run. Use normal automatic signing for the simulator.
set -e

DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$DIR"

SIMULATOR="${GROCER_SIMULATOR:-platform=iOS Simulator,name=iPhone 17 Pro}"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "error: xcodegen not installed (brew install xcodegen)" >&2
  exit 1
fi
xcodegen generate

xcodebuild test \
  -project Grocer.xcodeproj \
  -scheme Grocer \
  -destination "$SIMULATOR" \
  -only-testing:GrocerTests
