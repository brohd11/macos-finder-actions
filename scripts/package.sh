#!/bin/bash
#
# Builds, ad-hoc signs, verifies and archives Finder Actions.
# Single source of truth for packaging: used by build.sh and by CI.
#
# Usage: scripts/package.sh <version> <build-number> [output-dir]

set -euo pipefail

if [ "$#" -lt 2 ] || [ "$#" -gt 3 ]; then
    echo "usage: $0 <version> <build-number> [output-dir]" >&2
    exit 2
fi

version="$1"
build_number="$2"
repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
output_dir="${3:-$repo_root/dist}"

if [[ ! "$version" =~ ^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)$ ]]; then
    echo "version must be MAJOR.MINOR.PATCH without leading zeroes, got: $version" >&2
    exit 2
fi
if [[ ! "$build_number" =~ ^[0-9]+$ ]]; then
    echo "build number must be a nonnegative integer, got: $build_number" >&2
    exit 2
fi

: "${BUNDLE_ID_PREFIX:=com.brohd}"
: "${MACH_SERVICE_NAME:=$BUNDLE_ID_PREFIX.FinderActions.runner}"

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/finder-actions-package.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT

derived="$work_dir/DerivedData"
stage="$work_dir/Package"
app="$stage/Finder Actions.app"
extension="$app/Contents/PlugIns/FinderActionsFinderSync.appex"
runner="$app/Contents/Library/LoginItems/FinderActionsRunner.app"
entitlements="$work_dir/FinderSync.entitlements"

# --- Build: unsigned universal, versions injected as build settings ---------
echo "==> Building Finder Actions $version ($build_number)"
xcodebuild \
    -project "$repo_root/FinderActions.xcodeproj" \
    -scheme FinderActions \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$derived" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    DEVELOPMENT_TEAM= \
    "BUNDLE_ID_PREFIX=$BUNDLE_ID_PREFIX" \
    "MACH_SERVICE_NAME=$MACH_SERVICE_NAME" \
    "MARKETING_VERSION=$version" \
    "CURRENT_PROJECT_VERSION=$build_number" \
    ONLY_ACTIVE_ARCH=NO \
    'ARCHS=arm64 x86_64' \
    build

mkdir -p "$stage"
ditto "$derived/Build/Products/Release/Finder Actions.app" "$app"

# --- Sign: ad-hoc, inside out ----------------------------------------------
echo "==> Applying ad-hoc signatures"
cp "$repo_root/Resources/Entitlements/FinderSync.entitlements" "$entitlements"
/usr/libexec/PlistBuddy \
    -c "Set :com.apple.security.temporary-exception.mach-lookup.global-name:0 $MACH_SERVICE_NAME" \
    "$entitlements"
plutil -lint "$entitlements"

codesign --force --sign - --timestamp=none --options runtime "$runner"
codesign --force --sign - --timestamp=none --options runtime \
    --entitlements "$entitlements" "$extension"
codesign --force --sign - --timestamp=none --options runtime "$app"

# --- Verify ----------------------------------------------------------------
echo "==> Verifying package"

require_universal() {
    local binary="$1" architectures
    architectures="$(lipo -archs "$binary")"
    echo "$binary: $architectures"
    [[ " $architectures " == *' arm64 '* ]]
    [[ " $architectures " == *' x86_64 '* ]]
}

assert_plist_value() {
    local plist="$1" key="$2" expected="$3" actual
    actual="$(/usr/libexec/PlistBuddy -c "Print :$key" "$plist")"
    if [[ "$actual" != "$expected" ]]; then
        echo "$plist: expected $key=$expected, found $actual" >&2
        exit 1
    fi
}

require_universal "$app/Contents/MacOS/Finder Actions"
require_universal "$extension/Contents/MacOS/FinderActionsFinderSync"
require_universal "$runner/Contents/MacOS/FinderActionsRunner"

assert_plist_value "$app/Contents/Info.plist" CFBundleIdentifier "$BUNDLE_ID_PREFIX.FinderActions"
assert_plist_value "$extension/Contents/Info.plist" CFBundleIdentifier "$BUNDLE_ID_PREFIX.FinderActions.FinderSync"
assert_plist_value "$runner/Contents/Info.plist" CFBundleIdentifier "$BUNDLE_ID_PREFIX.FinderActions.Runner"
for plist in "$app/Contents/Info.plist" "$extension/Contents/Info.plist" "$runner/Contents/Info.plist"; do
    assert_plist_value "$plist" MachServiceName "$MACH_SERVICE_NAME"
    assert_plist_value "$plist" CFBundleShortVersionString "$version"
    assert_plist_value "$plist" CFBundleVersion "$build_number"
done

if [ -e "$app/Contents/Library/LaunchAgents" ]; then
    echo 'The bundle must not ship a LaunchAgents directory; the app writes one per user.' >&2
    exit 1
fi

codesign --verify --strict --verbose=2 "$runner"
codesign --verify --strict --verbose=2 "$extension"
codesign --verify --deep --strict --verbose=2 "$app"

signature_info="$(codesign -d --verbose=4 "$app" 2>&1)"
echo "$signature_info"
grep -q '^Signature=adhoc$' <<< "$signature_info"
grep -q '^TeamIdentifier=not set$' <<< "$signature_info"

if find "$app" -name embedded.provisionprofile -print | grep -q .; then
    echo 'An ad-hoc release must not contain a provisioning profile.' >&2
    exit 1
fi

for code in "$app" "$extension" "$runner"; do
    if codesign -d --entitlements :- "$code" 2>&1 | grep -q 'com.apple.security.application-groups'; then
        echo "$code unexpectedly contains an App Group entitlement." >&2
        exit 1
    fi
done

extension_entitlements="$(codesign -d --entitlements :- "$extension" 2>&1)"
grep -q 'com.apple.security.app-sandbox' <<< "$extension_entitlements"
if grep -q 'com.apple.security.temporary-exception.files.home-relative-path.read-only' <<< "$extension_entitlements"; then
    echo 'Finder extension unexpectedly has direct configuration-directory access.' >&2
    exit 1
fi
grep -q 'com.apple.security.temporary-exception.mach-lookup.global-name' <<< "$extension_entitlements"
grep -q "$MACH_SERVICE_NAME" <<< "$extension_entitlements"

echo 'Outer app entitlements:'
codesign -d --entitlements :- "$app" 2>&1
echo 'Finder extension entitlements:'
codesign -d --entitlements :- "$extension" 2>&1

echo 'Gatekeeper assessment (rejection is expected for an ad-hoc signature):'
set +e
spctl --assess --type execute --verbose=4 "$app"
echo "spctl exit status: $?"
set -e

# --- Archive ---------------------------------------------------------------
echo "==> Creating archive"
mkdir -p "$output_dir"
rm -f "$output_dir/Finder-Actions.zip" "$output_dir/Finder-Actions.zip.sha256"
ditto -c -k --sequesterRsrc --keepParent "$app" "$output_dir/Finder-Actions.zip"
(
    cd "$output_dir"
    shasum -a 256 Finder-Actions.zip > Finder-Actions.zip.sha256
    shasum -a 256 -c Finder-Actions.zip.sha256
)

printf '\nFinder Actions %s (%s)\n  %s\n  %s\n' \
    "$version" "$build_number" \
    "$output_dir/Finder-Actions.zip" \
    "$output_dir/Finder-Actions.zip.sha256"
