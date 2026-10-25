#!/bin/bash
# Sign nested code before the helper and app.
set -euo pipefail
if [ "$#" -ne 2 ]; then
    echo "Usage: bash Scripts/sign-app.sh 'Developer ID Application: name (TEAM)' build/Release" >&2
    exit 2
fi
sign_identity="$1"
sign_products="$2"
sign_root="$(cd "$(dirname "$0")/.." && pwd)"
sign_app="$sign_products/ReYogaSMC.app"
sign_helper="$sign_app/Contents/Library/LoginItems/ReYogaSMCHelper.app"
if [ ! -d "$sign_helper" ]; then
    echo 'The app or embedded login helper is missing. Build BuildAll first.' >&2
    exit 1
fi
sign_options=(--timestamp=none)
if [ "$sign_identity" != "-" ]; then sign_options=(--options runtime --timestamp); fi
while IFS= read -r -d '' library; do
    codesign --force "${sign_options[@]}" --sign "$sign_identity" "$library"
done < <(find "$sign_app" -depth -type f -name '*.dylib' -print0)
codesign --force "${sign_options[@]}" --sign "$sign_identity" "$sign_helper"
codesign --force "${sign_options[@]}" --entitlements "$sign_root/ReYogaSMCApp/ReYogaSMCApp.entitlements" --sign "$sign_identity" "$sign_app"
codesign --verify --deep --strict --verbose=2 "$sign_app"
echo 'App signature verified.'
