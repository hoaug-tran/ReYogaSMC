# Hardware profiles

Hardware profiles declare model identity, firmware interfaces and validation evidence for Lenovo laptops that expose model-specific ACPI EC sensor fields or USB RGB layouts. A source link or identity entry is not proof that every feature has been tested on hardware.

> [!NOTE]
> ThinkPad laptops (such as T, X, X1, P, L and E series) and standard IdeaPad/Yoga ACPI features (`GBMD`/`SBMC` battery conservation, rapid charge, keyboard backlight, Fn Lock, Always-On USB and WMI thermal modes) use generic ACPI/WMI methods and do not require a JSON file in this directory.

## Profile schema

Profiles in `HardwareProfiles/` use `schema_version: 1` and are consumed by `Scripts/generate_firmware_profiles.py` and the app adapters. Firmware fingerprints are required for raw-offset bridges; write validation is independent of identity and read support.

| Field | Type | Description |
| :--- | :--- | :--- |
| `schema_version` | integer | Must be `1` |
| `kind` | string | `acpi` for system firmware or `rgb` for a USB lighting controller |
| `id` | string | Unique profile identifier; ACPI entries are included in the generated driver table |
| `name` | string | Model name shown in the app (for example `Lenovo Legion 7 16ACHg6`) |
| `sources` | array of strings | References to Linux kernel drivers, PSREF specifications or Lenovo Legion Toolkit |
| `machine_types` | array of strings | Lenovo 4-character machine type codes (for example `82N6`, `82JQ`, `82WK`) |
| `bios_families` | array of strings | Lenovo 4-character BIOS family prefixes (for example `GKCN`, `KWCN`, `J2CN`) |
| `oem_table_ids` | array of strings | DSDT OEM table IDs (for example `CB-01`) |
| `pci_subsystem_ids` | array of strings | Optional model-specific Lenovo PCI subsystem IDs (`17aa:xxxx`) |
| `ec_path` | string | Absolute ACPI namespace path to the embedded controller (`\_SB.PCI0.LPC0.EC0` or `\_SB.PC00.LPCB.EC0`) |
| `ec_base` | string | Physical memory-mapped EC base address (optional) |
| `ec_size` | string | EC memory window size (optional) |
| `rpm_scale` | integer | Fan speed multiplier (`1` or `100`) |
| `battery_conservation_mask` | integer | Bitmask for conservation mode in `GBMD`/`SBMC` |
| `battery_rapidcharge_mask` | integer | Bitmask for rapid charge in `GBMD`/`SBMC` |
| `native_telemetry` | array of objects | Native ACPI sensor fields (`field` and `scale`) |

ACPI-specific fields do not apply to `rgb` profiles, which describe USB device matching and lighting layout. The supported schemas are enforced by the profile tests and adapters.

For raw-offset bridges, `reviewed_dsdt_hashes` or `reviewed_aml_hashes` identify reviewed firmware, `required_patterns` and `offsets` describe the declarations, and `verified_writes` records write validation. A native telemetry entry alone does not make a bridge eligible for generation. All current ACPI profiles leave manual fan writes disabled.

## Header generation

After editing or adding profiles, regenerate the kernel lookup header:

```sh
python3 Scripts/generate_firmware_profiles.py
python3 Scripts/generate_firmware_profiles.py --check
```

## Validation

Run the profile schema and identity tests:

```sh
python3 -B -m unittest Tests.test_profile_schemas Tests.test_firmware_profiles Tests.test_firmware_identity
```

Display identity also accepts optional `pci_subsystem_ids` entries (`"17aa:1234"`, lowercase hexadecimal subsystem vendor/device pairs). Only add IDs verified for that model; shared USB/RGB controller IDs do not identify a laptop. Machine types and PCI subsystem IDs do not grant firmware write permission. Ambiguous matches fall back to `Lenovo Laptop`; absent Lenovo evidence falls back to `Unknown Laptop`.
