#!/bin/bash
# Build one configuration as a standard user without requiring sudo.
set -euo pipefail
configuration="${1:-Release}"
case "$configuration" in Debug|Release) ;; *) echo 'Usage: bash Scripts/build.sh [Debug|Release]' >&2; exit 2 ;; esac
root="$(cd "$(dirname "$0")/.." && pwd)"

if [ "${EUID:-$(id -u)}" -eq 0 ] && [ -n "${SUDO_USER:-}" ]; then
    if [ -L "$root/build" ]; then
        chown -h "$SUDO_USER" "$root/build" 2>/dev/null || true
    elif [ -d "$root/build" ]; then
        chown -R -P "$SUDO_USER" "$root/build" 2>/dev/null || true
    fi
    exec sudo -u "$SUDO_USER" bash "$0" "$@"
fi

build_dir="${BUILD_DIR:-$root/build}"
if [ -e "$build_dir" ] && [ ! -w "$build_dir" ]; then
    echo "Error: $build_dir is not writable by $(id -un). Run: sudo chown -R $(id -un) \"$build_dir\"" >&2
    exit 1
fi

derived_data="${DERIVED_DATA_PATH:-$build_dir/DerivedData}"
obj_root="${OBJROOT_PATH:-$build_dir/Intermediates}"

mkdir -p "$build_dir"

cd "$root"
xcodebuild -project ReYogaSMC.xcodeproj \
    -scheme BuildAll \
    -configuration "$configuration" \
    CODE_SIGNING_ALLOWED=NO \
    -derivedDataPath "$derived_data" \
    SYMROOT="$build_dir" \
    OBJROOT="$obj_root" \
    build

bash "$root/Scripts/sign-app.sh" - "$build_dir/$configuration"

echo "Built $configuration products in: $build_dir/$configuration"
