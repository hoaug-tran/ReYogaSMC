# macOS compatibility

The app targets macOS 11 and has no upper-version restriction. Hardware support depends on the firmware interfaces and loaded drivers.

| Component | macOS 11–12 | macOS 13–15 | macOS 26 |
| :--- | :--- | :--- | :--- |
| Controls | SwiftUI and AppKit popover | Fixed hosting-controller size | Same controls, native glass for status messages when available |
| Start at login | Embedded helper | ServiceManagement app registration | ServiceManagement app registration |
| Hotkey mapping | Accessibility and Input Monitoring | Accessibility and Input Monitoring | Accessibility and Input Monitoring |
| Kext | OpenCore with compatible dependencies | OpenCore with compatible dependencies | OpenCore with compatible dependencies |

Settings and RGB configurations persist in the app's preferences. macOS manages privacy permissions separately; changing the bundle or signing identity can require permission to be granted again.

## Dependencies

Pinned dependency versions and SHA-256 checksums are in `Scripts/dependencies.json`. The main kext requires Lilu and VirtualSMC. The Alter variant omits VirtualSMC integration and must be loaded separately.

A compiler deployment target establishes API compatibility, not a successful hardware boot on every listed version. Device-support contributions include the model, BIOS and macOS versions used.

## Emergency safe mode

Add `-reysafe` to OpenCore `boot-args` when a Lenovo Idea-family machine stops before the login window after enabling ReYogaSMC. In this mode the `IdeaVPC` service may attach for diagnostics, but it does not enumerate vendor WMI providers, evaluate Lenovo ACPI methods, access the EC, start telemetry, or accept hardware-control requests. Its sensor plugin, standalone WMI matching and DYVPC matching are disabled as well. The switch is model-independent and intended to separate driver matching/loading failures from firmware-transport failures; ThinkVPC and ReYogaHIDD are outside this isolation mode.

If `-reysafe` boots successfully, collect the panic/OpenCore log and an IORegistry export before re-enabling hardware access. If it still fails, disable the kext entry itself: the failure is earlier than Idea-family ACPI/EC activation or belongs to another personality/dependency.

## Firmware isolation after a successful safe boot

These flags select code paths, not laptop models. A successful safe boot does not validate the paths it skips.

| Boot argument | Effect |
| :--- | :--- |
| `-reytrace` | Logs entry/return for WMI calls, VPC refresh groups and telemetry, plus initialization boundaries. Diagnostic only: it can produce substantial output and change timing. A missing return is a lead, not proof of the root cause. |
| `-reynowmi` | Disables IdeaVPC vendor WMI discovery, standalone ReYogaWMI and DYVPC matching. Legacy VPC ACPI/EC and its sensor plugin remain active; this is not safe mode. |
| `-reynobridge` | Disables IdeaVPC's optional RYxx ACPI bridge discovery, bridge telemetry and bridge controls. Native WMI/legacy ACPI remain active. Does not unload the SSDT or disable unrelated EC sensor configuration. |
| `-reycpupower` | Explicitly opts into CPU power-limit queries and controls. Disabled by default because even firmware range getters can initialize SystemMemory fields. Opt-in does not certify hardware safety. |

Keep a known-working EFI with `-reysafe` available for recovery. For a diagnostic boot of this revision, remove `-reysafe`, keep `-v keepsyms=1 debug=0x100`, and add `-reytrace -reynowmi -reynobridge`. Do not add `-reycpupower`. If that boots, remove only `-reynowmi` for the next test; if that also boots, remove only `-reynobridge`. Stop on the first failure and retain the last `Boot stage` / `Firmware begin` / `Firmware end` lines or panic report. Do not change other kexts or SSDTs between these tests. If the first test fails, the remaining legacy ACPI/EC path is still suspect; use the recorded boundary rather than enabling more interfaces.

Only treat the ordinary configuration as validated after a boot without isolation flags, plausible sensor values, individual control/readback checks, and sleep/wake. CPU-power access and manual fan writes require separate validation; neither is implied by reaching the desktop.
