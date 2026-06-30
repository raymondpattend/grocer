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
