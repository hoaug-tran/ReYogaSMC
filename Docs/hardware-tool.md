# Hardware reports

The hardware tool collects firmware tables and device information on Windows, macOS and Linux. When a reviewed profile matches, it can also generate and compile an SSDT bridge. It does not install tables, edit EFI or enable controls for unknown firmware.

## Collect a report

Install Python 3.9 or newer and open a source checkout.

| Platform | Launcher | Input |
| --- | --- | --- |
| Windows | `ReYoga.cmd` | Live device inventory, reviewed getter probes and an EC snapshot when available |
| macOS | `ReYoga.command` | ACPI dump path, or leave it blank for a runtime report |
| Any supported platform | Command below | Directory of tables or one AML/DAT/DSL file |

```sh
python3 Scripts/hardware_support.py --acpi /path/to/tables --model My-Laptop
```

Choose a new output directory. An existing export is not overwritten. Unavailable collectors are recorded as errors so the remaining report can still be used.

## Options

| Option | Purpose |
| --- | --- |
| `--acpi PATH` | Read a table directory or one AML/DAT/DSL file |
| `--dsdt PATH` | Alias for one DSDT input |
| `--model LABEL` | Set the SSDT filename label, up to 32 characters |
| `--output PATH` | Use a new export directory |
| `--iasl PATH` | Use a specific compiler |
| `--offline` | Disable downloads |
| `--source-only` | Generate source without compiling |
| `--compile` | Set up the compiler for source input too |
| `--windows-live` | Collect reviewed Windows getter results and provider errors |
| `--windows-report PATH` | Include an existing Windows JSON report |
| `--ec-read` | Read the standard 256-byte EC space on Windows/Linux |

An installed `iasl` on PATH is used first. Otherwise:

- Windows downloads the pinned ACPICA executable.
- macOS downloads the pinned Acidanthera/MaciASL binary.
- Linux downloads ACPICA source and builds it with the system C compiler and `make`.

Downloads are checked against SHA-256 values in `Scripts/acpica.json`. The cache is `~/.cache/reyoga/acpica`. A corrupt cached executable is reported without replacement. Offline mode needs an installed or valid cached compiler. Compiler errors remain in the report.

## Exported files

The dated directory and ZIP contain:

| File | Contents |
| --- | --- |
| `report.json` | Device information, table hashes, collector results and errors |
| `device-support.md` | Summary for a device-support request |
| DSDT/SSDT files | Copies of accepted input tables and available disassembly |
| `SSDT-ReYoga-<model>.dsl` / `.aml` | Bridge source and compiled output, only when reviewed fingerprints and required fields match |
| `ec-*.bin` | Complete EC snapshots when requested and available |

The report lists declared methods, literal operation regions, field offsets and WMI GUID records. An offset in a declaration does not establish its units or whether it is safe to write. Dynamic fields, aliases and incomplete dumps need review.

Unrelated tables, including licensing tables, are excluded. Windows registry tables supplement the firmware API; repeated SSDTs are checked and deduplicated by content. Supply a complete dump when other tables are needed to resolve external references. On Linux, reading tables can require permission.

ThinkPad helper generation is provided by the [macOS app](../README.md#thinkpad-acpi-helpers). An unmatched IdeaPad/Legion bridge does not mean ThinkPad controls are unsupported.

## EC snapshots

`--ec-read` captures the standard EC space sequentially. It is not an atomic snapshot and does not cover extended MMIO or banked vendor registers.

### Linux

The tool opens `/sys/kernel/debug/ec/ec*/io` read-only. If missing, load `ec_sys` with `write_support=0`, mount debugfs and grant the required read permission.

### Windows

Install the signed [PawnIO driver](https://pawnio.eu/) separately and run with administrator access. The tool downloads a pinned [LpcACPIEC module](https://github.com/namazso/PawnIO.Modules/blob/main/LpcACPIEC.p) and checks its checksum. It requires a disassembled EC declaration using standard ports `0x62`/`0x66`, uses the shared `Global\Access_EC` mutex and sends only ACPI READ transactions.

The collector stops on timeout. It does not install drivers or change Windows security settings. Module source and LGPL-2.1-or-later license references are in `Scripts/pawnio.json`.

## Share a report

Read the export before attaching it to an issue. Firmware tables and inventory can contain device identifiers or local paths. Reports stay local until you share them.

Include the exact model, BIOS, OS, app/kext versions, requested action and observed result. Note any difference between AC/battery or before/after sleep. Stop repeating a command that caused shutdown or loss of cooling.

See [CONTRIBUTING.md](../CONTRIBUTING.md) for profile changes and firmware validation.
