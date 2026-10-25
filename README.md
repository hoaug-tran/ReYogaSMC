<div align="center">

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="Assets/Brand/readme-dark.svg">
  <img src="Assets/Brand/readme-light.svg" alt="ReYogaSMC" width="720">
</picture>

[![Build](https://github.com/hoaug-tran/ReYogaSMC/actions/workflows/main.yml/badge.svg?branch=main)](https://github.com/hoaug-tran/ReYogaSMC/actions/workflows/main.yml)
[![Release](https://img.shields.io/github/v/release/hoaug-tran/ReYogaSMC)](https://github.com/hoaug-tran/ReYogaSMC/releases/latest)
[![License](https://img.shields.io/badge/license-GPL--2.0-blue)](LICENSE)

Hackintosh ACPI/WMI kernel extension and VirtualSMC plugin (`ReYogaSMC.kext`), macOS app (`ReYogaSMC.app`), and hardware support tool for Lenovo ThinkPad, IdeaPad, Yoga, LOQ, and Legion laptops, with HP WMI sensor/event support.
Forked from [YogaSMC 1.5.3](https://github.com/zhen-zen/YogaSMC).

[Releases](https://github.com/hoaug-tran/ReYogaSMC/releases/latest) - [Actions builds](https://github.com/hoaug-tran/ReYogaSMC/actions/workflows/main.yml) - [Hardware profiles](HardwareProfiles) - [Compatibility](Docs/compatibility.md) - [Hardware tool](Docs/hardware-tool.md)

</div>

---

## Overview

ReYogaSMC connects Lenovo ACPI (`VPC0` and `HKEY`), Lenovo WMI (`PNP0C14`), `AppleSmartBattery`, `AppleSMC`, and ITE USB RGB controllers to macOS. App hardware-control requests are serialized by the driver, checked against available firmware interfaces and verified through readback.

<p align="center">
  <img src="Assets/Screenshots/overview.png" alt="ReYogaSMC overview" width="860">
</p>

---

## Supported features

Available controls and sensors depend on what the laptop's firmware and connected devices expose:

| Interface | Provider | Supported features |
| :--- | :--- | :--- |
| **ThinkPad ACPI** | `ThinkVPC` (`LEN0068` / `LEN0268` `HKEY`) | Fn hotkeys, Fn Lock, keyboard backlight, battery start/stop charge thresholds (`BCTG`/`BCCS`/`BCSG`/`BCSS`), inhibit charge, force discharge, DYTC thermal profiles (`MMC` and `PSC`), mute/mic-mute LEDs, and serialized dual-fan EC control (`kRYSMCUCThinkFan`) |
| **IdeaPad / Yoga / Legion / LOQ ACPI** | `IdeaVPC` (`VPC0`) | Battery conservation mode (`GBMD`/`SBMC`), rapid charge, keyboard backlight (`HALS`/`SLBL`), Fn Lock, Always-on USB, native ACPI EC sensors (`FANS`, `FA2S`, `CPUT`, `GPUT`), and reviewed `RYID` ACPI bridge support |
| **Lenovo Game Zone WMI** | `IdeaWMIGameZone` | Thermal modes (`Quiet`, `Balanced`, `Performance`), full-speed fan control, opt-in CPU boost and sustained power limits (`-reycpupower`), display overdrive, touchpad lock, Win key lock, Y-logo LED, rear port lighting, and WMI sensor fallback |
| **Intel HID / HP WMI** | `ReYogaHIDD` (`INT33D5`), `DYVPC` | HID DSM Fn hotkeys, Yoga mode events, and HP WMI thermal/event sensors |
| **Smart battery** | `AppleSmartBattery` | Charge percentage, charging state, current/full-charge/design capacity (mAh), design health percentage, cycle count, voltage (V), signed current (mA), power draw (W), temperature (°C), and AC adapter watt rating |
| **SMC sensors** | `AppleSMC` | Read-only CPU (`TC0E`, `TC0P`, `TC0D`, `TC0F`, `TC0C`, `TC1C`, `TCSA`) and GPU (`TG0D`, `TG0P`, `TG0E`) temperature keys |
| **ITE `c968` USB RGB** | `IOHIDManager` (`0x048d:0xc955/0xc965/0xc967/0xc975/0xc985`) | Built-in lighting effects, speed, 2-level brightness, 4-zone static RGB colors, and per-key RGB JSON profile import |

> [!NOTE]
> `AppleSmartBattery`, `AppleSMC` temperature sensors, and ITE `c968` USB RGB run directly in userspace. They remain usable even when `ReYogaSMC.kext` is not loaded, is started with `-reysafe`, or does not match a Lenovo VPC device.

---

## Supported laptops and hardware profiles

ReYogaSMC supports two categories of Lenovo laptops:

### 1. ThinkPad, Yoga, IdeaPad, and older Lenovo laptops

Most Lenovo laptops **do not need** a profile file in [`HardwareProfiles/`](HardwareProfiles):

- **ThinkPad series (T, X, X1 Carbon, P, L, E, etc.):** Controlled dynamically through standard ThinkPad `HKEY` ACPI methods (`ThinkVPC`). Battery charge thresholds, Fn hotkeys, Fn Lock, keyboard backlight, DYTC thermal modes and fan control use the available firmware interfaces without per-model JSON profiles. Individual features can still be unavailable.
- **Yoga, IdeaPad, and older Lenovo laptops:** Controlled through standard `VPC0` ACPI methods (`IdeaVPC`) and Lenovo WMI (`IdeaWMI`). Battery conservation mode (`GBMD`/`SBMC`), rapid charge, keyboard backlight (`HALS`/`SLBL`), Fn Lock, Always-on USB, hotkeys and thermal modes depend on the advertised methods and successful readback.

### 2. Legion, LOQ, IdeaPad Gaming, and Yoga Slim profiles

On newer Lenovo gaming and consumer laptops, fan speeds (`FANS`, `FA2S`) and EC temperatures (`CPUT`, `GPUT`) are stored in model-specific ACPI EC fields instead of standard `VPC0` methods. For those machines, `IdeaVPC` uses [`HardwareProfiles/`](HardwareProfiles) to verify the laptop before reading its ACPI EC sensors:

1. **DSDT header check:** Valid `DSDT` signature, byte length (`36 .. 1048576` bytes), 8-bit checksum (`0x00`), and `LENOVO` OEM ID.
2. **OEM table ID:** Matches the profile's `oem_table_ids` (such as `CB-01`).
3. **Machine type and BIOS family:** Checked across `/`, `/efi/platform`, `IOPlatformExpertDevice`, `/options` NVRAM (`OEMProduct`, `OEMBoard`, `OEMBIOSVersion`), and `AppleSMBIOS` Type 0 / Type 1 strings, or matched by a model-specific Lenovo PCI subsystem ID (`17aa:xxxx`).
4. **Conflict rejection:** If two identity sources disagree (`conflict`) or multiple profiles match (`ambiguous`), model-specific EC reads are disabled while standard ACPI, WMI, battery, and SMC features stay active.

| Profile ID | Model name | Machine types | BIOS families | EC path |
| :--- | :--- | :--- | :--- | :--- |
| `ideapad-gaming3-gen5` | Lenovo IdeaPad Gaming 3 15ARH05 | `82EY` | `FCCN` | `\_SB.PCI0.LPC0.EC0` |
| `ideapad-gaming3-gen6` | Lenovo IdeaPad Gaming 3 15ACH6 | `82K2`, `82K1` | `H3CN` | `\_SB.PCI0.LPC0.EC0` |
| `legion-pro5-gen8-arh` | Lenovo Legion Pro 5 16ARX8 | `82WM`, `82WQ` | `LPCN` | `\_SB.PCI0.LPC0.EC0` |
| `legion-pro5-gen8-irx` | Lenovo Legion Pro 5 16IRX8 | `82WK`, `82WL` | `KWCN` | `\_SB.PC00.LPCB.EC0` |
| `legion-pro5-gen9-irx` | Lenovo Legion Pro 5 16IRX9 | `83DF` | `N2CN` | `\_SB.PC00.LPCB.EC0` |
| `legion-pro7-gen8-irx` | Lenovo Legion Pro 7 16IRX8H | `82WQ`, `82WR` | `KWCN` | `\_SB.PC00.LPCB.EC0` |
| `legion-pro7-gen9-irx` | Lenovo Legion Pro 7 16IRX9 | `83FD` | `NSCN` | `\_SB.PC00.LPCB.EC0` |
| `legion5-gen5-ach` | Lenovo Legion 5 15ARH05 | `82B5`, `82B1`, `82EY`, `82GN` | `EUCN`, `FSCN` | `\_SB.PCI0.LPC0.EC0` |
| `legion5-gen5-imh` | Lenovo Legion 5 15IMH05 | `81Y6`, `82AU`, `82B3`, `81Y8` | `EFCN`, `E9CN` | `\_SB.PCI0.LPC0.EC0` |
| `legion5-gen6-ach` | Lenovo Legion 5 15ACH6 | `82JW`, `82JU`, `82NW` | `GKCN`, `HHCN` | `\_SB.PCI0.LPC0.EC0` |
| `legion5-gen7-arh` | Lenovo Legion 5 15ARH7 | `82RE`, `82RD` | `JUCN`, `K9CN` | `\_SB.PCI0.LPC0.EC0` |
| `legion5pro-gen6-ach` | Lenovo Legion 5 Pro 16ACH6H | `82JQ`, `82JS` | `GKCN` | `\_SB.PCI0.LPC0.EC0` |
| `legion5pro-gen7-iah` | Lenovo Legion 5 Pro 16IAH7H | `82RF`, `82RG` | `J2CN`, `KFCN` | `\_SB.PC00.LPCB.EC0` |
| `legion7-16achg6-gkcn` | Lenovo Legion 7 2021 16ACHg6 | `82N6` | `GKCN` | `\_SB.PCI0.LPC0.EC0` |
| `legion7-gen5-imh` | Lenovo Legion 7 15IMH05 | `81YT`, `81YU` | `E9CN` | `\_SB.PCI0.LPC0.EC0` |
| `legion7-gen6-ith` | Lenovo Legion 7 16ITHg6 | `82K6` | `H1CN` | `\_SB.PC00.LPCB.EC0` |
| `legion7-gen7-arh` | Lenovo Legion 7 16ARHA7 | `82UH` | `K9CN` | `\_SB.PCI0.LPC0.EC0` |
| `loq-gen8-aph` | Lenovo LOQ 15APH8 | `82XT` | `LYCN` | `\_SB.PCI0.LPC0.EC0` |
| `loq-gen8-irh` | Lenovo LOQ 15IRH8 | `82XV`, `82XW`, `82XU` | `LZCN` | `\_SB.PC00.LPCB.EC0` |
| `loq-gen9-ahp` | Lenovo LOQ 15AHP9 | `83DX`, `83DV`, `83JC` | `NECN` | `\_SB.PCI0.LPC0.EC0` |
| `yoga-slim7-gen5` | Lenovo Yoga Slim 7 14ARE05 | `82A2`, `82A8` | `DMCN`, `EMCN` | `\_SB.PCI0.LPC0.EC0` |

> [!IMPORTANT]
> The table reflects the JSON catalog, not a certification of every model/BIOS combination. Matching enables validated sensor reads with per-sensor WMI fallback. Manual fan writes require separate validation; all current ACPI profiles leave them disabled.

---

## Temperature sensors

The app preserves fractional readings and displays one decimal, such as `55.5 °C`. A sensor that reports only whole degrees appears as `55.0 °C`.

The app prefers valid CPU/GPU readings from `AppleSMC` and falls back to driver firmware readings (`CPUT`, `GPUT` or Game Zone WMI). Available sources include:

| Sensor | Kext or firmware source | SMC keys / firmware fields | Notes |
| :--- | :--- | :--- | :--- |
| **AMD Ryzen CPU** | [**SMCProcessorAMD.kext**](https://github.com/trulyspinach/SMCAMDProcessor) | `TC0E`, `TC0P`, `TC0D`, `TC0F` | Needed on AMD Ryzen laptops when ACPI EC `CPUT` or WMI CPU temperature is unavailable |
| **Intel CPU** | [**SMCProcessor.kext**](https://github.com/acidanthera/VirtualSMC) | `TC0P`, `TC0D`, `TC0C`, `TC1C`, `TCSA` | Included in the official VirtualSMC release archive |
| **AMD Radeon iGPU / dGPU** | [**SMCRadeonSensors.kext**](https://github.com/ChefKissInc/SMCRadeonSensors) | `TG0D`, `TG0P`, `TG0E` | Needed to read AMD Radeon iGPU and dGPU temperatures through `AppleSMC` |
| **NVIDIA dGPU** | Firmware EC / WMI | `GPUT` | Depends on firmware and whether the GPU is powered |

A powered-off GPU may have no valid temperature source. Zero or invalid readings are shown as unavailable; installing a graphics driver does not establish EC sensor support.

---

## App

`ReYogaSMC.app` runs in the menu bar and opens a 6-section control window in English or Vietnamese (`en.lproj` / `vi.lproj`):

| Device controls | Cooling and power |
| :---: | :---: |
| <img src="Assets/Screenshots/device.png" alt="Device controls" width="420"> | <img src="Assets/Screenshots/cooling.png" alt="Cooling and power" width="420"> |
| **Battery status and health** | **Keyboard and USB RGB lighting** |
| <img src="Assets/Screenshots/battery.png" alt="Battery status" width="420"> | <img src="Assets/Screenshots/lighting.png" alt="Lighting controls" width="420"> |
| **Diagnostics and sensor sources** | **App settings** |
| <img src="Assets/Screenshots/diagnostics.png" alt="Diagnostics" width="420"> | <img src="Assets/Screenshots/settings.png" alt="Settings" width="420"> |

- **Overview:** CPU/GPU temperatures, fan speeds, battery charge ring, thermal mode selector (`Quiet`, `Balanced`, `Performance`), and quick hardware toggles.
- **Device:** Battery conservation mode (firmware-defined charge limit), rapid charge, display overdrive, touchpad lock, Win key lock, Fn Lock, Always-on USB, and custom action mapping for Lenovo Fn hotkeys (`Bluetooth`, `Search`, `Siri`, `Sleep`, `Mic`, `Second Display`, or launching an app/script).
- **Cooling:** Thermal mode switching, full-speed fan toggle, manual fan minimum RPM (when a validated v2 ACPI bridge is active), and opt-in WMI CPU boost / sustained power limits.
- **Battery:** Live `AppleSmartBattery` charge level, design health, cycle count, capacity breakdown (current / full-charge / design mAh), voltage, current, wattage, temperature, and adapter rating.
- **Lighting:** Keyboard backlight levels, Y-logo LED, rear port lighting, and USB RGB controls for supported ITE `c968` controllers.
- **Diagnostics:** Firmware profile match state, DSDT SHA-256 and OEM table ID, machine type and BIOS family, active temperature/fan sources (`Native ACPI`, `WMI`, `SMCProcessorAMD`, `SMCRadeonSensors`), per-feature availability reasons, and local diagnostic export.
- **Settings and OSD:** App on-screen display (OSD) popups for thermal modes, keyboard backlight, Fn Lock, touchpad, mic/camera, and Caps Lock, plus startup registration, update checks, and in-app language selection (`System`, `English`, `Tiếng Việt`).

---

## Installation

Requires **macOS 11 (Big Sur) or newer** and OpenCore.

> [!WARNING]
> **Upgrading from YogaSMC or ReYogaSMC 2.0.0:**  
> Do not load `YogaSMC.kext` or `ReYogaSMCAlter.kext` alongside `ReYogaSMC.kext`. Before installing, remove any old `YogaSMC*.kext` / `ReYogaSMCAlter.kext` entries from `EFI/OC/Kexts` and `config.plist`, and delete `/Applications/YogaSMCNC.app`, `/Applications/ReYogaSMCNC.app`, and `/Library/PreferencePanes/YogaSMCPane.prefPane` so old background helpers do not conflict with `ReYogaSMC.app`.

### 1. Download packages

Download the latest release from [GitHub Releases](https://github.com/hoaug-tran/ReYogaSMC/releases/latest) or from a completed [Actions run](https://github.com/hoaug-tran/ReYogaSMC/actions/workflows/main.yml):

| File | Contents | Usage |
| :--- | :--- | :--- |
| `ReYogaSMC-<version>-RELEASE.zip` | `ReYogaSMC.kext` | Daily-use kext for `EFI/OC/Kexts` |
| `ReYogaSMC-<version>-DEBUG.zip` | `ReYogaSMC.kext` | Debug kext with verbose kernel logging |
| `ReYogaSMC-App-<version>-RELEASE.zip` | `ReYogaSMC.app` | macOS app with bundled `ReYogaSMCHelper.app` |

Check `SHA256SUMS.txt` on the release page to verify the downloaded archives.

### 2. Load kexts in OpenCore

Copy `ReYogaSMC.kext` to `EFI/OC/Kexts` and order `Kernel -> Add` in `config.plist` so dependencies load first:

1. `Lilu.kext`
2. `VirtualSMC.kext`
3. `ReYogaSMC.kext`

CPU/GPU sensor plugins are optional temperature sources. Load them after their dependencies; they are not required for ReYogaSMC hotkeys or battery controls.

> [!IMPORTANT]
> Release and CI kexts are unsigned; the app and embedded helper are ad-hoc signed. Keep a working recovery EFI on a USB drive when updating kexts.

### 3. Install the app

1. Copy `ReYogaSMC.app` to `/Applications`.
2. Restart macOS and open `/Applications/ReYogaSMC.app`.
3. Open **Diagnostics** to check your profile match state, active sensor sources, and available controls before changing hardware settings.

---

## Boot arguments

Add any of the following flags to `boot-args` in `config.plist` when troubleshooting or enabling opt-in features:

| Boot argument | Description |
| :--- | :--- |
| `-reysafe` | Start `ReYogaSMC.kext` in safe mode: skip ACPI/WMI hardware probes and block all firmware writes |
| `-reynobridge` | Disable native ACPI profile matching and `RYID` SSDT bridge discovery; use generic ACPI/WMI only |
| `-reynowmi` | Disable vendor WMI probing, including IdeaVPC and HP WMI interfaces |
| `-reycpupower` | Enable opt-in WMI CPU boost and sustained power-limit controls on supported Legion firmware |
| `-reyfanstop` | Allow ThinkPad manual fan level `0` (`0 RPM`) through `kRYSMCUCThinkFan` |
| `-reytrace` | Log ACPI/WMI method entry and exit markers (capped at 128 WMI calls) |

---

## Troubleshooting

### 1. CPU or GPU temperature shows `Unavailable`

- **AMD CPU temperature missing:** Load `SMCProcessorAMD.kext` after `VirtualSMC.kext`. Check **Diagnostics → Telemetry sources** to confirm `CPU Temperature` uses `SMCProcessorAMD / TC0E` (or `TC0P`).
- **AMD GPU temperature missing:** Load `SMCRadeonSensors.kext`. Check **Diagnostics → Telemetry sources** to confirm `GPU Temperature` uses `SMCRadeonSensors / TG0D`.
- **NVIDIA dGPU temperature missing:** Check whether the GPU is powered and whether firmware supplies a valid `GPUT`/WMI reading. A missing firmware sensor cannot be supplied by ReYogaSMC.

### 2. Profile match state shows `identity_unavailable` or `conflict`

- OpenCore setups that spoof a Mac SMBIOS (`MacBookPro16,1`, etc.) replace SMBIOS Type 0 and Type 1 strings unless original OEM fields are preserved.
- On models with verified Lenovo PCI subsystem IDs in `HardwareProfiles/` (such as Legion 7 16ACHg6), `ReYogaSMC` matches the board's PCI subsystem ID (`17aa:xxxx`) together with the DSDT OEM table ID (`pci_matched`).
- For other models in `HardwareProfiles/` when SMBIOS is spoofed, expose the original 4-character Lenovo machine type and BIOS family prefix in `/efi/platform` or NVRAM (`OEMProduct` and `OEMBIOSVersion`), or export diagnostics so your DSDT SHA-256 digest can be reviewed.
- If `ProfileMatchState` is `conflict`, two identity sources on the system disagree (for example, an injected `OEMProduct` does not match the board's PCI subsystem ID). Remove the mismatched property.

### 3. Manual fan minimum RPM is disabled on IdeaPad or Legion

- Available ACPI/WMI interfaces may provide RPM readings, preset thermal modes and a separate full-speed fan toggle. These do not establish a safe generic manual RPM floor register.
- Manual fan minimum RPM controls (`Fan1TargetRPM`, `Fan2TargetRPM`) are enabled only when a reviewed v2 ACPI bridge (`RYID = 0x52590102`) with hardware-validated writes (`RYVW = 1`) matches your exact DSDT SHA-256 fingerprint.

### 4. CPU power limits are locked after switching thermal mode

- When `CPUBoostPower` or `CPUSustainedPower` is changed (with `-reycpupower` enabled), the driver records the active thermal profile in `CPUPowerPendingProfile`.
- If the thermal profile changes outside the app (such as pressing `Fn+Q`), the driver locks power-limit edits until you switch back to the recorded profile and restore its saved values.

### 5. ThinkPad fan control and ACPI bridge generation

- ThinkPad laptops do not use `HardwareProfiles/*.json` or `SSDT-ReYoga` bridges. The app hides **Generate ACPI bridge** when connected to ThinkVPC.
- ThinkPad fan speeds and manual levels (`Auto`, `Full Speed`, and levels `1`–`7`) are controlled in **Cooling → ThinkPad Fans** through the `ThinkFanProtocolVersion = 1` user client (`kRYSMCUCThinkFan`), which requires a `PNP0C09` EC device with `RW` access.
- If EC access is Basic or RO, check the real EC path and the `RE1B`/`WE1B` methods. Adapt [SSDT-ECRW.dsl](ReYogaSMC/SSDTSample/SSDT-ECRW.dsl) only after checking existing battery patches for field/method conflicts. ECEnabler alone does not add these methods.
- On dual-fan ThinkPads, the driver writes EC register `0x31` to select the second fan and restores `0x31` before finishing. If restoring `0x31` fails during a transaction, the driver sets `ThinkFanAccessFailed = true` and disables further fan access until reboot so later EC reads cannot hit the wrong bank.

### 6. Hotkeys, Fn keys, Bluetooth toggle, or Caps Lock OSD do not work

- Keep `ReYogaSMC.app` in `/Applications/ReYogaSMC.app`.
- Enable **Accessibility** and **Input Monitoring** for `ReYogaSMC` in **System Settings → Privacy & Security** (and allow **Bluetooth** access when using the `Fn+F10` Bluetooth hotkey).
- Because ad-hoc signed builds change their signature when rebuilt or updated, macOS may require privacy approval again after replacing the app. Remove `ReYogaSMC` from **Accessibility** and **Input Monitoring** (or toggle both switches off and back on), then reopen the app.

### 7. Start with macOS shows `Approve ReYogaSMC in System Settings → Login Items`

- On macOS 13 and newer, `SMAppService` registers the login item and waits for user approval in **System Settings → General → Login Items**. `Scripts/build.sh` and `Scripts/package.sh` ad-hoc sign `ReYogaSMC.app` to avoid shipping an unsigned bundle. Ad-hoc signing alone does not establish that login registration or permission persistence works on every macOS release. If registration still fails, install the app in `/Applications`, check Login Items approval, and collect diagnostics; use `Scripts/sign-app.sh` with a persistent signing identity for updates.

### 8. Windows hardware tool (`ReYoga.cmd`) reports that EC read is unavailable

- Windows blocks raw I/O port `0x62`/`0x66` access from unprivileged processes. Collecting a live 256-byte EC snapshot on Windows (`--ec-read`) is optional and requires the signed [PawnIO driver](https://pawnio.eu/) installed with Administrator privileges.
- Standard ACPI table dumps (`DSDT.aml`, `SSDT*.aml`) and WMI inventory on Windows work without PawnIO or EC read access.

---

## Compatibility limits

- T490 BIOS 1.85 provides the PSC interface used by the thermal-profile fix. Thermal modes, Fn+F10, login registration, performance and lid sleep still need validation with the updated app and kext on that machine. Removing the DYTC feedback path does not establish the cause of a graphics panic.
- Some X1 Carbon Gen 6 firmware rejects Quiet mode. Older MMC firmware may hide the active profile during lap mode; polling does not change lap mode to reveal it.
- Legion/LOQ support depends on firmware capabilities and the matching profile. A similar model name does not justify reusing register offsets.
- HP support covers the implemented WMI sensor/event interfaces, not every HP generation or the separate Elite x2 brightness interface. See [compatibility](Docs/compatibility.md) for sensor formats and unsupported cases.

---

## Device information

1. Open **ReYogaSMC → Diagnostics** and click **Export diagnostics** to save a local ZIP containing driver properties, sensor status, recent app logs, and `DSDT.aml` (when exported by the driver).
2. You can also run the collection tool from a source checkout (requires Python 3.9+):
   - **macOS:** `./ReYoga.command`
   - **Windows:** `ReYoga.cmd`
3. Attach the ZIP to a [device-support issue](https://github.com/hoaug-tran/ReYogaSMC/issues/new/choose) with your laptop model, BIOS version, and macOS version. See the [hardware tool guide](Docs/hardware-tool.md) for command-line flags.

> [!TIP]
> Diagnostic exports stay on your machine until you share them. Check the ZIP contents before posting publicly, as ACPI tables and SMBIOS data may contain serial numbers.

---

## Build from source

Install Xcode and its command-line tools, then run:

```sh
bash Scripts/bootstrap.sh
bash Scripts/build.sh Debug
bash Scripts/build.sh Release
bash Scripts/package.sh Release
```

- `Scripts/build.sh` and `Scripts/package.sh` run as a normal user without `sudo`.
- Locked dependency versions (`MacKernelSDK`, `Lilu`, `VirtualSMC`) and SHA-256 checksums are stored in [`Scripts/dependencies.json`](Scripts/dependencies.json).
- After editing `HardwareProfiles/*.json`, regenerate `ReYogaSMC/ReYogaFirmwareProfiles.hpp`:
  ```sh
  python3 Scripts/generate_firmware_profiles.py
  ```
- Run the test suite:
  ```sh
  python3 -B -m unittest discover -s Tests -v
  ```
- Sign the app with a local or Developer ID certificate using the same identity for subsequent builds to reduce repeated privacy prompts:
  ```sh
  bash Scripts/sign-app.sh 'Developer ID Application: Your Name (TEAMID)' build/Release
  ```

---

## Credits and license

- Original [YogaSMC](https://github.com/zhen-zen/YogaSMC) by **Zhen**.
- Licensed under [GPL v2.0](LICENSE); original copyright and license notices are retained.
- Protocol references: Linux [`thinkpad_acpi`](https://github.com/torvalds/linux/blob/master/drivers/platform/x86/lenovo/thinkpad_acpi.c) and [`ideapad-laptop`](https://github.com/torvalds/linux/blob/master/drivers/platform/x86/lenovo/ideapad-laptop.c), [LenovoLegionLinux](https://github.com/johnfanv2/LenovoLegionLinux), [LenovoLegionToolkit](https://github.com/BartoszCichecki/LenovoLegionToolkit), and [OpenRGB](https://gitlab.com/CalcProgrammer1/OpenRGB).
- Kernel SDK and SMC plugins by [Acidanthera](https://github.com/acidanthera), [SMCAMDProcessor](https://github.com/trulyspinach/SMCAMDProcessor), [SMCRadeonSensors](https://github.com/ChefKissInc/SMCRadeonSensors), and [ACPICA](https://github.com/open-acpica/acpica).
