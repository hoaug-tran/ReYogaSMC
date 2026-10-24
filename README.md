<div align="center">

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="Assets/Brand/readme-dark.svg">
  <img src="Assets/Brand/readme-light.svg" alt="ReYogaSMC" width="720">
</picture>

[![Build](https://github.com/hoaug-tran/ReYogaSMC/actions/workflows/main.yml/badge.svg?branch=main)](https://github.com/hoaug-tran/ReYogaSMC/actions/workflows/main.yml)
[![Release](https://img.shields.io/github/v/release/hoaug-tran/ReYogaSMC)](https://github.com/hoaug-tran/ReYogaSMC/releases/latest)
[![License](https://img.shields.io/badge/license-GPL--2.0-blue)](LICENSE)

Lenovo hardware controls for macOS.

[Download](https://github.com/hoaug-tran/ReYogaSMC/releases/latest) · [Actions builds](https://github.com/hoaug-tran/ReYogaSMC/actions/workflows/main.yml) · [Device information](#device-information)

</div>

## Features

ReYogaSMC includes a kernel extension, menu bar app and hardware support tool. Controls depend on the interfaces exposed by the machine's firmware.

| Interface | Features |
| :--- | :--- |
| ThinkPad ACPI | Fn hotkeys, Fn Lock, keyboard backlight, battery charge thresholds, DYTC power profiles and available EC sensors |
| IdeaPad / Yoga ACPI | Conservation mode, rapid charge, keyboard backlight, Fn Lock and Always-On USB |
| Legion WMI | Power profiles, temperatures, fan telemetry, display overdrive and supported lighting controls |
| ITE c968 USB RGB | Profile-specific keyboard and lighting zones |
| Intel HID / HP | Experimental event and sensor support |

The app shows each control's availability and its firmware response. Sensor access does not enable manual fan writes. Native ACPI telemetry uses exact firmware fingerprints from [HardwareProfiles](HardwareProfiles); unknown firmware does not inherit another machine's EC layout.

## Download and install

[GitHub Releases](https://github.com/hoaug-tran/ReYogaSMC/releases) contains Release and Debug ZIPs for the kexts, app and support tool. Use Release for installation. Actions builds are available under a successful run's **Artifacts** section; downloading artifacts requires a GitHub account.

| Package | Contents |
| :--- | :--- |
| `ReYogaSMC-kexts-*` | Main and Alter kexts, optional SSDT examples |
| `ReYogaSMC-apps-*` | Menu bar app with embedded login helper |
| `ReYogaSMC-tool-*` | Windows/macOS launchers, collection scripts and firmware profiles |

1. Load [Lilu](https://github.com/acidanthera/Lilu/releases) and [VirtualSMC](https://github.com/acidanthera/VirtualSMC/releases) before `ReYogaSMC.kext` in OpenCore.
2. Replace the old driver and update its `BundlePath` and `ExecutablePath`. Load one primary or Alter variant.
3. Copy `ReYogaSMCNC.app` to `/Applications`, restart macOS and open the app.
4. Check the driver connection and available controls before changing settings.

> [!IMPORTANT]
> CI packages are unsigned. Keep a bootable recovery configuration when replacing a kext. `ReYogaSMCAlter.kext` omits VirtualSMC integration and does not require Lilu or VirtualSMC.

A custom SSDT is optional. Standard ACPI/WMI interfaces and matching native sensor profiles work without one. Add a generated bridge only for its matching firmware.

## App

**Device** contains sensors, keyboard, battery, lighting and USB controls. **Cooling & Power** contains power profiles and the available fan/CPU controls. A control remains unavailable when its backend or required validation is missing.

Settings includes login, release updates, shortcut mapping and device information export. Updates are downloaded and installed manually. Hotkey mapping requires Accessibility and Input Monitoring; sensor display does not. Preferences from YogaSMC are imported on first launch.

## Device information

1. Open **Settings → Diagnostics** in the ReYogaSMC app.
2. Click **Export Report…** to save hardware state, driver capabilities, recent app logs and `DSDT.aml` when the driver supports ACPI export. Firmware does not need a matching profile for this export.
3. Attach the ZIP to a [device-support issue](https://github.com/hoaug-tran/ReYogaSMC/issues/new/choose), with the model, BIOS version, macOS version and affected feature.

> [!NOTE]
> Exports stay local until you share them. Review them first: firmware tables and device identifiers may contain identifying information.

On Windows, run `ReYoga.cmd` from the support-tool package. On macOS, run `ReYoga.command`. Python 3.9 or newer is required. Options and export contents are listed in the [hardware tool guide](Docs/hardware-tool.md).

## Build

Select Xcode and install its command-line tools:

```sh
bash Scripts/bootstrap.sh
xcodebuild -project ReYogaSMC.xcodeproj -target BuildAll -configuration Debug CODE_SIGNING_ALLOWED=NO
xcodebuild -project ReYogaSMC.xcodeproj -target BuildAll -configuration Release CODE_SIGNING_ALLOWED=NO
bash Scripts/package.sh Release
```

Dependency versions and checksums are pinned in `Scripts/dependencies.json`. Products go to `build/Debug` and `build/Release`; ZIPs go to `build/packages`.

The [Actions workflow](https://github.com/hoaug-tran/ReYogaSMC/actions/workflows/main.yml) tests the support tool on Windows, Linux and macOS, builds both configurations and publishes their packages. Versioned releases use the corresponding section of [Changelog.md](Changelog.md). See [Contributing](CONTRIBUTING.md) for the release policy and checks.

For a persistent app signing identity:

```sh
bash Scripts/sign-app.sh 'Developer ID Application: name (TEAM)' build/Release
```

Signing does not notarize the app. Keep the same identity and installation path when updating. Platform requirements are listed in [Compatibility](Docs/compatibility.md).

## Credits and license

Based on [YogaSMC by Zhen](https://github.com/zhen-zen/YogaSMC). Distributed under [GPL v2](LICENSE); original copyright and license notices are retained.

Protocol references include Linux [thinkpad-acpi](https://github.com/torvalds/linux/blob/master/drivers/platform/x86/lenovo/thinkpad_acpi.c) and [ideapad-laptop](https://github.com/torvalds/linux/blob/master/drivers/platform/x86/lenovo/ideapad-laptop.c), [LenovoLegionLinux](https://github.com/johnfanv2/LenovoLegionLinux), [LenovoLegionToolkit](https://github.com/BartoszCichecki/LenovoLegionToolkit) and [OpenRGB](https://gitlab.com/CalcProgrammer1/OpenRGB). Dependencies are maintained by [Acidanthera](https://github.com/acidanthera). The support tool uses [ACPICA](https://github.com/open-acpica/acpica).
