<div align="center">

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="Assets/Brand/readme-dark.svg">
  <img src="Assets/Brand/readme-light.svg" alt="ReYogaSMC" width="520">
</picture>

[![Build](https://github.com/hoaug-tran/ReYogaSMC/actions/workflows/main.yml/badge.svg?branch=main)](https://github.com/hoaug-tran/ReYogaSMC/actions/workflows/main.yml)
[![Release](https://img.shields.io/github/v/release/hoaug-tran/ReYogaSMC)](https://github.com/hoaug-tran/ReYogaSMC/releases/latest)
[![License](https://img.shields.io/badge/license-GPL--2.0-blue)](LICENSE)

Laptop sensors, hotkeys and hardware controls for macOS.

[Download](https://github.com/hoaug-tran/ReYogaSMC/releases/latest) | [Install](#installation) | [Compatibility](Docs/compatibility.md) | [Changelog](Changelog.md)

</div>

ReYogaSMC is a fork of [YogaSMC](https://github.com/zhen-zen/YogaSMC) by [Zhen](https://github.com/zhen-zen). It includes a VirtualSMC plugin, Lenovo ACPI/WMI controls, HP WMI sensor support and a macOS app in English and Vietnamese.

This branch contains changes for **2.2.0**. The release page provides the latest published build.

<p align="center">
  <a href="Assets/Screenshots/overview.png"><img src="Assets/Screenshots/overview.png" alt="Temperatures, fan readings and battery status on a Lenovo Legion 7" width="900"></a>
</p>

## Features

Features depend on the interfaces exposed by each laptop's firmware.

| Device or interface | Functions |
| --- | --- |
| ThinkPad HKEY | Hotkeys, Fn Lock, keyboard backlight, charge thresholds, DYTC power profiles, mute LEDs and EC fan control |
| IdeaPad, Yoga, Legion and LOQ | Battery conservation, rapid charge, power profiles, fan readings, backlight and USB power |
| Legion Game Zone WMI | Full Speed, CPU power limits, display overdrive, touchpad/Win key lock and supported logo/port lights |
| HP WMI and Intel HID | Mapped sensors and supported hotkey events |
| AppleSmartBattery and AppleSMC | Battery capacity, health and electrical readings; available CPU/GPU temperatures |
| ITE c968 USB RGB (`048d:c968`) | Lighting modes, zone colors and per-key color import |

The app groups controls into Overview, Device, Cooling, Battery, Lighting, Diagnostics and Settings. Battery, SMC temperatures and supported USB RGB controllers can work without a VPC driver connection. Updates are downloaded and installed manually.

### ThinkPad fan control

| Mode | Action |
| --- | --- |
| BIOS Auto | Return fan control to firmware immediately |
| Manual | Choose a fan level, then select Apply |
| Custom Curve | Edit temperature points and fan levels, then select Apply |
| Full Speed | Request the firmware's Full Speed mode immediately |

Manual control needs working EC read/write helpers. Custom Curve also needs the driver watchdog and a fresh CPU temperature. The app must remain open while a curve runs. Sleep, lost readings, disconnect or app shutdown stops the curve and requests BIOS Auto. The driver watchdog also requests Auto if updates stop.

The matching app and kext use a macOS administrator dialog to install a root fan-authorization helper. Authorization survives app restarts and reboot; passwords are never saved. Updating or re-signing the app, or using another macOS account, requires authorization again. Cancelling leaves fan controls unavailable; retry with **Authorize Fan Control…** in Cooling. The helper grants only fan access to the authenticated app connection, not raw EC access.

**Restore fan mode at startup** restores confirmed Auto, Manual or Full Speed choices for the same firmware identity. Choices are saved when commands succeed, rather than only when quitting. A Custom Curve saves its points and starts in Auto after reboot; start the curve explicitly.

Curve points are saved by firmware and fan. A curve does not restart automatically after sleep or reconnect. Full Speed is a firmware mode; it does not promise a fixed RPM.

### Legion and IdeaPad fan behavior on macOS

Non-ThinkPad Lenovo laptops (Legion, IdeaPad, Yoga, LOQ) rely on the Embedded Controller's internal thermal loop rather than ThinkPad manual fan levels.

- **Full Speed availability**: On older models (e.g. Y540, Y740), firmware advertises fan cooling capability (`GAME_ZONE_WMI_CAP_FAN_COOLING`) and accepts the vendor ACPI command `NCMD(0x59, 0x70)`. On modern revisions (such as Legion 7 16ACHg6 with GKCN BIOS, for example), Lenovo removed this handler from the EC firmware and reports capability `0x0C` as `0`. ReYogaSMC detects this capability and only presents the Full Speed control on machines whose firmware actually executes it.
- **Dual-sensor thermal cooling on macOS**: On laptops with shared thermal architecture (heatpipes or unified vapor chamber), the EC regulates fan speed based on both CPU and GPU temperatures. Because the dedicated GPU is disabled on macOS (e.g. via `SSDT-dGPU-OFF`), its temperature sensor stays cold. The firmware's internal thermal table keeps the GPU fan around idle/low speed (~2500-2700 RPM) and acoustic limits cap the CPU fan around ~3000-3500 RPM. Because only one side of the cooling assembly actively exhausts air under single-chip load, CPU temperatures naturally sit higher (75-85 °C) under sustained load than on Windows, where both fans spin up together.
- **Hardware safety**: ReYogaSMC communicates exclusively through documented vendor ACPI/WMI interfaces. It does not perform raw writes into the EC's internal RAM tables. Arbitrary EC RAM writes on laptop hardware risk triggering instant emergency shutdowns or microcontroller lockups.

See [compatibility](Docs/compatibility.md) for control limits and unavailable states.

<details>
<summary>More screenshots</summary>

Screenshots show a Legion 7 16ACHg6 as an example. Other machines expose different controls.

| Device | Battery |
| --- | --- |
| [![Device controls](Assets/Screenshots/device.png)](Assets/Screenshots/device.png) | [![Battery readings](Assets/Screenshots/battery.png)](Assets/Screenshots/battery.png) |

| Cooling | Lighting |
| --- | --- |
| [![Cooling controls](Assets/Screenshots/cooling.png)](Assets/Screenshots/cooling.png) | [![Lighting controls](Assets/Screenshots/lighting.png)](Assets/Screenshots/lighting.png) |

[![Diagnostics](Assets/Screenshots/diagnostics.png)](Assets/Screenshots/diagnostics.png)

</details>

## Requirements

- macOS 11 or newer on x86_64 hardware and OpenCore.
- [Lilu](https://github.com/acidanthera/Lilu) and [VirtualSMC](https://github.com/acidanthera/VirtualSMC).
- Matching ReYogaSMC app and kext versions.
- Firmware support for the controls you want to use.

CPU/GPU sensor plugins are optional; they are not required for hotkeys or battery controls.

## Installation

Keep a working EFI backup before changing kexts or ACPI tables.

1. Download the kext and app from [Releases](https://github.com/hoaug-tran/ReYogaSMC/releases/latest). Use RELEASE builds for normal use and DEBUG builds when collecting logs.

   | Archive | Contents |
   | --- | --- |
   | `ReYogaSMC-<version>-RELEASE.zip` | Release kext |
   | `ReYogaSMC-<version>-DEBUG.zip` | Debug kext |
   | `ReYogaSMC-App-<version>-RELEASE.zip` | App and login helper |
   | `ReYogaSMC-App-<version>-DEBUG.zip` | Debug app and login helper |

   Download `SHA256SUMS.txt` alongside the archives and run `shasum -a 256 -c SHA256SUMS.txt`. Missing archives are reported separately; the archives you downloaded must match their checksums.

2. Quit any older YogaSMC app. Remove old YogaSMC/ReYogaSMC kext entries before adding the replacement. Do not load `YogaSMC.kext` or `ReYogaSMCAlter.kext` alongside `ReYogaSMC.kext`.
3. Copy `ReYogaSMC.kext` to `EFI/OC/Kexts` and add it under `Kernel → Add` in `config.plist`. Load dependencies in this order:

   ```text
   Lilu.kext
   VirtualSMC.kext
   ReYogaSMC.kext
   ```

4. Copy `ReYogaSMC.app` to `/Applications`. Replace the old app and remove unused `YogaSMCNC.app`, `ReYogaSMCNC.app` or `YogaSMCPane.prefPane` installations.
5. Restart macOS, open the app and check **Diagnostics** for the driver version, available controls and sensor sources.

Kexts are unsigned. The app and its helper are ad-hoc signed by the build scripts. Follow OpenCore's requirements for third-party kexts; app installation does not install or load a kext.

### Permissions and startup

Enable **Start with macOS** in Settings. On macOS 13 and newer, approve the app in System Settings → Login Items if requested. macOS 11/12 uses the bundled login helper.

The keyboard mapper needs Accessibility and Input Monitoring permission. Bluetooth actions may request Bluetooth access. Keep the app in `/Applications` and reopen it if macOS requests a restart. Replacing an ad-hoc signed app can require permission approval again.

## Hardware support

ThinkPad controls use HKEY and EC methods; they do not need an IdeaPad/Legion JSON profile. Generic IdeaPad/Yoga battery and keyboard controls also use firmware methods directly.

Model-specific sensors and USB RGB layouts use [hardware profiles](HardwareProfiles/README.md). A recognized model name does not enable writes. Current ACPI profiles leave raw manual fan writes disabled; thermal profiles and firmware Full Speed are separate controls.

- [Compatibility and control limits](Docs/compatibility.md)
- [Profile fields and model list](HardwareProfiles/README.md)
- [Collect a hardware report](Docs/hardware-tool.md)

### ThinkPad ACPI helpers

If Cooling reports missing EC helpers:

1. Open **Diagnostics → Generate ThinkPad SSDT…**.
2. Choose an output file. The app checks running tables and existing helpers, then exports source, compiled AML and an analysis file.
3. Review the result and back up your EFI. Keep required EC and battery patches. Remove or replace overlapping helper declarations only after checking them.
4. Add the generated AML to OpenCore's `ACPI → Add`, restart and select **Verify ThinkPad SSDT**.

The app uses an installed `iasl` first, including `/usr/local/bin/iasl`, `/opt/homebrew/bin/iasl`, `PATH`, `~/bin/iasl`, a configured `IASLPath` or MaciASL's bundled stable compiler. If none is found, it downloads a pinned macOS binary and checks SHA-256. It never overwrites your installed compiler.

Verification needs the generation record for the current firmware. An older hand-written SSDT may provide working helpers without that record. Generated files are never installed automatically.

Other samples are listed in [ACPI patches](Docs/compatibility.md#acpi-patches). Do not load a sample unchanged on another machine.

## Troubleshooting

| Problem | Check |
| --- | --- |
| Driver missing | OpenCore entry, dependency order, matching versions and kernel log |
| Temperature unavailable | Active sensor source in Diagnostics; add the appropriate optional SMC sensor plugin if needed |
| Fan controls unavailable | EC helper status, driver protocol and Safe Mode; use the reason shown in Cooling |
| Power profile read error | Refresh the connection and retry; export diagnostics if firmware still returns no valid mode |
| Verify says no generated SSDT is recorded | Generate for this firmware first; follow the helper steps above |
| Start with macOS needs approval | App location, signature and Login Items settings |
| Hotkey mapping is inactive | Accessibility/Input Monitoring permissions and a supported mapping |

Enable **Detailed Logging**, repeat the failing action once, then use **Diagnostics → Export diagnostics**. Review the archive before sharing it. Reports can include device identifiers, firmware tables and local paths.

Open an [issue](https://github.com/hoaug-tran/ReYogaSMC/issues/new/choose) with the model, BIOS, macOS, app/kext versions, requested action and observed result. Stop testing a control that causes shutdown or loss of cooling. Report security problems through [SECURITY.md](SECURITY.md).

## Build from source

Use macOS with Xcode and its command-line tools:

```sh
git clone https://github.com/hoaug-tran/ReYogaSMC.git
cd ReYogaSMC
bash Scripts/bootstrap.sh
bash Scripts/build.sh Debug
bash Scripts/build.sh Release
```

Builds are written under `build/`. Dependency versions and checksums are pinned in [Scripts/dependencies.json](Scripts/dependencies.json). Packaging, signing, tests and contribution rules are in [CONTRIBUTING.md](CONTRIBUTING.md).

## Credits and license

- [YogaSMC](https://github.com/zhen-zen/YogaSMC) by Zhen; original author and license notices are retained.
- [Acidanthera](https://github.com/acidanthera) for Lilu, VirtualSMC, MacKernelSDK and MaciASL.
- Protocol references: Linux [thinkpad_acpi](https://github.com/torvalds/linux/blob/master/drivers/platform/x86/lenovo/thinkpad_acpi.c), [ideapad-laptop](https://github.com/torvalds/linux/blob/master/drivers/platform/x86/lenovo/ideapad-laptop.c), [LenovoLegionLinux](https://github.com/johnfanv2/LenovoLegionLinux), [LenovoLegionToolkit](https://github.com/LenovoLegionToolkit-Team/LenovoLegionToolkit) and [OpenRGB](https://gitlab.com/CalcProgrammer1/OpenRGB).
- Optional sensors: [SMCAMDProcessor](https://github.com/trulyspinach/SMCAMDProcessor) and [SMCRadeonSensors](https://github.com/ChefKissInc/SMCRadeonSensors).
- ACPI tools: [ACPICA](https://github.com/open-acpica/acpica).

Licensed under [GPL v2.0](LICENSE).
