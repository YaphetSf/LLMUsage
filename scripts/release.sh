#!/bin/zsh
set -euo pipefail

PROJECT_ROOT=${0:A:h:h}
CONFIGURATION=release
TRACKER_NAME=LLMUsage_Tracker
CONTROL_CENTER_NAME=LLMUsage
RESOURCE_BUNDLE_NAME=LLMUsage_LLMUsageUI.bundle
APP_ICON="$PROJECT_ROOT/Packaging/AppIcon.icns"
DIST_DIRECTORY="$PROJECT_ROOT/dist"

CODESIGN_IDENTITY=${CODESIGN_IDENTITY:-"Developer ID Application: Optical support limited (5ZK6D32Z6F)"}
NOTARY_KEYCHAIN_PROFILE=${NOTARY_KEYCHAIN_PROFILE:-"QRStudio"}
VOLUME_NAME=${VOLUME_NAME:-"LLMUsage"}

if ! /usr/bin/security find-identity -v -p codesigning \
    | /usr/bin/grep -F -- "$CODESIGN_IDENTITY" >/dev/null; then
    print -u2 "Code-signing identity not found: $CODESIGN_IDENTITY"
    print -u2 "Set CODESIGN_IDENTITY to override."
    exit 1
fi
if ! /usr/bin/xcrun notarytool history --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" >/dev/null 2>&1; then
    print -u2 "Notary keychain profile not found: $NOTARY_KEYCHAIN_PROFILE"
    print -u2 "Create one with: xcrun notarytool store-credentials \"$NOTARY_KEYCHAIN_PROFILE\""
    print -u2 "Or set NOTARY_KEYCHAIN_PROFILE to override."
    exit 1
fi

cd "$PROJECT_ROOT"
print "==> generating app icon"
swift "$PROJECT_ROOT/scripts/generate-app-icon.swift"

print "==> building ($CONFIGURATION)"
swift build --configuration "$CONFIGURATION"
BIN_DIRECTORY=$(swift build --configuration "$CONFIGURATION" --show-bin-path)

TRACKER_BINARY="$BIN_DIRECTORY/$TRACKER_NAME"
CONTROL_CENTER_BINARY="$BIN_DIRECTORY/$CONTROL_CENTER_NAME"
RESOURCE_BUNDLE="$BIN_DIRECTORY/$RESOURCE_BUNDLE_NAME"
RESOURCE_CONTENT="$RESOURCE_BUNDLE/Contents/Resources/Resources"
if [[ ! -d "$RESOURCE_CONTENT/ProviderIcons" && -d "$RESOURCE_BUNDLE/Resources/ProviderIcons" ]]; then
    RESOURCE_CONTENT="$RESOURCE_BUNDLE/Resources"
fi
if [[ ! -x "$TRACKER_BINARY" || ! -x "$CONTROL_CENTER_BINARY" || ! -d "$RESOURCE_CONTENT/ProviderIcons" ]]; then
    print -u2 "Build completed without the expected executables or resource bundle."
    exit 1
fi

STAGING_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/llmusage-release.XXXXXX")
trap "rm -rf '$STAGING_ROOT'" EXIT

STAGED_CONTROL_CENTER="$STAGING_ROOT/$CONTROL_CENTER_NAME.app"
STAGED_TRACKER="$STAGED_CONTROL_CENTER/Contents/Library/LoginItems/$TRACKER_NAME.app"

print "==> assembling"
stage_app() {
    local staged=$1 name=$2 binary=$3
    mkdir -p "$staged/Contents/MacOS" "$staged/Contents/Resources"
    cp "$PROJECT_ROOT/Packaging/$name/Info.plist" "$staged/Contents/Info.plist"
    cp "$binary" "$staged/Contents/MacOS/$name"
    cp "$APP_ICON" "$staged/Contents/Resources/AppIcon.icns"
    ditto "$RESOURCE_CONTENT" "$staged/Contents/Resources"
}

stage_app "$STAGED_CONTROL_CENTER" "$CONTROL_CENTER_NAME" "$CONTROL_CENTER_BINARY"
stage_app "$STAGED_TRACKER" "$TRACKER_NAME" "$TRACKER_BINARY"

print "==> signing"
codesign --force --timestamp --options runtime --sign "$CODESIGN_IDENTITY" "$STAGED_TRACKER"
codesign --force --timestamp --options runtime --sign "$CODESIGN_IDENTITY" "$STAGED_CONTROL_CENTER"

print "==> verifying signatures"
codesign --verify --deep --strict "$STAGED_TRACKER"
codesign --verify --deep --strict "$STAGED_CONTROL_CENTER"

MARKETING_VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$STAGED_CONTROL_CENTER/Contents/Info.plist")
ARTIFACT_BASENAME="${VOLUME_NAME}-${MARKETING_VERSION}"

mkdir -p "$DIST_DIRECTORY"
rm -rf "$DIST_DIRECTORY/$CONTROL_CENTER_NAME.app" \
       "$DIST_DIRECTORY/notary.zip" \
       "$DIST_DIRECTORY/$ARTIFACT_BASENAME.dmg"
ditto "$STAGED_CONTROL_CENTER" "$DIST_DIRECTORY/$CONTROL_CENTER_NAME.app"

print "==> notarizing (zip + submit + wait)"
NOTARY_ZIP="$DIST_DIRECTORY/notary.zip"
ditto -c -k --keepParent "$DIST_DIRECTORY/$CONTROL_CENTER_NAME.app" "$NOTARY_ZIP"
/usr/bin/xcrun notarytool submit "$NOTARY_ZIP" \
    --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" \
    --wait

print "==> stapling"
/usr/bin/xcrun stapler staple "$DIST_DIRECTORY/$CONTROL_CENTER_NAME.app/Contents/Library/LoginItems/$TRACKER_NAME.app"
/usr/bin/xcrun stapler staple "$DIST_DIRECTORY/$CONTROL_CENTER_NAME.app"

print "==> verifying notarization"
codesign --verify --deep --strict "$DIST_DIRECTORY/$CONTROL_CENTER_NAME.app"
spctl --assess --type execute --verbose=2 "$DIST_DIRECTORY/$CONTROL_CENTER_NAME.app"

print "==> creating DMG"
DMG_PATH="$DIST_DIRECTORY/$ARTIFACT_BASENAME.dmg"
DMG_RW="$STAGING_ROOT/$ARTIFACT_BASENAME.dmg"
DMG_STAGING="$STAGING_ROOT/dmg-layout"
mkdir -p "$DMG_STAGING"
ditto "$DIST_DIRECTORY/$CONTROL_CENTER_NAME.app" "$DMG_STAGING/$CONTROL_CENTER_NAME.app"
ln -s /Applications "$DMG_STAGING/Applications"
/usr/bin/hdiutil create -volname "$VOLUME_NAME" \
    -srcfolder "$DMG_STAGING" \
    -ov -format UDZO "$DMG_RW"
mv "$DMG_RW" "$DMG_PATH"

print "==> signing DMG"
codesign --force --timestamp --sign "$CODESIGN_IDENTITY" "$DMG_PATH"

print "==> notarizing DMG"
/usr/bin/xcrun notarytool submit "$DMG_PATH" \
    --keychain-profile "$NOTARY_KEYCHAIN_PROFILE" --wait
/usr/bin/xcrun stapler staple "$DMG_PATH"
/usr/bin/xcrun stapler validate "$DMG_PATH"
spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG_PATH"

rm -rf "$DIST_DIRECTORY/$CONTROL_CENTER_NAME.app" "$NOTARY_ZIP"

print "Done."
print "DMG: $DMG_PATH"
