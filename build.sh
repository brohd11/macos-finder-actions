  set -euo pipefail

  local_build_root="$(mktemp -d /private/tmp/finder-actions-local.XXXXXX)"
  local_derived="$local_build_root/DerivedData"
  local_stage="$local_build_root/Package"
  local_app="$local_stage/Finder Actions.app"
  local_entitlements="$local_build_root/FinderSync.entitlements"

  xcodebuild \
    -project FinderActions.xcodeproj \
    -scheme FinderActions \
    -configuration Release \
    -destination 'generic/platform=macOS' \
    -derivedDataPath "$local_derived" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    DEVELOPMENT_TEAM= \
    'BUNDLE_ID_PREFIX=com.brohd' \
    'MACH_SERVICE_NAME=com.brohd.FinderActions.runner' \
    'LEGACY_MACH_SERVICE_NAME=group.com.brohd.FinderActions.runner' \
    ONLY_ACTIVE_ARCH=NO \
    'ARCHS=arm64 x86_64' \
    build

  mkdir -p "$local_stage"
  ditto \
    "$local_derived/Build/Products/Release/Finder Actions.app" \
    "$local_app"

  for plist_path in \
    "$local_app/Contents/Info.plist" \
    "$local_app/Contents/PlugIns/FinderActionsFinderSync.appex/Contents/Info.plist" \
    "$local_app/Contents/Library/LoginItems/FinderActionsRunner.app/Contents/Info.plist"
  do
    /usr/libexec/PlistBuddy \
      -c 'Set :CFBundleShortVersionString 0.1.4' \
      "$plist_path"
    /usr/libexec/PlistBuddy \
      -c 'Set :CFBundleVersion 9' \
      "$plist_path"
    plutil -lint "$plist_path"
  done

  cp Resources/Entitlements/FinderSync.entitlements "$local_entitlements"

  /usr/libexec/PlistBuddy \
    -c 'Set :com.apple.security.temporary-exception.mach-lookup.global-name:0 com.brohd.FinderActions.runner' \
    "$local_entitlements"

  local_extension="$local_app/Contents/PlugIns/FinderActionsFinderSync.appex"
  local_runner="$local_app/Contents/Library/LoginItems/FinderActionsRunner.app"

  codesign --force --sign - --timestamp=none --options runtime \
    "$local_runner"

  codesign --force --sign - --timestamp=none --options runtime \
    --entitlements "$local_entitlements" \
    "$local_extension"

  codesign --force --sign - --timestamp=none --options runtime \
    "$local_app"

  codesign --verify --strict --verbose=2 "$local_runner"
  codesign --verify --strict --verbose=2 "$local_extension"
  codesign --verify --deep --strict --verbose=2 "$local_app"

printf '\nSigned app:\n%s\n' "$local_app"