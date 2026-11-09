#!/bin/sh
# Builds the release DMG: a universal Release build with ad-hoc signing, checked by the same security and privacy
# checks as `make security`, in a disk image with a link to /Applications, and its SHA-256.
#   build/ShowMyCopy.dmg
#   build/ShowMyCopy.dmg.sha256
# Ad-hoc signed, not notarized: there is no Developer ID yet, so macOS asks once before the first launch.
set -eu

PROJECT="ShowMyCopy.xcodeproj"
SCHEME="ShowMyCopy"
BUILD_DIR="build"
DERIVED_DATA="$BUILD_DIR/ReleaseDerivedData"
APP="$DERIVED_DATA/Build/Products/Release/ShowMyCopy.app"
STAGING="$BUILD_DIR/dmg"
DMG="$BUILD_DIR/ShowMyCopy.dmg"

rm -rf "$DERIVED_DATA" "$STAGING" "$DMG" "$DMG.sha256"

xcodebuild build \
    -project "$PROJECT" \
    -scheme "$SCHEME" \
    -configuration Release \
    -destination "generic/platform=macOS" \
    -derivedDataPath "$DERIVED_DATA" \
    CODE_SIGN_IDENTITY=- \
    -quiet

# What ships is what is checked: sandbox, no network, entitlements, hardened runtime, no Debug-only code.
./scripts/check_security.sh "$APP"
python3 -I scripts/check_privacy_manifest.py "$APP"

mkdir -p "$STAGING"
ditto "$APP" "$STAGING/ShowMyCopy.app"
ln -s /Applications "$STAGING/Applications"

hdiutil create -volname "Show My Copy" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null
(cd "$BUILD_DIR" && shasum -a 256 ShowMyCopy.dmg > ShowMyCopy.dmg.sha256)
rm -rf "$STAGING"

VERSION=$(defaults read "$PWD/$APP/Contents/Info" CFBundleShortVersionString)
echo "Built Show My Copy $VERSION"
echo "  $DMG"
echo "  $DMG.sha256"
