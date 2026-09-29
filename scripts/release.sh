#!/bin/sh
# Builds a Developer ID signed, notarized and stapled DBExplorer.app, plus a zip of it, in build/release.
#
# Signing and notarization use an App Store Connect API key, read from the environment or from the
# gitignored scripts/release.env:
#   ASC_KEY_PATH=/path/to/AuthKey_XXXXXXXXXX.p8
#   ASC_KEY_ID=XXXXXXXXXX
#   ASC_ISSUER_ID=xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
set -eu
cd "$(dirname "$0")/.."

[ -f scripts/release.env ] && . scripts/release.env
: "${ASC_KEY_PATH:?Set ASC_KEY_PATH (see scripts/release.sh)}"
: "${ASC_KEY_ID:?Set ASC_KEY_ID (see scripts/release.sh)}"
: "${ASC_ISSUER_ID:?Set ASC_ISSUER_ID (see scripts/release.sh)}"
OUT=build/release

[ -f "$ASC_KEY_PATH" ] || { echo "Missing App Store Connect API key: $ASC_KEY_PATH" >&2; exit 1; }
rm -rf "$OUT"
mkdir -p "$OUT"

# Lets Xcode create the Developer ID certificate and fetch profiles through the API key.
set -- -allowProvisioningUpdates \
    -authenticationKeyPath "$ASC_KEY_PATH" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID"

echo "==> Archiving"
xcodebuild archive -project DBExplorer.xcodeproj -scheme DBExplorer -configuration Release \
    -destination 'generic/platform=macOS' -archivePath "$OUT/DBExplorer.xcarchive" -quiet "$@"

echo "==> Exporting with Developer ID"
xcodebuild -exportArchive -archivePath "$OUT/DBExplorer.xcarchive" \
    -exportOptionsPlist scripts/ExportOptions.plist -exportPath "$OUT" -quiet "$@"

echo "==> Notarizing"
ditto -c -k --keepParent "$OUT/DBExplorer.app" "$OUT/DBExplorer.zip"
xcrun notarytool submit "$OUT/DBExplorer.zip" \
    --key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID" --wait

echo "==> Stapling"
xcrun stapler staple "$OUT/DBExplorer.app"
rm "$OUT/DBExplorer.zip"
ditto -c -k --keepParent "$OUT/DBExplorer.app" "$OUT/DBExplorer.zip"
spctl --assess --type execute --verbose "$OUT/DBExplorer.app"

echo "==> $OUT/DBExplorer.app"
