#!/usr/bin/env bash
# Build a signed release of the current commit and stage it for aerospace-switch
# (see JasonBates/aerospace-config). Run from a clean working tree; the build is
# named after the commit.
#
#   ./build-personal-release.sh [label] [--laptop]
#
# Puts AeroSpace.app and the CLI in ~/.local/share/aerospace-builds/<label>-<hash>/
# (label defaults to "features"). --laptop also copies the staged build to the laptop.
# Signing identity and laptop address come from ~/.config/aerospace-build.env.
set -euo pipefail
cd "$(dirname "$0")"

base_version=0.21.3
# Machine-specific values live outside the repository:
#   AEROSPACE_CODESIGN_IDENTITY  e.g. "Developer ID Application: Name (TEAMID)"
#   AEROSPACE_LAPTOP             user@host for --laptop
env_file="${AEROSPACE_BUILD_ENV:-$HOME/.config/aerospace-build.env}"
# shellcheck source=/dev/null
[ -f "$env_file" ] && . "$env_file"
identity="${AEROSPACE_CODESIGN_IDENTITY:?set AEROSPACE_CODESIGN_IDENTITY (or put it in $env_file)}"
laptop="${AEROSPACE_LAPTOP:-}"
label=features
copy_to_laptop=false
for arg in "$@"; do
    case "$arg" in
        --laptop) copy_to_laptop=true ;;
        *) label="$arg" ;;
    esac
done

if [ -n "$(git status --porcelain)" ]; then
    echo "Commit or stash your changes first: the build is named after the commit" >&2
    exit 1
fi
name="$label-$(git rev-parse --short HEAD)"

# The Command Line Tools SDK can be newer than the Swift toolchain's linker understands
# ("unknown architecture arm64e.x1"), so build against Xcode's SDK.
export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
export SDKROOT="$(xcrun --sdk macosx --show-sdk-path)"

./build-release.sh --build-version "$base_version-$label" --codesign-identity "$identity"

builds="$HOME/.local/share/aerospace-builds"
dest="$builds/$name"
rm -rf "$dest"
mkdir -p "$dest"
ditto .release/AeroSpace.app "$dest/AeroSpace.app"
cp .release/aerospace "$dest/aerospace"
codesign -v --strict "$dest/AeroSpace.app"
codesign -v "$dest/aerospace"
echo "Staged $dest"

if $copy_to_laptop; then
    : "${laptop:?set AEROSPACE_LAPTOP (user@host) for --laptop}"
    tar -C "$builds" -cf - "$name" | ssh "$laptop" "mkdir -p ~/.local/share/aerospace-builds && tar -C ~/.local/share/aerospace-builds -xf -"
    echo "Copied to the laptop"
fi
echo "Install with: aerospace-switch $name"
