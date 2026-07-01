#!/bin/sh
set -e

# CURRENT_PROJECT_VERSION in project.yml is a fixed placeholder for local
# builds. On Xcode Cloud, stamp every archive with a build number that is both
# monotonically increasing and higher than any previously uploaded build.
#
# CI_BUILD_NUMBER is Xcode Cloud's own per-workflow counter and starts low
# (1, 2, 3, ...). It is unrelated to App Store Connect's build history, so
# using it raw produced numbers below the legacy manual uploads (which reached
# 42) and App Store Connect rejected them. Offsetting past that legacy floor
# keeps every future build strictly increasing (CI_BUILD_NUMBER only ever
# grows) while clearing the highest number already on App Store Connect.
BUILD_NUMBER_OFFSET=100
cd "$CI_PRIMARY_REPOSITORY_PATH/apps/ios"
agvtool new-version -all "$((CI_BUILD_NUMBER + BUILD_NUMBER_OFFSET))"
