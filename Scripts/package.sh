#!/bin/bash
# Package the kext and app cleanly without requiring root.
set -euo pipefail
export COPYFILE_DISABLE=1
package_config="${1:-Release}"
case "$package_config" in Debug|Release) ;; *) echo 'Use Debug or Release' >&2; exit 2 ;; esac
package_root="$(cd "$(dirname "$0")/.." && pwd)"

if [ "${EUID:-$(id -u)}" -eq 0 ] && [ -n "${SUDO_USER:-}" ]; then
    chown -R "$SUDO_USER" "$package_root/build" 2>/dev/null || true
    exec sudo -u "$SUDO_USER" bash "$0" "$@"
fi

build_dir="${BUILD_DIR:-$package_root/build}"
if [ -e "$build_dir" ] && [ ! -w "$build_dir" ]; then
    echo "Error: $build_dir is not writable by $(id -un). Run: sudo chown -R $(id -un) \"$build_dir\"" >&2
    exit 1
fi

package_products="$build_dir/$package_config"
package_output="$build_dir/packages/$package_config"
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
for bundle in "$app_dir" "$app_dir/Contents/Library/LoginItems/ReYogaSMCHelper.app"; do
    app_version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$bundle/Contents/Info.plist")"
    test "$app_version" = "$package_version" || { echo 'App/helper and kext versions differ' >&2; exit 1; }
done
mkdir -p "$package_stage/app_pkg"
cp -R "$app_dir" "$package_stage/app_pkg/"
staged_app="$package_stage/app_pkg/ReYogaSMC.app"
if ! codesign --verify --deep --strict "$staged_app" >/dev/null 2>&1; then
    bash "$package_root/Scripts/sign-app.sh" - "$package_stage/app_pkg"
fi
codesign --verify --deep --strict "$staged_app"
ditto --norsrc --noextattr --noacl -c -k --keepParent "$staged_app" "$package_output/ReYogaSMC-App-$package_version-$package_label.zip"

echo "Packages: $package_output"
