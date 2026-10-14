<div align="center">

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="Assets/Brand/readme-dark.svg">
  <img src="Assets/Brand/readme-light.svg" alt="ReYogaSMC. Your hardware. Your controls." width="900">
</picture>

# ReYogaSMC

**Lenovo hardware controls, with firmware-aware support.**

A community macOS driver, menu bar app and ACPI support tool.

[Getting started](#getting-started) · [Hardware support](#hardware-support) · [Device reports](#device-reports) · [Contributing](CONTRIBUTING.md)

</div>

## What this project does

ReYogaSMC connects supported laptop firmware to macOS. The kext handles ACPI, WMI, hardware events and VirtualSMC sensors. The companion app shows what the loaded driver can actually use, with a reason when a feature is unavailable.

This is a fork of [YogaSMC by Zhen](https://github.com/zhen-zen/YogaSMC), maintained by Tran Kinh Hoang. The original authorship, source notices and GPL license remain part of the project. ReYogaSMC continues that work with firmware profiles, correlated control results and a device-report workflow.

## Hardware support

| Family / interface | Driver path | What to expect |
| :--- | :--- | :--- |
| Lenovo ThinkPad | ThinkVPC / ThinkSMC | Firmware events, supported battery and keyboard controls, configured EC sensors |
| Lenovo IdeaPad / Yoga | IdeaVPC / IdeaSMC | Battery conservation, rapid charge, keyboard and USB controls when advertised by ACPI |
| Lenovo Legion Game Zone | IdeaVPC / IdeaWMI | Firmware power modes, available temperatures, fan telemetry and model-dependent controls |
| Legion 7 16ACHg6, GKCN | Reviewed ACPI identity | Sensor bridge; manual fan control unavailable |
| ITE c968 USB RGB | Profile-backed HID adapter | Keyboard and lighting zones for the matching device/layout; transport acknowledgement only |
| Generic Intel HID / HP | YogaHIDD / DYVPC | Experimental; requires compatible firmware and a vanilla EC |
| Unknown firmware | ReYoga support tool | Export evidence for review; no guessed EC addresses or generated control profile |

| Feature | Source | How support is established |
| :--- | :--- | :--- |
| Battery conservation / rapid charge | ACPI | Methods, capability flags and state readback |
| Power mode / display overdrive / touchpad | WMI | Capability query and getter |
| Maximum fan speed | WMI fan interface | Command acceptance followed by state readback; physical cooling needs validation |
| Fan RPM / temperatures | WMI, reviewed ACPI or AppleSMC | Source and sample validity are reported separately |
| CPU power limits | WMI | Firmware-provided range and step; edits save the previous values for reset |
| Logo / rear port lighting | WMI or USB HID | Firmware readback or a USB transport result; physical light output is not measured |
| Fn hotkeys | Firmware events / reviewed mappings | Native firmware events where possible; app mappings require macOS privacy permission |

Model data belongs in [HardwareProfiles](HardwareProfiles). Protocol constants stay in the adapters. Similar product names do not establish compatible registers, payloads or field units.

## Getting started

1. Build the project or use an appropriate published package.
2. Load Lilu and VirtualSMC before `ReYogaSMC.kext` in OpenCore. Use current compatible dependencies.
3. Replace any older YogaSMC/ReYogaSMC kext. Update `BundlePath` and `ExecutablePath` for the new product name. Load only one primary or Alter variant.
4. Install `ReYogaSMCNC.app` in `/Applications` and open it. Check the driver connection and feature status before changing settings.
5. Add an optional SSDT only when its firmware profile matches your machine. Keep a bootable recovery configuration before changing EFI.

The original bundle IDs and IOService class names are retained for existing driver clients, preferences and privacy identity. Source names and runtime modules still include upstream identifiers for compatibility. Public products and the Xcode project use ReYoga names.

### Packages

| Product | Purpose |
| :--- | :--- |
| `ReYogaSMC.kext` | Main driver with VirtualSMC integration; requires Lilu and VirtualSMC |
| `ReYogaSMCAlter.kext` | Diagnostic variant without SMC keys or those two dependencies; load separately |
| `ReYogaSMCNC.app` | Menu bar controls, hardware status, hotkeys and diagnostic export |
| `ReYogaSMCNCHelper.app` | Embedded login helper |
| `Scripts/hardware_support.py` | Local ACPI discovery, reviewed bridge generation and report export |

## Device reports

Use Python 3.9 or newer. No third-party Python packages are required. Double-click `ReYoga.cmd` on Windows or `ReYoga.command` on macOS to start with the default options. Each run gets a dated export directory.

```sh
# Windows: tables, inventory and reviewed getter probes.
python Scripts/hardware_support.py --windows-live --ec-read

# Any supported host: supply the complete ACPI dump, including companion SSDTs.
python3 Scripts/hardware_support.py --acpi /path/to/tables --compile

# Optional model label and export destination.
python3 Scripts/hardware_support.py --dsdt DSDT.dsl --model Legion-7 --output ReYoga-my-device
```

The tool exports `report.json`, a device-support issue draft, copied/disassembled tables and a ZIP. Matching firmware gets a short `SSDT-ReYoga-<model>.dsl` name. A matched bridge is compiled automatically; `--source-only` exports just its source. Output goes into a new directory so an earlier report cannot be overwritten.

When needed, Windows downloads a pinned iasl binary. macOS and Linux download verified ACPICA source and build iasl using the system C tools. Downloads have SHA-256 checks and are cached outside the repository. Use `--iasl /path/to/iasl` for an existing compiler or `--offline` to disable downloads. Build and disassembly failures remain in the report.

On Windows, registry tables supplement the firmware API and preserve multiple SSDTs when available. The API itself exposes only the first repeated signature. For complete cross-table resolution, supply a full firmware dump. Linux can read tables from `/sys/firmware/acpi/tables` when permitted. On macOS, supply a dump or use the app's live DSDT export where the driver supports it.

> [!NOTE]
> ACPI alone cannot reveal every EC register's meaning, WMI payload or USB lighting protocol. The report distinguishes collected declarations from interfaces that still need review. Discovery does not scan physical memory, write EC registers or call arbitrary firmware methods.

Add `--ec-read` on Windows/Linux to include a live standard EC snapshot. Windows uses PawnIO; Linux uses `ec_sys`.

See the [tool reference](Docs/hardware-tool.md) for export contents and options.

For a new model, open a device-support issue with the report and observed behavior. A profile PR also needs evidence for addresses, units, ranges and firmware identity. See [Contributing](CONTRIBUTING.md). Review the export before publishing it: firmware tables and Windows device IDs may contain identifying information.

## Saved preferences

Color pickers, effect selection, numeric drafts and navigation survive closing the popover or changing tabs. Clicking Apply saves the successfully applied RGB configuration, including per-key imports, under the matching device profile. The app restores it after relaunch or rediscovery. Closing the app releases software RGB control; it does not erase the saved configuration.

Confirmed firmware settings are saved separately and restored after a compatible driver connects. Capability checks and current power ranges still apply. CPU/fan edits belong to the power profile where they were set. Reset Changes removes saved CPU edits; Restore Auto removes saved fan overrides.

Permissions, login registration and update preferences use macOS and persistent preferences. No setting needs a popover to stay focused in order to be saved.

## Diagnostics and recovery

The app records correlated requests, transport status, firmware command status, requested/actual values, capabilities and sensor sources. Logs rotate under `~/Library/Logs/ReYogaSMC`. Settings provides local report export and opens the issue draft for you to review. Nothing is submitted automatically.

A command acknowledgement means the firmware accepted the call. The app reports confirmation only when its readable state matches. A mismatch should include the feature, firmware version, requested state, readback and reproduction steps. USB RGB has no color readback, so its result is explicitly a transport acknowledgement.

For kernel output:

```sh
log stream --predicate 'senderImagePath contains "ReYogaSMC"'
swift Scripts/diagnose.swift
```

The second command refreshes and samples driver properties without changing feature settings. Enable detailed telemetry only while reproducing a problem. Attach relevant logs rather than an entire unrelated system log.

### Privacy permissions

Hotkey mapping needs Accessibility and Input Monitoring. Normal sensor display does not need an event tap. Grant permission to the installed app, then retry discovery or mapping.

macOS tracks privacy access using the app's signing identity. Unsigned builds, incompatible signing requirements, or changing installed copies can cause repeated prompts. Keep the app in one installation path and sign subsequent builds with the same identity. See [Apple's signing requirements](https://developer.apple.com/documentation/technotes/tn3127-inside-code-signing-requirements). The app exports its signing details for diagnosis; it cannot grant itself macOS permissions.

## macOS compatibility

The minimum deployment target is macOS 11. The app uses availability checks for newer services. There is no upper-version block for macOS 26.

| Version | Status / checks needed |
| :--- | :--- |
| 11–12 | Deployment baseline; verify permission handling, login helper, UI and sleep/wake on hardware |
| 13–15 | Verify login service registration, permission persistence |
| 26 | Runtime testing required with its SDK, System Settings and kext-loading environment |

Compilation is not runtime certification. This repository does not claim that every machine and macOS version has been tested. Each profile contribution should state the versions actually booted, including AC/battery and sleep/wake behavior.

## Building

Install Xcode command-line tools and select the intended Xcode installation. Dependency versions and checksums live in `Scripts/dependencies.json`.

```sh
bash Scripts/bootstrap.sh
xcodebuild -project ReYogaSMC.xcodeproj -target BuildAll -configuration Debug CODE_SIGNING_ALLOWED=NO
xcodebuild -project ReYogaSMC.xcodeproj -target BuildAll -configuration Release CODE_SIGNING_ALLOWED=NO
```

Unsigned output is for local development. For a persistent installed app, use your signing identity:

```sh
bash Scripts/sign-app.sh 'Developer ID Application: your name (TEAM)' build/Release
bash Scripts/package.sh Release
```

Keep the same identity for updates. Signing does not notarize the app. CI prepares unsigned packages and draft releases so distribution status can be checked before publication. [Compatibility and release checks](Docs/compatibility.md) describes the hardware validation expected before release.

## Credits and license

ReYogaSMC retains the [GPL v2 license](LICENSE) and original copyright notices. A rename does not remove upstream authorship.

* [Zhen and YogaSMC contributors](https://github.com/zhen-zen/YogaSMC) for the original driver and companion apps.
* [Apple](https://www.apple.com) for macOS and its development tools.
* Linux contributors for [ideapad-laptop](https://github.com/torvalds/linux/blob/master/drivers/platform/x86/lenovo/ideapad-laptop.c) and [thinkpad-acpi](https://github.com/torvalds/linux/blob/master/drivers/platform/x86/lenovo/thinkpad_acpi.c).
* [RehabMan](https://github.com/RehabMan) for VoodooPS2Controller, ACPI Debug, ioio and DSDT work.
* [vit9696 and Acidanthera](https://github.com/acidanthera/VirtualSMC) for VirtualSMC, Lilu and MacKernelSDK.
* [the-darkvoid](https://github.com/the-darkvoid) for macOS-IOElectrify; [pali](https://github.com/pali) for bmfdec.
* [LenovoLegionLinux](https://github.com/johnfanv2/LenovoLegionLinux) for published Legion EC research.
* [OpenRGB](https://gitlab.com/CalcProgrammer1/OpenRGB) and its Lenovo USB controller contributors for protocol research. Adapter attribution is retained in source.
* [ACPICA](https://github.com/open-acpica/acpica) for iasl. Downloaded tools retain their upstream licensing.
* benbender, 1Revenger1 and everyone contributing hardware reports and fixes.
