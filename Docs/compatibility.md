# Compatibility

## Requirements

- macOS 11 or newer, OpenCore, Lilu and VirtualSMC.
- Matching ReYogaSMC app and kext versions.
- Firmware interfaces for the requested feature. The deployment target does not establish runtime support on every macOS release.

## ThinkPad

ThinkPad uses HKEY methods and the EC interface, without IdeaPad/Legion JSON profiles. Battery thresholds, hotkeys, backlight, thermal profiles and fan access are checked separately.

Charge thresholds use firmware capability/error bits and battery addressing. Start is 0–99%; stop is 1–100%. The driver checks ordering and reads back accepted requests. Secondary-battery selection requires individual addressing support.

DYTC status polling is read-only. PSC uses Quiet/Balanced/Performance levels 3/5/7 before revision 9 and 1/3/4 from revision 9, following [thinkpad_acpi](https://github.com/torvalds/linux/blob/master/drivers/platform/x86/lenovo/thinkpad_acpi.c). Older MMC firmware can hide the active profile behind lap mode; the selector then reports unavailable. Some X1 Carbon Gen 6 firmware rejects Quiet.

The T490 BIOS 1.85 DSDT confirms the PSC interface and SET-triggered `0x6032` notifications addressed by the fix. Thermal modes, Bluetooth, login registration, performance and sleep/wake still require testing with the updated build on that machine. A graphics panic is not declared fixed by removing the notification feedback path.

Fan control requires the correct EC read/write methods. Transactions restore the second-fan selector and verify requested levels. Failed selector restoration disables further access until reboot. Modified fans are returned to automatic mode when possible on sleep, client close or driver stop. Fan stop requires the app preference and `-reyfanstop`.

## IdeaPad, Yoga, Legion and LOQ

Generic battery, keyboard and USB controls use advertised ACPI methods; Game Zone WMI is not required for those controls. Conservation mode uses a firmware-defined charge target, not a universal percentage.

Native sensor profiles require a valid Lenovo DSDT and a unique machine-type or declared PCI subsystem match together with the OEM table ID. An available BIOS family must agree. Preserved OEM properties and Lenovo SMBIOS records supply identity; spoofed Apple records are excluded. Contradictory or ambiguous evidence disables model-specific access. An OEM table ID or similarly named EC fields alone cannot identify a model.

`ProfileMatchState=identity_matched`, `pci_matched` or `exact` can supply a display name. `exact` additionally requires a reviewed AML fingerprint. None certifies every firmware version or grants write permission. Each sensor is checked independently for transport failure, overflow and invalid values, with per-sensor WMI fallback.

Raw-offset bridge generation requires a unique reviewed source or AML fingerprint and complete bridge data. Installed bridges must match reviewed AML identity. Manual fan writes require separate hardware validation; all current ACPI profiles leave them disabled. A BIOS update or ACPI patch can invalidate a fingerprint. Never reuse another model's offsets merely to obtain a match.

CPU power-limit access is disabled by default because even firmware getters can initialize hardware state. `-reycpupower` enables it; range, step and readback checks still apply. If the thermal profile changes after an edit, saved limits remain associated with the modified profile. Return to that profile to restore them; another profile does not receive its limits.

## HP sensors

HP WMI supports the old and new numeric-sensor package layouts, decimal modifiers, Celsius/Fahrenheit/Kelvin temperatures and RPM readings. The formats are described in [hp-wmi-sensors](https://github.com/torvalds/linux/blob/master/drivers/hwmon/hp-wmi-sensors.c).

Only mapped sensor names are exported. Duplicate aliases cannot create duplicate SMC keys, and fan indices are consecutive. Fault states, changed sensor types, malformed records, unknown units and rate-based values are unavailable. Buffer-encoded WMI strings and the separate Elite x2 brightness interface are not implemented. These interfaces do not establish support for every HP model or EC layout.

## Readings and unavailable controls

The app prefers valid SMC temperatures and falls back to firmware. Fractional readings are preserved and shown with one decimal. Whole-degree firmware values appear as `55.0 °C`; formatting does not add sensor precision. Failed fan reads are unavailable, while a valid stopped fan remains zero RPM.

The visible dashboard refreshes every 500 ms. IdeaVPC feature state and background ThinkPad firmware state normally refresh every two seconds. Stale snapshots disable firmware controls. Missing current values, ranges or fan steps are not replaced with assumed limits.

If the kext is missing, in safe mode or lacks a compatible control interface, independent battery, SMC and supported USB RGB access remains available. Multiple matching RGB controllers disable control rather than selecting one arbitrarily. Reconnection clears pending requests and rejects results from the previous connection.

An unavailable control is not enabled by adding another laptop's profile. Export diagnostics with the model, BIOS, macOS, installed versions, requested value and observed result.

## Permissions and signing

Shortcut mapping requires Accessibility and Input Monitoring. Bluetooth actions may require Bluetooth approval. Grant access to the installed app in System Settings and reopen it if macOS requests a restart.

Keep the app in `/Applications`. CI and local scripts ad-hoc sign the app, helper and embedded libraries; kexts remain unsigned. Replacing an ad-hoc build may require privacy approval again. Use the same signing identity for subsequent builds when available. Signing alone does not establish successful login registration on every macOS release.

On macOS 13 and newer, Start with macOS uses `SMAppService.mainApp` and may require approval in Login Items. macOS 11/12 uses the embedded helper, which opens the app and exits. It neither installs nor loads a kext.

## Verification and recovery

Check controls and readback on AC and battery, sleep/wake and restoration after closing the app. Do not retry a command that caused shutdown or loss of cooling. An AML call hanging inside firmware cannot be cancelled by a user-space timeout. Keep a recovery EFI and use `-reysafe`, `-reynowmi` or `-reynobridge` to isolate the affected interface.

Portable C++ tests cover profile selection, SMBIOS parsing, sensor bounds and fan transactions with injected failures. Swift tests cover support adapters and sensor decoding. Python tests cover profiles, tools, localization and packaging. ACPI samples compile in CI. Builds and fixture rendering verify integration; they do not replace booted hardware tests.

`-reytrace` logs firmware calls, capped at 128 calls per WMI instance and four initial IdeaVPC refreshes/samples. Remove it after diagnosis. The app's Detailed logging setting controls additional samples; Debug builds also emit periodic telemetry summaries. Exported register keys and protocol values remain unchanged by UI translation.
