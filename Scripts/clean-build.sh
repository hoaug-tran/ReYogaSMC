#!/bin/bash
# Remove ReYogaSMC build products and Xcode intermediates without requiring root.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
if [ "${EUID:-$(id -u)}" -eq 0 ] && [ -n "${SUDO_USER:-}" ]; then
    chown -R "$SUDO_USER" "$root/build" 2>/dev/null || true
    exec sudo -u "$SUDO_USER" bash "$0" "$@"
fi
if [ -e "$root/build" ]; then
    if [ ! -w "$root/build" ]; then
        echo "Error: $root/build is not writable by $(id -un). Run: sudo chown -R $(id -un) \"$root/build\"" >&2
        exit 1
    fi
    rm -rf "$root/build"
fi
rm -rf "${TMPDIR%/}/ReYogaSMC-DerivedData" "${TMPDIR%/}/ReYogaSMC-Intermediates" "$root/.verify-derived"*
echo "Cleaned writable ReYogaSMC build products and intermediates."
