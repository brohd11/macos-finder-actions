#!/bin/bash
#
# Regenerates Resources/Icons/*.icns from the matching *.svg sources.
# Run this by hand whenever the artwork changes; the .icns outputs are committed
# so that a plain xcodebuild needs no icon tooling.
#
# Usage: scripts/make-icons.sh

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
icons_dir="$repo_root/Resources/Icons"
renderer="$repo_root/scripts/render-icon.swift"

work_dir="$(mktemp -d "${TMPDIR:-/tmp}/finder-actions-icons.XXXXXX")"
trap 'rm -rf "$work_dir"' EXIT

# iconutil slot name -> pixel size.
slots=(
    "icon_16x16:16"
    "icon_16x16@2x:32"
    "icon_32x32:32"
    "icon_32x32@2x:64"
    "icon_128x128:128"
    "icon_128x128@2x:256"
    "icon_256x256:256"
    "icon_256x256@2x:512"
    "icon_512x512:512"
    "icon_512x512@2x:1024"
)

shopt -s nullglob
sources=("$icons_dir"/*.svg)
shopt -u nullglob

if [ "${#sources[@]}" -eq 0 ]; then
    echo "no SVG sources found in $icons_dir" >&2
    exit 1
fi

for source in "${sources[@]}"; do
    name="$(basename "$source" .svg)"
    iconset="$work_dir/$name.iconset"
    mkdir -p "$iconset"

    echo "==> Rendering $name"
    for slot in "${slots[@]}"; do
        swift "$renderer" "$source" "${slot#*:}" "$iconset/${slot%%:*}.png"
    done

    iconutil --convert icns --output "$icons_dir/$name.icns" "$iconset"
    echo "    $icons_dir/$name.icns"
done
