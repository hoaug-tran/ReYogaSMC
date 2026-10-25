<div align="center">

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="Assets/Brand/readme-dark.svg">
  <img src="Assets/Brand/readme-light.svg" alt="ReYogaSMC" width="720">
</picture>

[![Build](https://github.com/hoaug-tran/ReYogaSMC/actions/workflows/main.yml/badge.svg?branch=main)](https://github.com/hoaug-tran/ReYogaSMC/actions/workflows/main.yml)
[![Release](https://img.shields.io/github/v/release/hoaug-tran/ReYogaSMC)](https://github.com/hoaug-tran/ReYogaSMC/releases/latest)
[![License](https://img.shields.io/badge/license-GPL--2.0-blue)](LICENSE)

Kernel extension (`ReYogaSMC.kext`), macOS control workspace (`ReYogaSMC.app`), and ACPI/EC diagnostic toolkit for Lenovo ThinkPad, IdeaPad, Yoga, LOQ, and Legion laptops running macOS.  
Forked from [YogaSMC 1.5.3](https://github.com/zhen-zen/YogaSMC).

[Releases](https://github.com/hoaug-tran/ReYogaSMC/releases/latest) · [CI Artifacts](https://github.com/hoaug-tran/ReYogaSMC/actions/workflows/main.yml) · [Hardware Profiles](HardwareProfiles) · [Compatibility](Docs/compatibility.md) · [Hardware Tool](Docs/hardware-tool.md)

</div>

---

## Overview

ReYogaSMC bridges Lenovo ACPI Virtual Power Controller (`VPC0`), ThinkPad `HKEY`, Lenovo WMI (`PNP0C14`), `AppleSmartBattery`, `AppleSMC`, and ITE USB HID controllers into a unified kernel and userspace stack. Every control request is serialized through the driver's `IOCommandGate`, checked against hardware capability flags, and verified by readback before updating state.

<p align="center">
  <img src="Assets/Screenshots/overview.png" alt="ReYogaSMC Overview Workspace" width="860">
</p>

---

## Supported Interfaces & Capabilities

Controls and sensors are enabled per-feature based on the interfaces exposed by the machine's ACPI tables, WMI GUIDs, and USB bus:

| Subsystem | Kernel / Userspace Provider | Supported Capabilities |
| :--- | :--- | :--- |
| **IdeaPad / Yoga / Legion / LOQ ACPI** | `IdeaVPC` (`VPC0`) | Battery Conservation mode (`GBMD`/`SBMC`), Rapid Charge, keyboard backlight (`HALS`/`SLBL`), Fn Lock, Always-On USB, native ACPI EC telemetry (`FANS`, `FA2S`, `CPUT`, `GPUT`), and reviewed `RYID` ACPI bridge support |
| **Lenovo Game Zone WMI** | `IdeaWMIGameZone` (`887B54E3-DDDC-4B2C-8B88-68A26A8835D0`) | SmartFan thermal profiles (`Quiet`, `Balanced`, `Performance`), `Fn+Q` full-speed cooling, opt-in CPU Boost & Sustained power limits (`-reycpupower`), Display Overdrive, Touchpad Lock, Win Key Lock, Y-Logo LED, Rear Port Lighting, and WMI sensor fallback |
| **ThinkPad ACPI** | `ThinkVPC` (`LEN0068` / `LEN0268` `HKEY`) | Fn hotkeys, Fn Lock, keyboard backlight, battery charge start/stop thresholds (`BCTG`/`BCCS`/`BCSG`/`BCSS`), inhibit charge, force discharge, DYTC thermal profiles, mute/mic-mute LED sync, and serialized dual-fan EC control (`kRYSMCUCThinkFan`) |
| **Intel HID / HP WMI** | `ReYogaHIDD` (`INT33D5`), `DYVPC` | HID DSM Fn event routing, Yoga mode notifications, and HP WMI thermal/event sensors |
| **Smart Battery (Userspace)** | `AppleSmartBattery` (`IORegistry`) | Live state of charge, charging state, current/full-charge/design capacity (mAh), design retention percentage, cycle count, voltage (V), signed current (mA), power draw (W), temperature (°C), and AC adapter watt rating |
| **SMC Sensors (Userspace)** | `AppleSMC` (`IOServiceOpen`) | Direct read-only queries for CPU (`TC0E`, `TC0P`, `TC0D`, `TC0F`, `TC0C`, `TC1C`, `TCSA`) and GPU (`TG0D`, `TG0P`, `TG0E`) temperature keys |
| **ITE `c968` USB RGB (Userspace)** | `IOHIDManager` (`0x048d:0xc955/0xc965/0xc967/0xc975/0xc985`) | Hardware effect presets, speed, 2-step brightness, 4-zone static RGB color picker, and per-key RGB JSON profile import |

> [!NOTE]
> `AppleSmartBattery`, `AppleSMC` temperature sensors, and ITE `c968` USB RGB lighting operate independently in userspace. They remain functional even if `ReYogaSMC.kext` is not loaded, is running in `-reysafe` mode, or does not match a Lenovo VPC device.

---

## Temperature Sensors & Required SMC Kexts

ReYogaSMC aggregates thermal telemetry from both Lenovo firmware (native ACPI EC fields or Game Zone WMI) and VirtualSMC sensor plugins. When firmware EC temperature registers are absent, unpopulated, or report `0`, the app reads directly from `AppleSMC`.

| Target Sensor | Required Kext / Source | SMC Keys / Firmware Objects | Notes |
| :--- | :--- | :--- | :--- |
| **AMD Ryzen CPU** | [**SMCProcessorAMD.kext**](https://github.com/trulyspinach/SMCAMDProcessor) | `TC0E`, `TC0P`, `TC0D`, `TC0F` | Required on AMD Ryzen laptops when ACPI EC `CPUT` or WMI CPU temperature is unavailable |
| **Intel CPU** | [**SMCProcessor.kext**](https://github.com/acidanthera/VirtualSMC) | `TC0P`, `TC0D`, `TC0C`, `TC1C`, `TCSA` | Bundled with VirtualSMC release packages |
| **AMD Radeon iGPU / dGPU** | [**SMCRadeonSensors.kext**](https://github.com/ChefKissInc/SMCRadeonSensors) | `TG0D`, `TG0P`, `TG0E` | Required for AMD Radeon integrated and discrete GPU diode temperatures via `AppleSMC` |
| **NVIDIA dGPU** | Firmware EC (`GPUT`) / WMI only | `GPUT` | **Not supported when dGPU is disabled or using `NullNVSMCDriver`** (see warning below) |

> [!WARNING]
> **NVIDIA Discrete GPU Temperature Limitation:**  
> macOS does not have an active driver for modern NVIDIA Turing/Ampere/Ada laptop dGPUs. When the NVIDIA dGPU is disabled via ACPI (`_OFF`), boot arguments (`-wegnoegpu`), or masked with a dummy kext such as **`NullNVSMCDriver`**, the GPU is powered down or uninitialized. In this state, `AppleSMC` exposes no valid NVIDIA temperature sensor, and the embedded controller's `GPUT` register returns `0 °C` (which ReYogaSMC rejects as an inactive sensor rather than displaying a fake reading).

---

## Hardware Profiles & Firmware Identity Verification

Native ACPI telemetry in `IdeaVPC` does not guess EC register offsets or trust OEM table IDs alone. At boot, `ReYogaFirmware::select` (`ReYogaSMC/FirmwareIdentity.hpp`) validates:

1. **DSDT Integrity:** Table signature (`DSDT`), byte length (`36 .. 1048576` bytes), 8-bit ACPI checksum (`0x00`), and `LENOVO` OEM ID.
2. **OEM Table ID:** Exact match against the profile's `oem_table_ids` (for example `CB-01`).
3. **Machine Type & BIOS Family:** Cross-checked across `/`, `/efi/platform`, `IOPlatformExpertDevice`, `/options` NVRAM (`OEMProduct`, `OEMBoard`, `OEMBIOSVersion`), and raw `AppleSMBIOS` Type 0 / Type 1 strings, plus Lenovo PCI subsystem IDs (`17aa:xxxx`).
4. **Conflict & Ambiguity Rejection:** If multiple identity sources disagree (`MatchState::conflict`) or more than one distinct hardware profile matches (`MatchState::ambiguous`), model-specific EC access is disabled and generic ACPI/WMI interfaces remain active.

### Included Hardware Profiles (`HardwareProfiles/`)

| Profile ID | Model Name | Machine Types | BIOS Families | EC Path |
| :--- | :--- | :--- | :--- | :--- |
| `ideapad_gaming_3_15arh05` | IdeaPad Gaming 3 15ARH05 | `82EY` | `FCCN` | `\_SB.PCI0.LPC0.EC0` |
| `ideapad_gaming_3_15ach6` | IdeaPad Gaming 3 15ACH6 | `82K2`, `82MJ` | `H3CN` | `\_SB.PCI0.LPC0.EC0` |
| `legion_5_15arh05` | Legion 5 15ARH05 / 15ARH05H / R7000P2020H | `82B5`, `82B1`, `82GN` | `EUCN`, `FSCN` | `\_SB.PCI0.LPC0.EC0` |
| `legion_5_15imh05` | Legion 5 15IMH05 / 15IMH05H / 17IMH05H | `82AU`, `81Y6`, `81Y8` | `EFCN` | `\_SB.PCI0.LPCB.EC0` |
| `legion_5_15ach6` | Legion 5 15ACH6 / 15ACH6A / 15ACH6H / 17ACH6H | `82JW`, `82NW`, `82JU`, `82K0` | `HHCN`, `GKCN` | `\_SB.PCI0.LPC0.EC0` |
| `legion_5_15arh7` | Legion 5 15ARH7 / 15ARH7H | `82RE`, `82RD` | `JUCN` | `\_SB.PCI0.LPC0.EC0` |
| `legion_5_pro_16ach6h` | Legion 5 Pro 16ACH6H / R9000P2021H | `82JQ`, `82GR` | `GKCN` | `\_SB.PCI0.LPC0.EC0` |
| `legion_5_pro_16iah7h` | Legion 5 Pro 16IAH7H / 5 15IAH7H | `82RF`, `82RB` | `K1CN` | `\_SB.PC00.LPCB.EC0` |
| `legion_7_15imh05` | Legion 7 15IMH05 / S7 15IMH5 | `81YT`, `82BC` | `E9CN`, `F5CN` | `\_SB.PCI0.LPCB.EC0` |
| `legion_7_16achg6` | Legion 7 16ACHg6 / R9000K2021H (`17aa:3801`/`3802`/`3803`/`381b`) | `82N6`, `82K6` | `GKCN` | `\_SB.PCI0.LPC0.EC0` |
| `legion_7_16ithg6` | Legion 7 16ITHg6 / S7 16IAH7 | `82K8`, `82TF` | `H1CN`, `JYCN` | `\_SB.PC00.LPCB.EC0` |
| `legion_7_16arha7` | Legion 7 16ARHA7 / Slim 7 16ARHA7 | `82UH`, `82UG` | `K9CN` | `\_SB.PCI0.LPC0.EC0` |
| `legion_pro_5_16arx8` | Legion Pro 5 16ARX8 / Pro 7 16ARX8H | `82WM`, `82WS` | `LPCN` | `\_SB.PCI0.LPC0.EC0` |
| `legion_pro_5_16irx8` | Legion Pro 5 16IRX8 / Slim 5 16IRH8 | `82WK`, `82YA` | `KWCN`, `M2CN` | `\_SB.PC00.LPCB.EC0` |
| `legion_pro_5_16irx9` | Legion Pro 5 16IRX9 / Legion 7 16IRX9 | `83DF`, `83FD` | `N0CN`, `N9CN` | `\_SB.PC00.LPCB.EC0` |
| `legion_pro_7_16irx8h` | Legion Pro 7 16IRX8H | `82WQ` | `KWCN` | `\_SB.PC00.LPCB.EC0` |
| `legion_pro_7_16irx9h` | Legion Pro 7 16IRX9H | `83DE` | `N2CN` | `\_SB.PC00.LPCB.EC0` |
| `loq_15aph8` | LOQ 15APH8 / Legion Slim 5 16APH8 | `82XT`, `82Y9` | `LYCN`, `M3CN` | `\_SB.PCI0.LPC0.EC0` |
| `loq_15irh8` | LOQ 15IRH8 / 16IRH8 | `82XV`, `82XW` | `LZCN` | `\_SB.PC00.LPCB.EC0` |
| `loq_15ahp9` | LOQ 15AHP9 / Legion Slim 5 16AHP9 | `83DX`, `83DH` | `NZCN`, `NRCN` | `\_SB.PCI0.LPC0.EC0` |
| `yoga_slim_7_14are05` | Yoga Slim 7 14ARE05 / IdeaPad 5 15ARE05 | `82A2`, `81YQ` | `DMCN`, `E7CN` | `\_SB.PCI0.LPC0.EC0` |

> [!IMPORTANT]
> Identifying a model enables validated read-only ACPI sensor polling (`FANS`, `FA2S`, `CPUT`, `GPUT`) with automatic per-sensor fallback to WMI if an ACPI field returns out-of-range data. Model identification **never** authorizes raw EC writes.

---

## Application Workspace (`ReYogaSMC.app`)

`ReYogaSMC.app` provides a 6-section hardware workspace and menu bar monitor localized in **English** and **Vietnamese** (`en.lproj` / `vi.lproj`).

| Device Controls | Cooling & Power |
| :---: | :---: |
| <img src="Assets/Screenshots/device.png" alt="Device Controls" width="420"> | <img src="Assets/Screenshots/cooling.png" alt="Cooling and Power" width="420"> |
| **Battery Health & Electrical Telemetry** | **Lighting & 4-Zone / Per-Key USB RGB** |
| <img src="Assets/Screenshots/battery.png" alt="Battery Telemetry" width="420"> | <img src="Assets/Screenshots/lighting.png" alt="Lighting Controls" width="420"> |
| **Diagnostics & Telemetry Sources** | **Settings & Startup Integration** |
| <img src="Assets/Screenshots/diagnostics.png" alt="Diagnostics" width="420"> | <img src="Assets/Screenshots/settings.png" alt="Settings" width="420"> |

- **Overview:** Live CPU/GPU temperatures, fan RPM gauges, battery charge ring, active thermal profile switcher (`Quiet`, `Balanced`, `Performance`), and hardware quick actions.
- **Device:** Battery Conservation Mode (~55–60% cap), Rapid Charge, Display Overdrive, Touchpad Lock, Win Key Lock, Fn Lock, Always-On USB, and hotkey permission status.
- **Cooling:** Thermal mode switching, `Fn+Q` full-speed cooling toggle, manual fan minimum RPM (when a validated v2 ACPI bridge is active), and opt-in WMI CPU Boost / Sustained power limits.
- **Battery:** Live `AppleSmartBattery` capacity retention, cycle count, mAh breakdown (current / full-charge / design), voltage, signed amperage, wattage, temperature, and adapter rating.
- **Lighting:** Keyboard backlight levels, Y-Logo LED, Rear Port Lighting, and direct USB HID RGB control for supported ITE `c968` controllers.
- **Diagnostics:** Firmware profile match stage, DSDT SHA-256 & OEM Table ID, Machine Type & BIOS Family, active sensor sources (`Native ACPI`, `WMI`, `SMCProcessorAMD`, `SMCRadeonSensors`), per-feature capability audit, and one-click local diagnostic ZIP export.

---

## Installation

### 1. Download Release Packages

Download the latest archives from [GitHub Releases](https://github.com/hoaug-tran/ReYogaSMC/releases/latest) (or from a completed [GitHub Actions](https://github.com/hoaug-tran/ReYogaSMC/actions/workflows/main.yml) run):

| Archive | Contents | Purpose |
| :--- | :--- | :--- |
| `ReYogaSMC-<version>-RELEASE.zip` | `ReYogaSMC.kext` | Production kernel extension for OpenCore `EFI/OC/Kexts` |
| `ReYogaSMC-<version>-DEBUG.zip` | `ReYogaSMC.kext` | Debug build with verbose IOLog tracing |
| `ReYogaSMC-App-<version>-RELEASE.zip` | `ReYogaSMC.app` | macOS workspace app with embedded `ReYogaSMCHelper.app` |

Verify downloaded archives against `SHA256SUMS.txt` attached to the release.

### 2. Configure OpenCore (`config.plist`)

Place `ReYogaSMC.kext` in `EFI/OC/Kexts` and ensure `Kernel -> Add` loads dependencies in the following order:

1. `Lilu.kext`
2. `VirtualSMC.kext`
3. `SMCProcessorAMD.kext` (AMD Ryzen) or `SMCProcessor.kext` (Intel)
4. `SMCRadeonSensors.kext` (if using an AMD Radeon iGPU/dGPU)
5. `ReYogaSMC.kext`

> [!IMPORTANT]
> CI builds are unsigned. Always keep a tested recovery EFI on a USB drive before updating kernel extensions.

### 3. Install `ReYogaSMC.app`

1. Copy `ReYogaSMC.app` into `/Applications`.
2. Reboot macOS and open `/Applications/ReYogaSMC.app`.
3. Open **Diagnostics** first to confirm your **Profile Match** state, active sensor sources, and verified capabilities before changing hardware settings.

---

## Kernel Boot Arguments

Add any of the following flags to `NVRAM -> Add -> 7C436110-AB2A-4BBB-A880-FE41995C9F82 -> boot-args` when diagnosing firmware behavior or opting into restricted features:

| Boot Argument | Effect |
| :--- | :--- |
| `-reysafe` | Start `ReYogaSMC.kext` in safe mode: skip ACPI/WMI hardware probes and block all firmware control writes |
| `-reynobridge` | Disable native ACPI profile matching and `RYID` SSDT bridge discovery; use generic ACPI/WMI only |
| `-reynowmi` | Skip vendor WMI probing on `IdeaVPC` |
| `-reycpupower` | Enable opt-in WMI CPU Boost and Sustained power-limit getters/setters on supported Legion firmware |
| `-reyfanstop` | Allow ThinkPad manual fan level `0` (`0 RPM`) through `kRYSMCUCThinkFan` |
| `-reydump` | Enable diagnostic EC read (`readEC`) and dump properties |
| `-reytrace` | Log ACPI/WMI method entry and exit markers (capped at 128 WMI calls to prevent log flooding) |
| `-reytel` | Increase periodic telemetry debug logging frequency |
| `reyec=<ms>` | Override the `IdeaVPC` telemetry polling interval in milliseconds (`500`–`10000`, default `2000`) |

---

## Troubleshooting & Known Issues

### 1. CPU or GPU Temperature Shows `Unavailable`
- **AMD CPU temperature missing:** Install `SMCProcessorAMD.kext` after `VirtualSMC.kext`. Verify in **Diagnostics → Telemetry Sources** that `CPU Temperature` resolves to `SMCProcessorAMD / TC0E` (or `TC0P`).
- **AMD GPU temperature missing:** Install `SMCRadeonSensors.kext`. Verify in **Diagnostics → Telemetry Sources** that `GPU Temperature` resolves to `SMCRadeonSensors / TG0D`.
- **NVIDIA dGPU temperature missing:** Expected behavior on Hackintosh laptops where the NVIDIA dGPU is disabled via SSDT/`-wegnoegpu` or masked with `NullNVSMCDriver`. When the dGPU is powered off, EC `GPUT` reads `0` and is filtered out.

### 2. Profile Match State Shows `identity_unavailable` or `conflict`
- OpenCore configurations that replace SMBIOS with a Mac model (`MacBookPro16,1`, etc.) overwrite SMBIOS Type 0 and Type 1 tables unless `UpdateSMBIOSMode` or OEM NVRAM/DeviceTree keys are preserved.
- On supported Legion models (such as Legion 7 16ACHg6), `ReYogaSMC` automatically falls back to verifying the Lenovo PCI subsystem ID (`17aa:xxxx`) paired with the DSDT OEM Table ID (`pci_matched`).
- If your machine has no unique PCI subsystem ID in its profile and SMBIOS is spoofed, expose the original 4-character Lenovo machine type and BIOS family prefix via `/efi/platform` or NVRAM (`OEMProduct` and `OEMBIOSVersion`), or run the hardware support tool so your exact DSDT SHA-256 digest can be reviewed.
- If `ProfileMatchState` reports `conflict`, two identity sources on your system disagree (for example, an injected `OEMProduct` does not match the board's PCI subsystem ID). Remove the mismatched property override.

### 3. Manual Fan Target RPM is Unavailable on IdeaPad / Legion
- Standard Lenovo WMI and native ACPI profiles expose fan RPM readings and preset thermal modes (`Quiet`, `Balanced`, `Performance`, and `Fn+Q` full-speed cooling), but do not provide a safe generic manual RPM floor register.
- Manual fan target RPM controls (`Fan1TargetRPM`, `Fan2TargetRPM`) are enabled only when a reviewed v2 ACPI bridge (`RYID = 0x52590102`) with hardware-validated writes (`RYVW = 1`) matches your exact DSDT SHA-256 fingerprint.

### 4. CPU Power Limits Locked After Switching Thermal Profiles
- When `CPUBoostPower` or `CPUSustainedPower` is modified (with `-reycpupower` enabled), the driver records the active thermal profile in `CPUPowerPendingProfile`.
- If the thermal profile is changed externally (for example via the hardware `Fn+Q` shortcut), the driver blocks further CPU power-limit edits and profile switches until you return to the modified profile and restore its saved baseline.

### 5. ThinkPad Manual Fan Control Disabled (`ThinkFanAccessFailed`)
- ThinkPad dual-fan access switches EC register `0x31` to select fan 2 and restores `0x31` before returning. If restoring register `0x31` fails during a transaction, the driver sets `ThinkFanAccessFailed = true` and disables further fan access until the next reboot so subsequent EC reads cannot hit the wrong bank.

### 6. Hotkeys, Fn Keys, or Caps Lock OSD Do Not Appear
- Ensure `ReYogaSMC.app` is located in `/Applications/ReYogaSMC.app`.
- Grant **Accessibility** and **Input Monitoring** permissions in **System Settings → Privacy & Security**.
- Because CI builds are unsigned (`ad-hoc`), macOS TCC invalidates previously granted permissions whenever you replace `ReYogaSMC.app` with a new build. Remove `ReYogaSMC` from **Accessibility** and **Input Monitoring** (or toggle both switches off and on) and relaunch the app.

### 7. Start with macOS Shows `Approve ReYogaSMC in System Settings → Login Items`
- On macOS 13 and newer, `SMAppService` registers the login item but requires user confirmation in **System Settings → General → Login Items** before macOS launches it at login.

---

## Exporting Diagnostics & Adding Device Support

1. Open **ReYogaSMC → Diagnostics** and click **Export Report…** to generate a local archive containing IORegistry driver properties, sensor status, recent bounded app logs, and `DSDT.aml` (when exported by the driver).
2. Alternatively, run the cross-platform collector from a repository checkout (Python 3.9+ required):
   - **macOS:** `./ReYoga.command`
   - **Windows:** `ReYoga.cmd`
3. Attach the generated report to a [Device Support issue](https://github.com/hoaug-tran/ReYogaSMC/issues/new/choose) along with your laptop model, BIOS version, and macOS version. See [Docs/hardware-tool.md](Docs/hardware-tool.md) for collector flags and bridge generation rules.

> [!TIP]
> Diagnostic archives are written locally and are never uploaded automatically. Inspect the archive contents before sharing publicly, as ACPI tables and SMBIOS records may contain hardware serial numbers.

---

## Building from Source

Install Xcode and the Xcode Command Line Tools, then run:

```sh
bash Scripts/bootstrap.sh
bash Scripts/build.sh Debug
bash Scripts/build.sh Release
bash Scripts/package.sh Release
```

- Pinned dependency versions (`MacKernelSDK`, `Lilu`, `VirtualSMC`) and SHA-256 digests are defined in [`Scripts/dependencies.json`](Scripts/dependencies.json).
- Build outputs are placed in `build/Debug` and `build/Release`; packaged archives are written to `build/packages`.
- To regenererate `ReYogaSMC/ReYogaFirmwareProfiles.hpp` after editing `HardwareProfiles/*.json`, run:
  ```sh
  python3 Scripts/generate_firmware_profiles.py
  ```
- To run the validation and sanitizer test suites:
  ```sh
  python3 -m unittest discover -s Tests -v
  ```
- To sign `ReYogaSMC.app` and its embedded `ReYogaSMCHelper.app` with a persistent local or Developer ID certificate (so macOS TCC preserves Accessibility / Input Monitoring across rebuilds):
  ```sh
  bash Scripts/sign-app.sh 'Developer ID Application: Your Name (TEAMID)' build/Release
  ```

---

## Credits & License

- Original [YogaSMC](https://github.com/zhen-zen/YogaSMC) created by **Zhen**.
- Distributed under the [GNU General Public License v2.0](LICENSE). All upstream copyright and license headers are preserved.
- Hardware protocol references: Linux [`thinkpad_acpi`](https://github.com/torvalds/linux/blob/master/drivers/platform/x86/lenovo/thinkpad_acpi.c) and [`ideapad-laptop`](https://github.com/torvalds/linux/blob/master/drivers/platform/x86/lenovo/ideapad-laptop.c), [LenovoLegionLinux](https://github.com/johnfanv2/LenovoLegionLinux), [LenovoLegionToolkit](https://github.com/BartoszCichecki/LenovoLegionToolkit), and [OpenRGB](https://gitlab.com/CalcProgrammer1/OpenRGB).
- Kernel SDK and SMC ecosystem maintained by [Acidanthera](https://github.com/acidanthera). ACPI disassembly tooling powered by [ACPICA](https://github.com/open-acpica/acpica).
