#!/usr/bin/env bash
# Build, sign, notarize and zip an AeroSpace Alpha release.
#
#   script/release-alpha.sh --version 0.1 --codesign-identity "Developer ID Application: Name (TEAMID)" \
#       --notary-key /path/AuthKey.p8 --notary-key-id KEYID --notary-issuer ISSUER-UUID
#
#   --skip-notarize        sign only (local checks, dry runs)
#   --skip-build           reuse the existing .release/AeroSpace-v<version> stage
#   --codesign-identity -  ad-hoc signature (dry runs on CI without certificates)
#
# Output: .release/AeroSpace-Alpha-v<version>.zip containing AeroSpace.app, bin/aerospace,
# man pages, shell completion and legal notices. The app is signed with the hardened
# runtime and, unless skipped, notarized by Apple and stapled.
set -euo pipefail
cd "$(dirname "$0")/.."

version=""
identity=""
notary_key=""
notary_key_id=""
notary_issuer=""
notarize=true
build=true
while test $# -gt 0; do
    case $1 in
        --version) version="$2"; shift 2;;
        --codesign-identity) identity="$2"; shift 2;;
        --notary-key) notary_key="$2"; shift 2;;
        --notary-key-id) notary_key_id="$2"; shift 2;;
        --notary-issuer) notary_issuer="$2"; shift 2;;
        --skip-notarize) notarize=false; shift;;
        --skip-build) build=false; shift;;
        *) echo "Unknown option $1" >&2; exit 1;;
    esac
done
[ -n "$version" ] || { echo "--version is required" >&2; exit 1; }
[ -n "$identity" ] || { echo "--codesign-identity is required" >&2; exit 1; }
if $notarize; then
    for v in notary_key notary_key_id notary_issuer; do
        [ -n "${!v}" ] || { echo "--${v//_/-} is required unless --skip-notarize" >&2; exit 1; }
    done
    [ -f "$notary_key" ] || { echo "notary key not found: $notary_key" >&2; exit 1; }
fi

#############
### BUILD ###
#############
if $build; then
    ./build-release.sh --build-version "$version" --codesign-identity "$identity"
fi

stage=".release/AeroSpace-v$version"
app="$stage/AeroSpace.app"
cli="$stage/bin/aerospace"
[ -d "$app" ] && [ -f "$cli" ] || { echo "build-release.sh did not produce $stage" >&2; exit 1; }

#####################################
### SIGN WITH THE HARDENED RUNTIME ###
#####################################
# build-release.sh signs without the hardened runtime, which notarization requires.
sign_flags=(--force --options runtime)
[ "$identity" != "-" ] && sign_flags+=(--timestamp)
codesign "${sign_flags[@]}" -s "$identity" "$cli"
codesign "${sign_flags[@]}" -s "$identity" --entitlements resources/AeroSpace.entitlements "$app"
codesign --verify --strict --verbose=2 "$app"
codesign --verify --strict --verbose=2 "$cli"
for bin in "$app" "$cli"; do
    flags="$(codesign -d --verbose=1 "$bin" 2>&1 | grep -E '^CodeDirectory' || true)"
    case "$flags" in
        *runtime\)*) ;;   # "flags=0x10000(runtime)" or "0x10002(adhoc,runtime)"
        *) echo "hardened runtime flag missing on $bin: $flags" >&2; exit 1;;
    esac
done

################
### PACKAGE  ###
################
cd .release
rm -rf "AeroSpace-Alpha-v$version" "AeroSpace-Alpha-v$version.zip"
mv "AeroSpace-v$version" "AeroSpace-Alpha-v$version"
rm -f "AeroSpace-v$version.zip"
zip -qry "AeroSpace-Alpha-v$version.zip" "AeroSpace-Alpha-v$version"
cd ..
zip_path=".release/AeroSpace-Alpha-v$version.zip"

################
### NOTARIZE ###
################
if $notarize; then
    echo "Submitting $zip_path for notarization"
    xcrun notarytool submit "$zip_path" \
        --key "$notary_key" --key-id "$notary_key_id" --issuer "$notary_issuer" \
        --wait --timeout 30m
    xcrun stapler staple ".release/AeroSpace-Alpha-v$version/AeroSpace.app"
    xcrun stapler validate ".release/AeroSpace-Alpha-v$version/AeroSpace.app"
    # Re-zip so the download carries the stapled ticket.
    cd .release
    rm -f "AeroSpace-Alpha-v$version.zip"
    zip -qry "AeroSpace-Alpha-v$version.zip" "AeroSpace-Alpha-v$version"
    cd ..
    spctl --assess --type execute --verbose=2 ".release/AeroSpace-Alpha-v$version/AeroSpace.app"
else
    echo "Notarization skipped"
fi

echo "Release artifact: $zip_path"
shasum -a 256 "$zip_path"
