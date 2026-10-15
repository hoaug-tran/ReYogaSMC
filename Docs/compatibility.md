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
