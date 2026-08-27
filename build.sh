#!/bin/bash
#
# Local ad-hoc build. Derives a version from git and delegates to
# scripts/package.sh, so local builds run exactly what CI runs.
#
# Usage: ./build.sh [version] [build-number]

set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
version="${1:-$(git -C "$repo_root" describe --tags --abbrev=0 2>/dev/null | sed 's/^v//')}"
version="${version:-0.0.0}"
build_number="${2:-$(git -C "$repo_root" rev-list --count HEAD)}"

exec "$repo_root/scripts/package.sh" "$version" "$build_number" "$repo_root/dist"
