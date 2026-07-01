#!/bin/sh
#
# Swift 6 readiness lane.
#
# Builds the app in the Swift 6 language mode with complete strict-concurrency
# checking and warnings treated as errors, WITHOUT changing the default build
# (SWIFT_VERSION stays 5.0 in project.yml). Run it locally or as a dedicated CI
# lane to track the remaining concurrency work ahead of flipping the app targets
# to Swift 6:
#
#   apps/ios/ci_scripts/swift6_check.sh
#
# It is expected to fail until the backlog is cleared — wire it as an
# allowed-failure / informational CI lane, and make it a required gate once it
# passes clean. Fix issues incrementally (actors for persistence/sync,
# @MainActor for UI state, cancellable `.task(id:)` for view async work).
set -e

DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$DIR"

SIMULATOR="${SWIFT6_SIMULATOR:-platform=iOS Simulator,name=iPhone 17 Pro}"

if ! command -v xcodegen >/dev/null 2>&1; then
  echo "error: xcodegen not installed (brew install xcodegen)" >&2
  exit 1
fi
xcodegen generate

echo "=== Building Grocer in Swift 6 language mode (warnings as errors) ==="
set +e
xcodebuild build-for-testing \
  -project Grocer.xcodeproj \
  -scheme Grocer \
  -destination "$SIMULATOR" \
  SWIFT_VERSION=6.0 \
  SWIFT_STRICT_CONCURRENCY=complete \
  SWIFT_TREAT_WARNINGS_AS_ERRORS=YES \
  2>&1 | tee /tmp/grocer-swift6.log | grep -E "error:|BUILD (SUCCEEDED|FAILED)"
STATUS=${PIPESTATUS:-$?}
set -e

ERRORS=$(grep -c "error:" /tmp/grocer-swift6.log || true)
echo ""
echo "=== Swift 6 lane: ${ERRORS} error line(s). Full log: /tmp/grocer-swift6.log ==="
if grep -q "BUILD SUCCEEDED" /tmp/grocer-swift6.log; then
  echo "Swift 6 lane is GREEN — safe to flip SWIFT_VERSION to 6.0 in project.yml."
  exit 0
fi
exit 1
