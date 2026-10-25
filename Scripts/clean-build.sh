#!/bin/bash
# Remove only ReYogaSMC build products and Xcode intermediates.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
rm -rf "$root/build"
rm -rf "$root/.verify-derived"*
mkdir -p "$root/build"
echo "Cleaned ReYogaSMC build products and intermediates."
