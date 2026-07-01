#!/bin/sh
set -e

# CURRENT_PROJECT_VERSION in project.yml is a fixed placeholder for local
# builds. On Xcode Cloud, stamp every archive with a build number that is both
# monotonically increasing and higher than any previously uploaded build.
#
# We use a UTC timestamp (YYYYMMDDHHMM) rather than CI_BUILD_NUMBER. Xcode
# Cloud's CI_BUILD_NUMBER is a small per-workflow counter unrelated to App
# Store Connect's build history, so it kept landing below builds we'd already
# uploaded and App Store Connect rejected them. A timestamp is guaranteed to
# exceed any prior integer build number and strictly increases with wall-clock
# time, so every upload is accepted without needing to know the current
# ceiling. (Caveat: at most one uploadable build per minute.)
BUILD_NUMBER="$(date -u +%Y%m%d%H%M)"
cd "$CI_PRIMARY_REPOSITORY_PATH/apps/ios"
agvtool new-version -all "$BUILD_NUMBER"
# Echo the applied value so the build number is visible in the Xcode Cloud
# logs; agvtool what-version reads it back from the project to confirm the
# stamp actually took (not just what we asked for).
echo "CFBundleVersion set to $BUILD_NUMBER"
agvtool what-version -terse
