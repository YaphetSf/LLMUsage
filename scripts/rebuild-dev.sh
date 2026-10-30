#!/bin/zsh
set -euo pipefail

PROJECT_ROOT=${0:A:h:h}
CONFIGURATION=debug
TRACKER_NAME=LLMUsage_Tracker
CONTROL_CENTER_NAME=LLMUsage
RESOURCE_BUNDLE_NAME=LLMUsage_LLMUsageUI.bundle
APP_ICON="$PROJECT_ROOT/Packaging/AppIcon.icns"
CONTROL_CENTER_DESTINATION="/Applications/$CONTROL_CENTER_NAME.app"
TRACKER_DESTINATION="$CONTROL_CENTER_DESTINATION/Contents/Library/LoginItems/$TRACKER_NAME.app"
LEGACY_CONTROL_CENTER_DESTINATION="$HOME/Applications/$CONTROL_CENTER_NAME.app"
LSREGISTER=/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister
SIGNING_IDENTITY=-

if [[ -n "${CODESIGN_IDENTITY:-}" ]] \
    && /usr/bin/security find-identity -v -p codesigning \
    | /usr/bin/grep -F -- "$CODESIGN_IDENTITY" >/dev/null; then
    SIGNING_IDENTITY=$CODESIGN_IDENTITY
fi

cd "$PROJECT_ROOT"
if [[ ! -f "$APP_ICON" ]]; then
    print "==> generating app icon"
    swift "$PROJECT_ROOT/scripts/generate-app-icon.swift"
fi

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

STAGING_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/llmusage-dev.XXXXXX")
trap "rm -rf '$STAGING_ROOT'" EXIT

STAGED_CONTROL_CENTER="$STAGING_ROOT/$CONTROL_CENTER_NAME.app"
STAGED_TRACKER="$STAGED_CONTROL_CENTER/Contents/Library/LoginItems/$TRACKER_NAME.app"

print "==> staging"
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

print "==> signing ($SIGNING_IDENTITY)"
codesign --force --sign "$SIGNING_IDENTITY" "$STAGED_TRACKER"
codesign --force --sign "$SIGNING_IDENTITY" "$STAGED_CONTROL_CENTER"
codesign --verify --deep --strict "$STAGED_CONTROL_CENTER"

print "==> stopping old processes"
for app_name in "$TRACKER_NAME" "$CONTROL_CENTER_NAME"; do
    for app_pid in ${(f)$(/usr/bin/pgrep -x "$app_name" || true)}; do
        /bin/kill "$app_pid" 2>/dev/null || true
    done
done

print "==> installing"
mkdir -p /Applications
if [[ -d "$LEGACY_CONTROL_CENTER_DESTINATION" ]]; then
    "$LSREGISTER" -u "$LEGACY_CONTROL_CENTER_DESTINATION/Contents/Library/LoginItems/$TRACKER_NAME.app" >/dev/null 2>&1 || true
    "$LSREGISTER" -u "$LEGACY_CONTROL_CENTER_DESTINATION" >/dev/null 2>&1 || true
    rm -rf "$LEGACY_CONTROL_CENTER_DESTINATION"
fi
rm -rf "$CONTROL_CENTER_DESTINATION"
ditto "$STAGED_CONTROL_CENTER" "$CONTROL_CENTER_DESTINATION"
codesign --verify --deep --strict "$CONTROL_CENTER_DESTINATION"

"$LSREGISTER" -f "$TRACKER_DESTINATION" >/dev/null 2>&1 || true
"$LSREGISTER" -f "$CONTROL_CENTER_DESTINATION" >/dev/null 2>&1 || true

print "==> launching $TRACKER_NAME"
/usr/bin/open "$TRACKER_DESTINATION"

print "Installed $TRACKER_DESTINATION"
print "Installed $CONTROL_CENTER_DESTINATION"

open "$CONTROL_CENTER_DESTINATION"
