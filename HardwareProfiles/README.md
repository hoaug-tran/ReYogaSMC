# Hardware profiles

Profiles describe firmware or a shared device protocol. Matching a product name does not establish a compatible EC layout.

## Common metadata

Every profile uses `schema_version: 1` and the following fields, in order:

| Field | Meaning |
| :--- | :--- |
| `schema_version` | File format version |
| `kind` | `acpi` for firmware or `rgb` for a USB lighting adapter |
| `id` | Stable identifier used by the app and saved settings |
| `name` | Display name |
| `sources` | References for the protocol, field layout and units |

Adapter-specific fields retain the names expected by their readers. Do not change an existing ID when reorganizing a file.

## Firmware

An ACPI profile includes `machine_type`, `bios_family`, `reviewed_aml_hashes`, `reviewed_dsdt_hashes` and `required_patterns`. Binary hashes cover the complete DSDT; source hashes use the collection tool's normalization. Patterns alone do not authorize a match.

`ec_path`, `ec_base`, `ec_size` and `offsets` describe the reviewed namespace and operation region. Battery masks, commands and capability bits are recorded separately. `verified_writes` stays zero until write/readback and restoration have been checked on the target firmware.

Optional `hotkeys` belong to the firmware profile. The nested mapping keeps its own stable `id`, keycodes, consumer usages and `matchProfiles`. That list may include a shared RGB adapter ID, so keyboard discovery does not require an ACPI bridge. Unknown IDs do not inherit the mapping.

## RGB adapters

USB profiles contain VID/PID, usage page, report size, command values and bank/LED maps. Keep shared controllers such as ITE c968 separate from a machine's firmware profile. Do not duplicate their wire protocol across model files.

## Native telemetry

`native_telemetry` lists four existing fields in order: fan 1, fan 2, CPU temperature, GPU temperature. Each entry contains `field` and an integer `scale` converting it into RPM or Celsius. The generator combines each name with the profile's absolute `ec_path`.

After reviewing the complete binary DSDT and field units, add its SHA-256 to `reviewed_aml_hashes` and run:

```sh
python3 Scripts/generate_firmware_profiles.py
python3 Scripts/generate_firmware_profiles.py --check
```

Commit the generated `ReYogaSMC/ReYogaFirmwareProfiles.hpp`; Xcode requires no Python generation step. The kext checks the DSDT signature, length, checksum, SHA-256 and declared fields before reading them. These descriptors do not authorize physical-memory access or register writes.

The Legion 7 profile reads FANS/FA2S at 100 RPM per unit and CPUT/GPUT in Celsius. A firmware update or bootloader patch that changes the DSDT requires a new review.
