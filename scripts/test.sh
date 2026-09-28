#!/bin/bash
#
# Runs the Xcode test suite unsigned. Used by the release workflow before packaging.
#
# Usage: scripts/test.sh

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
derived="$(mktemp -d "${TMPDIR:-/tmp}/finder-actions-test.XXXXXX")"
trap 'rm -rf "$derived"' EXIT

: "${BUNDLE_ID_PREFIX:=com.brohd}"
: "${MACH_SERVICE_NAME:=$BUNDLE_ID_PREFIX.FinderActions.runner}"

xcodebuild \
    -project "$repo_root/FinderActions.xcodeproj" \
    -scheme FinderActions \
    -configuration Debug \
    -destination 'platform=macOS' \
    -derivedDataPath "$derived" \
    CODE_SIGNING_ALLOWED=NO \
    CODE_SIGNING_REQUIRED=NO \
    DEVELOPMENT_TEAM= \
    "BUNDLE_ID_PREFIX=$BUNDLE_ID_PREFIX" \
    "MACH_SERVICE_NAME=$MACH_SERVICE_NAME" \
    ONLY_ACTIVE_ARCH=YES \
    "ARCHS=$(uname -m)" \
    test
