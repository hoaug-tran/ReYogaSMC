#!/bin/bash
# Sign the installed app and its helper with one persistent identity.
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
codesign --force --options runtime --timestamp --sign "$sign_identity" "$sign_helper"
codesign --force --options runtime --timestamp --entitlements "$sign_root/ReYogaSMCApp/ReYogaSMCApp.entitlements" --sign "$sign_identity" "$sign_app"
codesign --verify --deep --strict --verbose=2 "$sign_app"
codesign -d -r- --verbose=4 "$sign_app"
echo 'App signed. Keep this identity for updates. Notarization is a separate distribution step.'
