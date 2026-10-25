# ReYoga hardware tool

The tool exports evidence for firmware support and compiles an SSDT when a reviewed profile matches. It does not install tables, edit EFI, write EC registers or invoke arbitrary WMI methods.

## Run the tool

Install Python 3.9 or newer and run from a source checkout. On Windows, open `ReYoga.cmd`; it requests reviewed live getter probes and an EC snapshot. An unavailable backend is recorded as a collection error. On macOS, open `ReYoga.command`; you can enter the path to an ACPI dump or leave it blank for a runtime report. Command-line use works on Windows, macOS and Linux:

```sh
python3 Scripts/hardware_support.py --acpi /path/to/tables --model My-Laptop
```

| Option | Behavior |
| :--- | :--- |
| `--acpi PATH` | Read a table directory or one AML/DAT/DSL file |
| `--dsdt PATH` | Alias for one DSDT input |
| `--model LABEL` | Set the generated SSDT filename label, limited to 32 characters |
| `--output PATH` | Choose a new export directory; existing files are preserved |
| `--iasl PATH` | Use your compiler |
| `--offline` | Disable downloads |
| `--source-only` | Export the reviewed SSDT without compiling it |
| `--windows-live` | Collect reviewed Windows getter results, including output parameters and provider errors |
| `--windows-report PATH` | Attach an existing Windows JSON report for offline review |
| `--ec-read` | Capture the standard 256-byte EC space on Windows/Linux |
| `--compile` | Request compiler setup for source input as well |

With no compiler on PATH, Windows downloads the pinned ACPICA iasl executable. On macOS/Linux, the tool downloads verified ACPICA source and builds it. Those hosts need system C build tools installed once. Cache location: `~/.cache/reyoga/acpica`. Source/compiler failures are recorded so the rest of the report can still be reviewed.

## Export contents

The dated directory and ZIP contain `report.json`, `device-support.md`, copied DSDT/SSDT input and available disassembly. Unrelated tables, including licensing tables, are excluded. When fingerprints and required bridge data match a reviewed profile, the export also includes `SSDT-ReYoga-<model>.dsl` and compiled AML. The tool never generates a control profile for unmatched firmware.

Windows inventory also preserves instance data and method parameter directions. Getter results include every returned output field, with failures recorded individually. The collector never invokes methods merely because they have no input parameters.

The report contains table hashes, checksum status, method declarations, literal operation regions, static field/bit offsets and decoded WMI GUID records. Windows adds model/BIOS, ACPI/USB devices and available WMI class qualifiers, method IDs and parameter metadata. macOS adds driver capabilities, sensor status, raw lighting/fan-boost states and the last correlated command result.

Literal field offsets identify declarations. They do not establish units, writable semantics or safe values. Dynamic expressions, aliases, banked/indexed fields and incomplete table dumps need review. Unknown firmware still gets an export, with generation marked unmatched.

Windows registry ACPI tables supplement the firmware API, including multiple SSDTs when present. Tables are checked for length and checksum and deduplicated by content. The firmware API cannot retrieve every repeated SSDT by signature. Supply a complete dump when companion SSDTs are required. On Linux, table access can require permission. On macOS, provide the dump or use the app's supported DSDT export.

ThinkPad does not need an IdeaPad/Legion bridge. An unmatched bridge result does not establish that ThinkPad hotkeys, battery thresholds or fan control are unsupported.

## Live EC values

Add `--ec-read` for a register snapshot. Linux reads `/sys/kernel/debug/ec/ec*/io` through `ec_sys`. If the interface is missing, load `ec_sys` with `write_support=0`, mount debugfs and run with read permission. The tool opens the interface read-only.

Windows requires the signed [PawnIO driver](https://pawnio.eu/) installed separately and administrator access. The tool downloads a pinned, checksum-verified [LpcACPIEC module](https://github.com/namazso/PawnIO.Modules/blob/main/LpcACPIEC.p) and uses the shared `Global\Access_EC` mutex. A disassembled EC declaration with standard ports 0x62/0x66 is required. It sends only ACPI READ transactions and stops after a timeout. Driver installation and Windows security settings are not changed.

`report.json` records the backend, timestamp, values and failures; complete snapshots also include `ec-*.bin`. These are sequential samples, not an atomic image. The standard space does not cover extended MMIO, indexed or banked vendor registers. A snapshot cannot establish which values safely control a feature. Compare exports from known operating states and review them with the ACPI declarations.

The downloaded module is LGPL-2.1-or-later; its source and license are linked in `Scripts/pawnio.json`. Windows/Linux live collection still needs validation on those operating systems.

## Sharing a report

Read the export before publishing it. Device IDs, local paths and firmware tables can contain identifying information. The tool keeps reports local; submitting an issue or PR is your choice.

Describe the exact model and BIOS, the feature, expected/actual behavior and AC/battery or sleep/wake differences. Do not repeat a command that caused shutdown. A maintainer must review field meaning and write safety before enabling a new control.

For profile review and code changes, see [contributing](../CONTRIBUTING.md).
