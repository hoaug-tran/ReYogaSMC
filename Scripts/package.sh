#!/bin/bash
# Package each driver variant and the app separately.
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
for package_name in ReYogaSMC ReYogaSMCAlter ReYogaSMCNC; do
    package_extension=kext
    if [ "$package_name" = ReYogaSMCNC ]; then package_extension=app; fi
    package_product="$package_products/$package_name.$package_extension"
    test -f "$package_product/Contents/MacOS/$package_name" || { echo "Missing executable: $package_name" >&2; exit 1; }
    package_product_version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$package_product/Contents/Info.plist")"
    if [ "$package_product_version" != "$package_version" ]; then echo "Version mismatch: $package_name" >&2; exit 1; fi
    mkdir -p "$package_stage/$package_name"
    cp -R "$package_product" "$package_stage/$package_name/"
    cp "$package_root/LICENSE" "$package_root/README.md" "$package_stage/$package_name/"
    if [ "$package_extension" = app ]; then
        ln -s /Applications "$package_stage/$package_name/Applications"
    else
        cp -R "$package_root/ReYogaSMC/SSDTSample" "$package_stage/$package_name/"
    fi
    ditto --norsrc --noextattr --noacl -c -k --keepParent "$package_stage/$package_name" "$package_output/$package_name-$package_version-$package_label.zip"
done
echo "Packages: $package_output"
