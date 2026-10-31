#!/bin/bash
# Build the root broker separately; signing happens before the containing app.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
output="$TARGET_BUILD_DIR/$CONTENTS_FOLDER_PATH/Library/LaunchServices"
mkdir -p "$output"
architectures=()
for architecture in $ARCHS; do architectures+=(-arch "$architecture"); done
xcrun --sdk macosx clang -fobjc-arc -fblocks -Wall -Wextra -Werror \
    "${architectures[@]}" -isysroot "$SDKROOT" -mmacosx-version-min="$MACOSX_DEPLOYMENT_TARGET" \
    "$root/ReYogaSMCFanHelper/main.m" -framework Foundation -framework Security -framework IOKit -lbsm \
    -o "$output/org.reyoga.ReYogaSMC.FanAuthorization"
/usr/bin/codesign --force --sign - --timestamp=none "$output/org.reyoga.ReYogaSMC.FanAuthorization"
