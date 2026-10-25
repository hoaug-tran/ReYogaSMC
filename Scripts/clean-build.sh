#!/bin/bash
# Remove ReYogaSMC build products and Xcode intermediates without requiring root.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
if [ "${EUID:-$(id -u)}" -eq 0 ] && [ -n "${SUDO_USER:-}" ]; then
    chown -R "$SUDO_USER" "$root/build" "$root/build-user" 2>/dev/null || true
    exec sudo -u "$SUDO_USER" bash "$0" "$@"
fi
for dir in "$root/build" "$root/build-user"; do
    if [ -e "$dir" ] && [ -w "$dir" ]; then
        rm -rf "$dir"
    fi
done
rm -rf "${TMPDIR%/}/ReYogaSMC-DerivedData" "${TMPDIR%/}/ReYogaSMC-Intermediates" "$root/.verify-derived"*
echo "Cleaned writable ReYogaSMC build products and intermediates."
