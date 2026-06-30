#!/bin/sh
set -e

# CURRENT_PROJECT_VERSION in project.yml is a fixed placeholder for local
# builds. On Xcode Cloud, stamp every archive with the workflow's own
# auto-incrementing build number so App Store Connect always sees a higher
# bundle version than the last upload.
cd "$CI_PRIMARY_REPOSITORY_PATH/apps/ios"
agvtool new-version -all "$CI_BUILD_NUMBER"
