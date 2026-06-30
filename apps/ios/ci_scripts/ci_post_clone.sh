#!/bin/sh
set -e

# Grocer.xcodeproj is gitignored and generated from project.yml via XcodeGen.
# Xcode Cloud's VM doesn't have XcodeGen preinstalled, so install it and
# generate the project before Xcode Cloud tries to resolve/build it.
if ! command -v xcodegen >/dev/null 2>&1; then
  brew install xcodegen
fi

cd "$CI_PRIMARY_REPOSITORY_PATH/apps/ios"
xcodegen generate

# Package.resolved lives inside the gitignored .xcodeproj, so it can't be
# committed at its normal path. Seed it from the tracked copy so Xcode
# Cloud's strict (non-automatic) package resolution has a file to read.
mkdir -p Grocer.xcodeproj/project.xcworkspace/xcshareddata/swiftpm
cp Package.resolved Grocer.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved
