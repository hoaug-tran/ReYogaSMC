#!/bin/bash
# Package the kext and app cleanly.
set -euo pipefail
export COPYFILE_DISABLE=1
package_config="${1:-Release}"
case "$package_config" in Debug|Release) ;; *) echo 'Use Debug or Release' >&2; exit 2 ;; esac
package_root="$(cd "$(dirname "$0")/.." && pwd)"
package_products="$package_root/build/$package_config"
package_output="$package_root/build/packages/$package_config"
package_stage="$(mktemp -d)"
trap 'rm -rf "$package_stage"' EXIT
package_label="$(printf '%s' "$package_config" | tr '[:lower:]' '[:upper:]')"
package_version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$package_products/ReYogaSMC.kext/Contents/Info.plist")"
if [ -n "${BUILD_VERSION:-}" ] && [ "$package_version" != "$BUILD_VERSION" ]; then echo 'Build version mismatch' >&2; exit 1; fi
mkdir -p "$package_output"

# 1. Package ReYogaSMC.kext (ONLY the .kext inside zip)
kext_dir="$package_products/ReYogaSMC.kext"
test -f "$kext_dir/Contents/MacOS/ReYogaSMC" || { echo "Missing kext binary" >&2; exit 1; }
ditto --norsrc --noextattr --noacl -c -k --keepParent "$kext_dir" "$package_output/ReYogaSMC-$package_version-$package_label.zip"

# 2. Package ReYogaSMC.app (App release bundle)
app_dir="$package_products/ReYogaSMC.app"
test -f "$app_dir/Contents/MacOS/ReYogaSMC" || { echo "Missing app binary" >&2; exit 1; }
mkdir -p "$package_stage/app_pkg"
cp -R "$app_dir" "$package_stage/app_pkg/"
ditto --norsrc --noextattr --noacl -c -k --keepParent "$package_stage/app_pkg/ReYogaSMC.app" "$package_output/ReYogaSMC-App-$package_version-$package_label.zip"

echo "Packages: $package_output"
