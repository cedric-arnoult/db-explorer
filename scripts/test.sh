#!/bin/sh
# Runs the DBCore unit tests, then an unsigned Release build of the app.
# Set DBEXPLORER_TEST_DATABASE_URL to also run the integration tests (see scripts/test-integration.sh).
set -eu
cd "$(dirname "$0")/.."
(cd Packages/DBCore && xcodebuild test -scheme DBCore -destination 'platform=macOS' -quiet)
xcodebuild build -project DBExplorer.xcodeproj -scheme DBExplorer -configuration Release -destination 'platform=macOS' -quiet CODE_SIGNING_ALLOWED=NO
