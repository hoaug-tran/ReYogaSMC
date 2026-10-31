# Hardware profiles

Profiles describe model-specific ACPI sensors and USB RGB layouts. ThinkPad HKEY controls and generic IdeaPad/Yoga ACPI features do not need a profile from this directory.

A model-name match does not grant write access. Current ACPI profiles leave raw manual fan writes disabled. See [compatibility](../Docs/compatibility.md) for runtime requirements and [CONTRIBUTING.md](../CONTRIBUTING.md#change-device-support) for validation steps.

## ACPI models

The table lists profile identity data, not a guarantee for every BIOS revision. Open a JSON file for its firmware references and fields.

| Profile | Model | Machine types | BIOS families |
| --- | --- | --- | --- |
| [ideapad-gaming3-gen5](ideapad-gaming3-gen5.json) | Lenovo IdeaPad Gaming 3 15ARH05 | 82EY | FCCN |
| [ideapad-gaming3-gen6](ideapad-gaming3-gen6.json) | Lenovo IdeaPad Gaming 3 15ACH6 | 82K2, 82K1 | H3CN |
| [legion-pro5-gen8-arh](legion-pro5-gen8-arh.json) | Lenovo Legion Pro 5 16ARX8 | 82WM | LPCN |
| [legion-pro5-gen8-irx](legion-pro5-gen8-irx.json) | Lenovo Legion Pro 5 16IRX8 | 82WK, 82WL | KWCN |
| [legion-pro5-gen9-irx](legion-pro5-gen9-irx.json) | Lenovo Legion Pro 5 16IRX9 | 83DF | N2CN |
| [legion-pro7-gen8-irx](legion-pro7-gen8-irx.json) | Lenovo Legion Pro 7 16IRX8H | 82WQ, 82WR | KWCN |
| [legion-pro7-gen9-irx](legion-pro7-gen9-irx.json) | Lenovo Legion Pro 7 16IRX9 | 83FD | NSCN |
| [legion5-gen5-ach](legion5-gen5-ach.json) | Lenovo Legion 5 15ARH05 | 82B5, 82B1, 82GN | EUCN, FSCN |
| [legion5-gen5-imh](legion5-gen5-imh.json) | Lenovo Legion 5 15IMH05 | 81Y6, 82AU, 82B3, 81Y8 | EFCN, E9CN |
| [legion5-gen6-ach](legion5-gen6-ach.json) | Lenovo Legion 5 15ACH6 | 82JW, 82JU, 82NW | GKCN, HHCN |
| [legion5-gen7-arh](legion5-gen7-arh.json) | Lenovo Legion 5 15ARH7 | 82RE, 82RD | JUCN, K9CN |
| [legion5pro-gen6-ach](legion5pro-gen6-ach.json) | Lenovo Legion 5 Pro 16ACH6H | 82JQ, 82JS | GKCN |
| [legion5pro-gen7-iah](legion5pro-gen7-iah.json) | Lenovo Legion 5 Pro 16IAH7H | 82RF, 82RG | J2CN, KFCN |
| [legion7-16achg6-gkcn](legion7-16achg6.json) | Lenovo Legion 7 2021 16ACHg6 | 82N6 | GKCN |
| [legion7-gen5-imh](legion7-gen5-imh.json) | Lenovo Legion 7 15IMH05 | 81YT, 81YU | E9CN |
| [legion7-gen6-ith](legion7-gen6-ith.json) | Lenovo Legion 7 16ITHg6 | 82K6 | H1CN |
| [legion7-gen7-arh](legion7-gen7-arh.json) | Lenovo Legion 7 16ARHA7 | 82UH | K9CN |
| [loq-gen8-aph](loq-gen8-aph.json) | Lenovo LOQ 15APH8 | 82XT | LYCN |
| [loq-gen8-irh](loq-gen8-irh.json) | Lenovo LOQ 15IRH8 | 82XV, 82XW, 82XU | LZCN |
| [loq-gen9-ahp](loq-gen9-ahp.json) | Lenovo LOQ 15AHP9 | 83DX | NZCN |
| [yoga-slim7-gen5](yoga-slim7-gen5.json) | Lenovo Yoga Slim 7 14ARE05 | 82A2, 82A8 | DMCN, EMCN |

## Fields

All profiles use `schema_version: 1`, a unique `id`, a display `name`, a `kind` and source URLs.

| Field | Meaning |
| --- | --- |
| `kind` | `acpi` for firmware sensors; `rgb` for USB lighting |
| `machine_types` | Four-character Lenovo machine types |
| `bios_families` | Expected BIOS prefixes |
| `oem_table_ids` | Expected DSDT OEM table IDs |
| `pci_subsystem_ids` | Optional model-specific Lenovo subsystem IDs, in `17aa:xxxx` form |
| `ec_path` | Absolute ACPI path to the embedded controller |
| `native_telemetry` | Named sensor fields and their scales |
| `rpm_scale` | Fan reading multiplier: 1 or 100 |
| `reviewed_dsdt_hashes`, `reviewed_aml_hashes` | Optional legacy fingerprints; active profiles match via hardware identity without hashes |
| `required_patterns`, `offsets` | Required declarations and addresses for a raw-offset bridge |
| `ec_base`, `ec_size` | Memory-mapped EC window, where used |
| `verified_writes` | Write-validation flag; keep 0 until target writes and recovery are confirmed |

Native named-field sensors and bridges match via hardware identity (machine type, BIOS family, OEM table ID and PCI subsystem ID) without firmware hashes. A model match does not enable raw-offset writes; manual fan writes remain disabled.

Machine types and PCI IDs must not name different models. Shared USB controller IDs do not identify a laptop. Unknown or conflicting identities keep model-specific access unavailable.

## USB RGB

The [ITE c968 Gen 6 profile](ite-c968-gen6.json) describes HID matching, report sizes, zones, effects and LED IDs. Matching uses VID `0x048D`, PID `0xC968`, usage page `0xFF89`, usage `0x07` and a 192-byte feature report, together with the required interface pair.

Numeric LED IDs are stable. Existing name aliases remain accepted by color imports. Reviewed keyboard mappings use the `hotkeys` section in the relevant laptop profile.

## Model-name catalog

[catalogs/models.json](catalogs/models.json) maps machine types and PCI subsystem IDs to names. It is used for display identity. Adding a name does not add a firmware backend or enable a control.

## Generate and check

After editing an ACPI profile:

```sh
python3 Scripts/generate_firmware_profiles.py
python3 Scripts/generate_firmware_profiles.py --check
python3 -B -m unittest Tests.test_profile_schemas Tests.test_firmware_profiles Tests.test_firmware_identity
```

The generator updates `ReYogaSMC/ReYogaFirmwareProfiles.hpp`. Edit the JSON source, not the header. Tests reject duplicate identities, conflicting model names, invalid fingerprints and unsupported sensor scales.
