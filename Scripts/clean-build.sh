#!/bin/bash
# Remove ReYogaSMC build products and Xcode intermediates without requiring root.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"

if [ "${EUID:-$(id -u)}" -eq 0 ] && [ -n "${SUDO_USER:-}" ]; then
    if [ -L "$root/build" ]; then
        chown -h "$SUDO_USER" "$root/build" 2>/dev/null || true
    elif [ -d "$root/build" ]; then
        chown -R -P "$SUDO_USER" "$root/build" 2>/dev/null || true
    fi
    exec sudo -u "$SUDO_USER" bash "$0" "$@"
fi

if [ -L "$root/build" ]; then
    rm -f "$root/build" 2>/dev/null || rm -rf "$root/build"
elif [ -d "$root/build" ]; then
    if [ ! -w "$root/build" ]; then
        echo "Error: $root/build is not writable by $(id -un). Run: sudo chown -R $(id -un) \"$root/build\"" >&2
        exit 1
    fi
    for item in "$root/build"/Debug "$root/build"/Release "$root/build"/DerivedData \
                "$root/build"/Intermediates "$root/build"/packages "$root/build"/ReYogaUIReview \
                "$root/build"/SupportTests "$root/build"/HardwareProfiles \
                "$root/build"/release-plan.json "$root/build"/release-notes.md; do
        if [ -L "$item" ]; then
            rm -f "$item" 2>/dev/null || rm -rf "$item"
        elif [ -e "$item" ]; then
            rm -rf "$item"
        fi
    done
    for log_file in "$root/build"/*.log; do
        if [ -L "$log_file" ] || [ -f "$log_file" ]; then
            rm -f "$log_file"
        fi
    done
    rmdir "$root/build" 2>/dev/null || true
elif [ -e "$root/build" ]; then
    if [ ! -w "$root/build" ]; then
        echo "Error: $root/build is not writable by $(id -un). Run: sudo chown -R $(id -un) \"$root/build\"" >&2
        exit 1
    fi
    rm -f "$root/build"
fi

echo "Cleaned writable ReYogaSMC build products and intermediates."
