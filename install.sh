#!/bin/sh

set -eu

repository="brohd11/macos-finder-actions"
app_name="Finder Actions.app"
archive_name="Finder-Actions.zip"
checksum_name="Finder-Actions.zip.sha256"
release_base_url="https://github.com/$repository/releases/latest/download"
install_dir="${FINDER_ACTIONS_INSTALL_DIR:-/Applications}"
target_app="$install_dir/$app_name"

download_dir=""
stage_dir=""
backup_app=""
replacement_started=0

say() {
    printf '%s\n' "$*"
}

fail() {
    printf 'finder-actions installer: %s\n' "$*" >&2
    exit 1
}

path_exists() {
    [ -e "$1" ] || [ -L "$1" ]
}

cleanup() {
    status=$?
    trap - EXIT

    if [ "$replacement_started" -eq 1 ] && ! path_exists "$target_app" && path_exists "$backup_app"; then
        if ! mv "$backup_app" "$target_app"; then
            printf 'finder-actions installer: could not restore the previous app from %s\n' "$backup_app" >&2
            stage_dir=""
        fi
    fi

    if [ -n "$stage_dir" ]; then
        rm -rf -- "$stage_dir"
    fi
    if [ -n "$download_dir" ]; then
        rm -rf -- "$download_dir"
    fi

    exit "$status"
}

trap cleanup EXIT
trap 'exit 1' HUP INT TERM

[ "$(uname -s)" = "Darwin" ] || fail "Finder Actions requires macOS."

macos_version="$(sw_vers -productVersion)"
macos_major="${macos_version%%.*}"
case "$macos_major" in
    ''|*[!0-9]*) fail "could not determine the macOS version." ;;
esac
[ "$macos_major" -ge 13 ] || fail "Finder Actions requires macOS 13 or newer (found $macos_version)."

for required_command in curl ditto shasum codesign mktemp; do
    command -v "$required_command" >/dev/null 2>&1 || fail "required command not found: $required_command"
done
[ -x /usr/libexec/PlistBuddy ] || fail "required command not found: /usr/libexec/PlistBuddy"

case "$install_dir" in
    /*) ;;
    *) fail "FINDER_ACTIONS_INSTALL_DIR must be an absolute path." ;;
esac

if [ ! -d "$install_dir" ]; then
    mkdir -p "$install_dir" || fail "could not create $install_dir."
fi
[ -w "$install_dir" ] || fail "cannot write to $install_dir. Set FINDER_ACTIONS_INSTALL_DIR to a writable absolute path."

umask 077
download_dir="$(mktemp -d "${TMPDIR:-/tmp}/finder-actions-download.XXXXXX")" || fail "could not create a temporary download directory."
archive_path="$download_dir/$archive_name"
checksum_path="$download_dir/$checksum_name"

say "Downloading the latest Finder Actions release..."
curl --fail --location --silent --show-error --retry 3 --proto '=https' --tlsv1.2 \
    --output "$archive_path" "$release_base_url/$archive_name"
curl --fail --location --silent --show-error --retry 3 --proto '=https' --tlsv1.2 \
    --output "$checksum_path" "$release_base_url/$checksum_name"

say "Verifying SHA-256 checksum..."
(
    cd "$download_dir"
    shasum -a 256 -c "$checksum_name"
) || fail "the downloaded archive did not match its published checksum."

extract_dir="$download_dir/extracted"
mkdir "$extract_dir"
ditto -x -k "$archive_path" "$extract_dir"
source_app="$extract_dir/$app_name"

[ -d "$source_app" ] || fail "the release archive does not contain $app_name."
[ -x "$source_app/Contents/MacOS/Finder Actions" ] || fail "the release contains an invalid app bundle."

bundle_id="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$source_app/Contents/Info.plist" 2>/dev/null || true)"
[ "$bundle_id" = "com.brohd.FinderActions" ] || fail "the release contains an unexpected bundle identifier: ${bundle_id:-missing}."
codesign --verify --deep --strict "$source_app" || fail "the release app failed code-signature verification."

stage_dir="$(mktemp -d "$install_dir/.finder-actions-install.XXXXXX")" || fail "could not create a staging directory in $install_dir."
staged_app="$stage_dir/$app_name"
ditto "$source_app" "$staged_app"
codesign --verify --deep --strict "$staged_app" || fail "the staged app failed code-signature verification."

if path_exists "$target_app"; then
    say "Replacing the existing app..."
    backup_app="$stage_dir/Previous Finder Actions.app"
    replacement_started=1
    mv "$target_app" "$backup_app" || fail "could not move the existing app out of the way."
else
    say "Installing Finder Actions..."
fi

mv "$staged_app" "$target_app" || fail "could not move Finder Actions into $install_dir."
replacement_started=0

say "Installed Finder Actions at $target_app"
say ""
say "Next steps:"
say "  1. Open $target_app"
say "  2. Enable the background runner in the dashboard."
say "  3. Enable Finder Actions under System Settings > Login Items & Extensions > Finder Extensions."
say ""
say "This installer does not change macOS quarantine settings. If macOS blocks the first launch,"
say "use Open Anyway under System Settings > Privacy & Security."
