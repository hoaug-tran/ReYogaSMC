#!/bin/bash
# Package built products and the hardware tool without including local reports.
set -euo pipefail
export COPYFILE_DISABLE=1
package_config="${1:-Release}"
case "$package_config" in Debug|Release) ;; *) echo 'Use Debug or Release' >&2; exit 2 ;; esac
package_root="$(cd "$(dirname "$0")/.." && pwd)"
package_products="$package_root/build/$package_config"
package_output="$package_root/build/packages/$package_config"
package_stage="$(mktemp -d)"
trap 'rm -rf "$package_stage"' EXIT
for package_product in ReYogaSMC.kext ReYogaSMCAlter.kext ReYogaSMCNC.app; do
    test -d "$package_products/$package_product" || { echo "Missing product: $package_product" >&2; exit 1; }
done
mkdir -p "$package_output" "$package_stage/kexts" "$package_stage/apps" "$package_stage/tool/Scripts" "$package_stage/tool/HardwareProfiles"
cp -R "$package_products/ReYogaSMC.kext" "$package_products/ReYogaSMCAlter.kext" "$package_root/ReYogaSMC/SSDTSample" "$package_stage/kexts/"
cp -R "$package_products/ReYogaSMCNC.app" "$package_stage/apps/"
cp "$package_root/LICENSE" "$package_root/README.md" "$package_stage/kexts/"
cp "$package_root/LICENSE" "$package_root/README.md" "$package_stage/apps/"
cp "$package_root/LICENSE" "$package_root/ReYoga.command" "$package_root/ReYoga.cmd" "$package_stage/tool/"
cp "$package_root/Docs/hardware-tool.md" "$package_stage/tool/README.md"
cp "$package_root/Scripts/hardware_support.py" "$package_root/Scripts/acpica.json" "$package_root/Scripts/ec_reader.py" "$package_root/Scripts/pawnio.json" "$package_root/Scripts/windows_support.py" "$package_root/Scripts/windows_inventory.ps1" "$package_root/Scripts/windows_probes.json" "$package_stage/tool/Scripts/"
cp "$package_root/HardwareProfiles/"*.json "$package_root/HardwareProfiles/"*.dsl "$package_root/HardwareProfiles/README.md" "$package_stage/tool/HardwareProfiles/"
ln -s /Applications "$package_stage/apps/Applications"
for package_kind in kexts apps tool; do
    ditto --norsrc --noextattr --noacl -c -k --keepParent "$package_stage/$package_kind" "$package_output/ReYogaSMC-$package_kind-$package_config.zip"
done
echo "Packages: $package_output"
