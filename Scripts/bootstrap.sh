#!/bin/bash
# Reproducible SDK setup. No downloaded shell script is evaluated.
set -euo pipefail
bootstrap_root="$(cd "$(dirname "$0")/.." && pwd)"
bootstrap_tmp="$(mktemp -d)"
trap 'rm -rf "$bootstrap_tmp"' EXIT
bootstrap_revision="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["MacKernelSDK"]["revision"])' "$bootstrap_root/Scripts/dependencies.json")"
if [ ! -d "$bootstrap_root/MacKernelSDK/.git" ]; then
    git clone --no-checkout https://github.com/acidanthera/MacKernelSDK.git "$bootstrap_root/MacKernelSDK"
    git -C "$bootstrap_root/MacKernelSDK" checkout --detach "$bootstrap_revision"
fi
if [ "$(git -C "$bootstrap_root/MacKernelSDK" rev-parse HEAD)" != "$bootstrap_revision" ]; then
    echo 'MacKernelSDK differs from the dependency lock. Preserve local changes and select the locked revision explicitly.' >&2
    exit 1
fi
for bootstrap_name in Lilu VirtualSMC; do
    bootstrap_version="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]]["version"])' "$bootstrap_root/Scripts/dependencies.json" "$bootstrap_name")"
    bootstrap_sha="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]]["sha256"])' "$bootstrap_root/Scripts/dependencies.json" "$bootstrap_name")"
    bootstrap_archive="$bootstrap_tmp/$bootstrap_name.zip"
    curl --fail --location --silent --show-error "https://github.com/acidanthera/$bootstrap_name/releases/download/$bootstrap_version/$bootstrap_name-$bootstrap_version-DEBUG.zip" -o "$bootstrap_archive"
    bootstrap_actual="$(shasum -a 256 "$bootstrap_archive" | awk '{print $1}')"
    if [ "$bootstrap_actual" != "$bootstrap_sha" ]; then echo "Checksum mismatch: $bootstrap_name" >&2; exit 1; fi
    unzip -q "$bootstrap_archive" -d "$bootstrap_tmp/$bootstrap_name"
    bootstrap_source="$bootstrap_tmp/$bootstrap_name/$bootstrap_name.kext"
    if [ "$bootstrap_name" = VirtualSMC ]; then bootstrap_source="$bootstrap_tmp/$bootstrap_name/Kexts/VirtualSMC.kext"; fi
    if [ -d "$bootstrap_root/$bootstrap_name.kext" ]; then
        bootstrap_installed="$(/usr/libexec/PlistBuddy -c 'Print CFBundleVersion' "$bootstrap_root/$bootstrap_name.kext/Contents/Info.plist")"
        if [ "$bootstrap_installed" != "$bootstrap_version" ]; then echo "Existing $bootstrap_name.kext differs; preserve it before replacing the SDK." >&2; exit 1; fi
    else
        cp -R "$bootstrap_source" "$bootstrap_root/"
    fi
done
