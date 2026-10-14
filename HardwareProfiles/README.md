# Firmware profiles

Profiles describe reviewed firmware and device layouts. They do not make similarly named laptops interchangeable.

## ACPI profiles

| Field | Meaning |
| :--- | :--- |
| `id`, `name`, `kind` | Stable profile identity, display name and adapter family |
| `machine_type`, `bios_family` | Documented model and firmware scope |
| `reviewed_aml_hashes` | SHA-256 of complete, reviewed binary DSDTs |
| `reviewed_dsdt_hashes` | SHA-256 of reviewed source after the tool's normalization |
| `required_patterns` | Additional interface checks; patterns alone never authorize generation |
| `ec_path`, `ec_base`, `ec_size` | Reviewed namespace path and operation region |
| `offsets` | Adapter-specific field locations, with source evidence |
| `rpm_scale`, `curve_points_max` | Proven units and layout bounds |
| `verified_writes` | Zero until manual curve writes and restoration have been reviewed on hardware |
| `fan_command_method`, `fan_fullspeed_*` | Reviewed vendor full-speed method and arguments from the matched DSDT |
| `validation`, `sources` | What was checked, what remains unverified, and supporting references |
| `battery_conservation_mask`, `battery_rapidcharge_mask` | Reviewed GBMD state masks; distinct single bits supplied through the bridge |
| `fan_labels` | Optional physical fan labels; omit when the cooling identity is unknown |

A binary hash match still needs the required source interfaces. The app's live binary path uses the reviewed binary identity; the command-line tool disassembles tables for additional inspection. Include the BIOS version and original table fingerprint in the review evidence.

The supplied Legion profile's `verified_writes` is zero. The SSDT advertises that through `RYVW`, rejects manual fan-curve writes, and the kext separately rejects those commands. The app also requires the driver's `FanWritesValidated` property, so an older driver cannot silently make an unvalidated manual control available.

`RYFF` preserves the return value of the vendor full-speed command. It uses the same method and arguments as the firmware WMI dispatcher, with profile data supplying them. An EC error is exported separately from ACPI transport success and state readback. This path does not enable manual curve writes.

Lighting availability comes from each firmware `LENOVO_LIGHTING_DATA` record, including control interface and lighting type. A model name alone does not enable or disable lighting.

## USB and hotkey profiles

USB layouts must match VID, PID, usage page, report length and supported device layout. Document report IDs, instruction bytes, zone banks and LED indices. USB transport success does not confirm a visible color.

Hotkey mappings require a known matching profile, physical Fn identity where applicable, and repeat behavior. Ordinary media/function keys must remain usable when the mapper is off or permissions are denied.

## Adding a model

Attach the tool export to a device-support issue first. The report includes static fields and bit offsets, literal operation-region addresses, WMI GUIDs and Windows class/method metadata where available. These are declarations, not proof that writing a field is safe. Dynamic expressions, namespace aliases, banked/indexed fields and firmware-controlled units require manual review.

Do not add a write-enabled profile from a guessed register map. Follow CONTRIBUTING.md for the required hardware evidence and test matrix.
