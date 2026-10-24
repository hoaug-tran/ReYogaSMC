# Compatibility

## Requirements

- macOS 11 or newer; controls depend on firmware and macOS API availability.
- OpenCore with the main kext and its Lilu/VirtualSMC dependencies, or the standalone Alter variant.
- Matching app and driver versions for the control protocol.
- Xcode with command-line tools for local builds.

The minimum deployment target is macOS 11. Availability checks select newer login and interface APIs where supported; there is no upper-version block. Runtime support still requires testing on the target macOS release.

## Firmware interfaces

ThinkPad charge thresholds use firmware capability/error bits and battery addressing. Start is 0–99%; stop is 1–100%. The driver checks their order and reads back accepted requests. The app offers Primary and Secondary selections when individual addressing is supported.

IdeaPad/Yoga battery controls use `GBMD`/`SBMC`. Keyboard and USB controls use their advertised ACPI interfaces. Game Zone WMI is not required for those controls.

Native sensor profiles require the DSDT signature, length, checksum and SHA-256 to match, plus the declared ACPI fields. Firmware updates or bootloader patches can invalidate a profile. WMI remains a separate backend. On the reviewed Legion 7 profile, native fan readings have 100-RPM resolution.

CPU power-limit access is disabled by default because firmware getters can initialize hardware state. `-reycpupower` enables access; firmware ranges and readback still apply. Manual fan writes require a profile that records validated write support.

## Permissions and signing

Shortcut mapping requires Accessibility and Input Monitoring. Grant access to the installed app in System Settings, then retry mapping. If macOS requests a restart, quit and reopen the app.

macOS associates privacy access with the app's signing identity. Keep the app in `/Applications` and sign subsequent builds with the same identity. CI packages are unsigned. Login registration uses the available macOS login-service API and the embedded helper.

## Installation checks

Confirm that one driver variant is loaded, the app connects and the required controls are available. Check requested settings against readback, sensors against another source, and sleep/wake on the target machine. A successful build does not establish firmware compatibility.
