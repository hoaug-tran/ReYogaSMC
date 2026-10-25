#!/bin/bash
# Build one configuration as a standard user without requiring sudo.
set -euo pipefail
configuration="${1:-Release}"
case "$configuration" in Debug|Release) ;; *) echo 'Usage: bash Scripts/build.sh [Debug|Release]' >&2; exit 2 ;; esac
root="$(cd "$(dirname "$0")/.." && pwd)"

if [ "${EUID:-$(id -u)}" -eq 0 ] && [ -n "${SUDO_USER:-}" ]; then
    chown -R "$SUDO_USER" "$root/build" "$root/build-user" 2>/dev/null || true
    exec sudo -u "$SUDO_USER" bash "$0" "$@"
fi

build_dir="${BUILD_DIR:-$root/build}"
if [ -e "$build_dir" ] && [ ! -w "$build_dir" ]; then
    build_dir="$root/build-user"
    echo "Notice: $root/build is not writable by $(id -un); writing build products to $build_dir" >&2
fi

derived_data="${DERIVED_DATA_PATH:-${TMPDIR%/}/ReYogaSMC-DerivedData}"
obj_root="${OBJROOT_PATH:-${TMPDIR%/}/ReYogaSMC-Intermediates}"

rm -rf "$build_dir/$configuration" "$derived_data" "$obj_root"
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

echo "Built $configuration products in: $build_dir/$configuration"
