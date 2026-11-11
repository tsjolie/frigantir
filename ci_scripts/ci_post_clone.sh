#!/bin/sh
# Xcode Cloud runs this right after cloning the repo. FrigateApp.xcodeproj is
# generated from project.yml and isn't committed (see .gitignore), so create it
# here before Xcode Cloud looks for it.
set -eu

# The Team ID is public (it's in every signed app) and lives in the git-ignored
# .env locally. A DEVELOPMENT_TEAM environment variable on the Xcode Cloud
# workflow overrides this default.
export DEVELOPMENT_TEAM="${DEVELOPMENT_TEAM:-6G3YR39A62}"

export HOMEBREW_NO_AUTO_UPDATE=1 HOMEBREW_NO_INSTALL_CLEANUP=1
brew install xcodegen

cd "$CI_PRIMARY_REPOSITORY_PATH"
xcodegen generate

# Xcode Cloud won't resolve Swift packages itself; it needs the exact versions
# in the generated project. They're kept in the committed Package.resolved.
mkdir -p FrigateApp.xcodeproj/project.xcworkspace/xcshareddata/swiftpm
cp Package.resolved FrigateApp.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/
