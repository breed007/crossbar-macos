#!/usr/bin/env bash
#
# release.sh — build, Developer ID-sign, notarize, staple, and package crossbar
# as both a universal .zip and a .dmg.
#
# Prerequisites (one-time):
#   1. A "Developer ID Application: Brian Reed (YA83Q8FTH3)" cert in the keychain.
#   2. A stored notarytool credential profile (shared with Switchback):
#
#        xcrun notarytool store-credentials "switchback-notary" \
#          --apple-id "breed007@gmail.com" --team-id YA83Q8FTH3
#
# Usage:
#   scripts/release.sh                        # profile "switchback-notary"
#   NOTARY_PROFILE=my-profile scripts/release.sh
#
set -euo pipefail
cd "$(dirname "$0")/.."

NOTARY_PROFILE="${NOTARY_PROFILE:-switchback-notary}"
TEAM="YA83Q8FTH3"
SCHEME="Crossbar"
BUILD_DIR="build/release"
ARCHIVE="$BUILD_DIR/Crossbar.xcarchive"
EXPORT_DIR="$BUILD_DIR/export"
APP="$EXPORT_DIR/Crossbar.app"

VERSION="$(xcodebuild -project Crossbar.xcodeproj -scheme "$SCHEME" -configuration Release \
  -showBuildSettings 2>/dev/null | awk -F' = ' '/ MARKETING_VERSION =/{print $2; exit}')"
[ -n "$VERSION" ] || { echo "could not read MARKETING_VERSION"; exit 1; }
ZIP="dist/crossbar-v${VERSION}-universal.zip"
DMG="dist/crossbar-v${VERSION}.dmg"

echo "==> Archiving Crossbar $VERSION (universal)"
rm -rf "$BUILD_DIR"
xcodebuild -project Crossbar.xcodeproj -scheme "$SCHEME" -configuration Release \
  -archivePath "$ARCHIVE" \
  ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO \
  DEVELOPMENT_TEAM="$TEAM" \
  archive

echo "==> Exporting Developer ID-signed app"
xcodebuild -exportArchive -archivePath "$ARCHIVE" \
  -exportPath "$EXPORT_DIR" \
  -exportOptionsPlist scripts/ExportOptions.plist

echo "==> Verifying signature + hardened runtime"
codesign --verify --deep --strict --verbose=2 "$APP"
codesign -dvv "$APP" 2>&1 | grep -E 'Authority|TeamIdentifier|flags' || true

mkdir -p dist

echo "==> Notarizing the app"
ditto -c -k --keepParent "$APP" "$BUILD_DIR/notary-app.zip"
xcrun notarytool submit "$BUILD_DIR/notary-app.zip" --keychain-profile "$NOTARY_PROFILE" --wait

echo "==> Stapling the app"
xcrun stapler staple "$APP"
xcrun stapler validate "$APP"

echo "==> Packaging $ZIP (stapled app)"
ditto -c -k --keepParent "$APP" "$ZIP"

echo "==> Building $DMG"
STAGE="$BUILD_DIR/dmg"
rm -rf "$STAGE"; mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
rm -f "$DMG"
hdiutil create -volname "Crossbar" -srcfolder "$STAGE" -fs HFS+ -format UDZO -ov "$DMG"

echo "==> Notarizing + stapling the dmg"
xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait
xcrun stapler staple "$DMG"
spctl -a -vv "$APP" || true

echo "==> Done:"
echo "    $ZIP"
echo "    $DMG"
