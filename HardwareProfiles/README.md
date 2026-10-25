# Hardware profiles

Hardware profiles declare model identity, firmware interfaces and validation evidence for Lenovo consumer and gaming laptop families (Legion, LOQ, IdeaPad Gaming, Yoga). A source link or identity entry is not proof that every feature has been tested on hardware.

> **Architecture Note**: ThinkPad models (e.g. T480, X1 Carbon, P52) communicate through the standard ThinkPad ACPI/SMM interface (`ThinkVPC` handling `HKEY`), which queries the Embedded Controller and CMOS dynamically without requiring per-model JSON profiles.

## Profile Schema (`schema_version: 1`)

Profiles in `HardwareProfiles/` are consumed by the kernel table generator and app adapters. Firmware fingerprints are required for raw-offset bridges; write validation is independent of identity and read support.

| Field | Type | Description |
| :--- | :--- | :--- |
| `schema_version` | integer | Must be `1` |
| `kind` | string | `acpi` for system firmware or `rgb` for lighting controller |
| `id` | string | Unique immutable identifier matching driver profile registry |
| `name` | string | Official commercial model name (e.g., `Lenovo Legion 7 2021 16ACHg6`) |
| `sources` | array of strings | References to Linux kernel driver (`legion-laptop.c`), PSREF specs, or Lenovo Legion Toolkit |
| `machine_types` | array of strings | Lenovo 4-character machine type codes (e.g., `82N6`, `82JQ`, `82WK`) |
| `bios_families` | array of strings | Lenovo 4-character BIOS family prefixes (e.g., `GKCN`, `KWCN`, `J2CN`) |
| `oem_table_ids` | array of strings | DSDT OEM Table ID identifiers (e.g., `CB-01`) |
| `ec_path` | string | Absolute ACPI namespace path to Embedded Controller (`\\_SB.PCI0.LPC0.EC0` or `\\_SB.PC00.LPCB.EC0`) |
| `ec_base` | string | Physical memory-mapped EC base address (optional) |
| `ec_size` | string | EC memory window size (optional) |
| `rpm_scale` | integer | Fan telemetry scaling factor (typically `100`) |
| `battery_conservation_mask` | integer | Bitmask for Conservation Mode in `GBMD`/`SBMC` |
| `battery_rapidcharge_mask` | integer | Bitmask for Rapid Charge in `GBMD`/`SBMC` |
| `native_telemetry` | array of objects | List of telemetry sensors (`field` and `scale`) |

## Header Generation

After editing or adding profiles, compile the kernel firmware lookup table:

```sh
python3 Scripts/generate_firmware_profiles.py
python3 Scripts/generate_firmware_profiles.py --check
```

## Automated Validation

Verify schema compliance across all profiles:

```sh
python3 Tests/test_profile_schemas.py
```

Display identity also accepts optional `pci_subsystem_ids` entries (`"17aa:1234"`, lowercase hexadecimal subsystem vendor/device pairs). Only add IDs verified for that model; shared USB/RGB controller IDs do not identify a laptop. Machine types and PCI subsystem IDs are used for display only and do not grant firmware control eligibility. Ambiguous matches fall back to `Lenovo Laptop`; absent Lenovo evidence falls back to `Unknown Laptop`.
