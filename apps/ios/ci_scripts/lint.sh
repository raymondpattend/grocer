#!/bin/sh
#
# Lint + format-check lane for the Grocer iOS app. Run locally or in CI:
#   apps/ios/ci_scripts/lint.sh          # lint + format diff (non-mutating)
#   apps/ios/ci_scripts/lint.sh --fix    # apply SwiftFormat in place
#
# Tools (install once): brew install swiftlint swiftformat
set -e

DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$DIR"
SOURCES="Grocer GrocerWidget GrocerTests"
STATUS=0

if command -v swiftformat >/dev/null 2>&1; then
  if [ "$1" = "--fix" ]; then
    echo "=== SwiftFormat (in place) ==="
    swiftformat $SOURCES
    echo "note: re-run the source-guardrail tests — formatting can move pinned lines."
  else
    echo "=== SwiftFormat (lint mode) ==="
    swiftformat --lint $SOURCES || STATUS=1
  fi
else
  echo "warning: swiftformat not installed (brew install swiftformat)"
fi

if command -v swiftlint >/dev/null 2>&1; then
  echo "=== SwiftLint ==="
  swiftlint lint --quiet || STATUS=1
else
  echo "warning: swiftlint not installed (brew install swiftlint)"
fi

exit $STATUS
