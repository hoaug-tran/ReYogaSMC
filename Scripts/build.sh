#!/bin/bash
# Clean and build one configuration from a predictable workspace.
# Set DERIVED_DATA_PATH to keep intermediates outside the repository.
set -euo pipefail
configuration="${1:-Release}"
case "$configuration" in Debug|Release) ;; *) echo 'Usage: bash Scripts/build.sh [Debug|Release]' >&2; exit 2 ;; esac
root="$(cd "$(dirname "$0")/.." && pwd)"
bash "$root/Scripts/clean-build.sh"
cd "$root"

build_dir="$root/build"
derived_data="${DERIVED_DATA_PATH:-$build_dir/DerivedData}"

xcodebuild -project ReYogaSMC.xcodeproj \
    -scheme BuildAll \
    -configuration "$configuration" \
    CODE_SIGNING_ALLOWED=NO \
    -derivedDataPath "$derived_data" \
    SYMROOT="$build_dir" \
    OBJROOT="$build_dir/Intermediates" \
    build

