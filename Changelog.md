# Releases

## 2.1.0

### Driver

- Gate `ReYogaSMCUserClient` external methods through the provider's `IOCommandGate`, reject calls while `-reysafe` is active, and retire the legacy `kRYSMCUCWriteEC` selector and raw `writeEC` property interface.
- Add the serialized `kRYSMCUCThinkFan` (`ThinkFanProtocolVersion = 1`) transaction path for ThinkPad dual-fan reads and level writes, with EC register `0x31` selector restoration, readback verification, automatic-mode (`0x84`) restoration on client close, sleep, or driver stop, and explicit `-reyfanstop` opt-in for zero-RPM level `0`.
- Replace single-digest native profile matching in `IdeaVPC` with `ReYogaFirmware::select` (`FirmwareIdentity.hpp`), resolving profiles from DSDT header/checksum validation, `LENOVO` OEM vendor, OEM table ID, original machine type (`OEMProduct`, `OEMBoard`, Lenovo SMBIOS Type 1, `/options` NVRAM), BIOS family (`OEMBIOSVersion`, SMBIOS Type 0), and model-specific Lenovo PCI subsystem IDs (`17aa:xxxx`), while rejecting conflicting or ambiguous identity evidence.
- Decouple model identification from sensor availability and write permission: validate each native ACPI telemetry sample (`FANS`, `FA2S`, `CPUT`, `GPUT`) individually with per-sensor WMI fallback, clear failed or out-of-range SMC sensor readings instead of retaining stale values, and require an exact reviewed AML digest match before enabling an installed `RYID` ACPI bridge.
- Pass an explicit empty `OSData` buffer as `Arg2` for 2-argument ACPI WMI `WMxx` evaluations in `WMI::evaluateMethod` so firmware methods that dereference `Arg2` on reads do not fault, bound `_WDG` descriptor parsing to 256 entries, cap `-reytrace` logging at 128 WMI calls, and silence non-fatal BMF parser warnings at boot.
- Keep `IdeaVPC` active when `_CFG` is absent by discovering individual ACPI and WMI capabilities, refresh battery, keyboard, and feature state every 4 telemetry cycles (2 seconds), verify `BDVT` conservation updates via readback before updating VirtualSMC state, remove the unimplemented `CH0B` key, and preserve modified CPU power-limit baselines across external power-profile switches until the original profile is restored.

### Hardware Profiles

- Expand the hardware profile catalog to 21 ACPI profiles (`ReYogaFirmwareProfiles.hpp`) covering IdeaPad Gaming 3 (15ARH05, 15ACH6), Legion 5 (15ARH05, 15IMH05, 15ACH6, 15ARH7), Legion 5 Pro (16ACH6H, 16IAH7H), Legion Pro 5 (16ARX8, 16IRX8, 16IRX9), Legion 7 (15IMH05, 16ITHg6, 16ACHg6, 16ARHA7), Legion Pro 7 (16IRX8H, 16IRX9), LOQ (15APH8, 15IRH8, 15AHP9), and Yoga Slim 7 (14ARE05).
- Preserve quoted string literals when computing normalized DSL source hashes in `Scripts/hardware_support.py`, and restrict raw-offset SSDT bridge generation to profiles with complete reviewed digests, required patterns, and EC offsets.

### App

- Rename the application target and bundle from `ReYogaSMCNC.app` (`ReYogaSMCNCHelper.app`) to `ReYogaSMC.app` (`ReYogaSMCHelper.app`), migrating saved preferences from previous bundle identifiers on first launch.
- Replace the 2-tab layout with a 6-section sidebar workspace (**Overview**, **Device**, **Cooling**, **Battery**, **Lighting**, **Diagnostics**) plus **Settings**, keeping independent `AppleSmartBattery`, `AppleSMC` (`SMCProcessorAMD`, `SMCProcessor`, `SMCRadeonSensors`), and ITE `c968` USB RGB features functional when the VPC kernel service is absent or in safe mode.
- Add live `AppleSmartBattery` telemetry reporting charge percentage, charging state, current/full-charge/design capacity (mAh), design capacity retention, cycle count, voltage, signed current, power draw, temperature, adapter watt rating, and battery model/serial identifiers.
- Add a typed `LocalizedKey` catalog with complete English (`en.lproj`) and Vietnamese (`vi.lproj`) localization covering UI views, OSD notifications, driver capability reasons, and diagnostic summaries.
- Embed git source revision metadata into `Info.plist` after target plist generation and report app build version, loaded kext build version, firmware match state, and active SMC temperature keys (`TC0E`, `TC0P`, `TG0D`, `TG0P`) in **Diagnostics**.

### Packaging & Tests

- Retire the duplicate `ReYogaSMCAlter.kext` build target and package `ReYogaSMC-<version>-<CONFIG>.zip` (`ReYogaSMC.kext`) alongside `ReYogaSMC-App-<version>-<CONFIG>.zip` (`ReYogaSMC.app`).
- Add host-compiled C++ unit tests (`Tests/test_firmware_identity.cpp`, `Tests/test_control_validation.py`) with AddressSanitizer/UndefinedBehaviorSanitizer coverage for SMBIOS parsing, profile selection, sensor bounds, and ThinkPad fan transactions, alongside localization parity and project structure test suites.

## 2.0.0

First ReYogaSMC release, based on YogaSMC 1.5.3.

### Driver

- Use ReYogaSMC service and bundle names while preserving the public user-client selectors.
- Add capability checks and command readback for ThinkPad keyboard, battery thresholds and DYTC power profiles.
- Expose IdeaPad/Yoga ACPI controls without requiring Game Zone WMI.
- Read native ACPI fan and temperature fields for matching firmware profiles without a custom SSDT.
- Keep sensor units, battery command mappings and writable-control validation in firmware profiles.
- Check EC ranges, firmware error bits, allocation failures and charge-threshold ordering.

### App

- Replace the preference pane with Device, Cooling & Power and Settings views.
- Connect ThinkPad services to the dashboard and launch Siri through Workspace.
- Add profile-based USB RGB controls and persistent hardware settings.
- Read CPU/GPU temperatures from available firmware and SMC providers.
- Preserve color-panel focus and control drafts across view updates.
- Use the current default audio devices after hotplug.
- Add local device information export, including DSDT when provided by the driver.
- Support keyboard navigation, VoiceOver and Reduce Motion in the controls.

### Distribution

- Provide Windows/macOS hardware-collection scripts in the source repository.
- Build separate DEBUG and RELEASE ZIPs for the main kext, Alter kext and app.
- Publish release notes from this changelog and include SHA-256 checksums.

Packages are unsigned.

## 1.5.3 — YogaSMC

Upstream release: [YogaSMC 1.5.3](https://github.com/zhen-zen/YogaSMC/releases/tag/1.5.3).
Earlier changes are listed in the [upstream releases](https://github.com/zhen-zen/YogaSMC/releases).
