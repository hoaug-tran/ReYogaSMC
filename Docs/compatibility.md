# Compatibility

## Requirements

- macOS 11 or newer; controls depend on firmware and macOS API availability.
- OpenCore with the ReYogaSMC kext and its Lilu/VirtualSMC dependencies.
- Matching app and driver versions for the control protocol.
- Xcode with command-line tools for local builds.

The minimum deployment target is macOS 11. Availability checks select newer login and interface APIs where supported; there is no upper-version block. Runtime support still requires testing on the target macOS release.

## Firmware interfaces

ThinkPad charge thresholds use firmware capability/error bits and battery addressing. Start is 0–99%; stop is 1–100%. The driver checks their order and reads back accepted requests. The app offers Primary and Secondary selections when individual addressing is supported.

IdeaPad/Yoga battery controls use `GBMD`/`SBMC`. Keyboard and USB controls use their advertised ACPI interfaces. Game Zone WMI is not required for those controls.

Display identity and firmware access are separate. The app resolves declared machine types and verified PCI subsystem mappings to a model name. Shared USB controller IDs do not identify a laptop. Missing Lenovo model data displays `Lenovo Laptop`; absent Lenovo evidence displays `Unknown Laptop`. Conflicting model evidence does not select the first candidate.

The kernel validates the DSDT header, length, checksum and Lenovo OEM vendor, then selects a distinct profile ID using a unique original machine type or declared PCI subsystem ID together with the OEM table ID. An available BIOS family must agree; a reviewed AML fingerprint is optional for model recognition. Preserved platform/OEM properties and bounded Lenovo SMBIOS records supply identity; spoofed Apple SMBIOS records are excluded. Matching fingerprints cannot override contradictory identity. Different machine/BIOS rows belonging to the same profile are counted once. OEM ID `CB-01` and the existence of similarly named EC fields are never sufficient to identify a model.

`ProfileMatchState=identity_matched` identifies a declared machine type and `pci_matched` identifies a declared PCI subsystem; it does not certify every firmware version or a write operation. Named native telemetry reads are checked individually for transport failure, multiplication overflow, invalid temperatures and fan sentinels. A stopped fan is valid at zero RPM; an unavailable or powered-off temperature sensor is not reported as zero Celsius. WMI is tried independently per failed sensor. `ProfileMatchState=exact` requires a reviewed AML fingerprint. All three states can supply the display name, while write eligibility remains separate.

Raw-offset SSDT generation requires a unique reviewed source or AML fingerprint and complete bridge data. Source fingerprints preserve quoted string contents. No source-pattern-only or OEM-ID-only fallback is allowed. Installed bridges also require the reviewed AML identity to agree with their declared profile. A fingerprint match does not validate writes: manual fan writes additionally require an explicitly hardware-validated write profile. A BIOS update or ACPI patch can invalidate the fingerprint; export diagnostics rather than reusing offsets from a similar model.

CPU power-limit access is disabled by default because firmware getters can initialize hardware state. `-reycpupower` enables access; firmware ranges and readback still apply. Manual fan writes require a profile that records validated write support.

## Permissions and signing

Shortcut mapping requires Accessibility and Input Monitoring. Grant access to the installed app in System Settings, then retry mapping. If macOS requests a restart, quit and reopen the app.

macOS associates privacy access with the app's signing identity. Keep the app in `/Applications` and sign subsequent builds with the same identity. CI packages are unsigned. Login registration uses the available macOS login-service API and the embedded helper.

## Installation checks

Confirm that one driver variant is loaded, the app connects and the required controls are available. Check requested settings against readback, sensors against another source, and sleep/wake on the target machine. A successful build does not establish firmware compatibility.


## Unsupported hardware and failure behavior

| Condition | Behavior |
| --- | --- |
| No matching machine/BIOS profile, missing original identity, or an unsupported BIOS family | No model-specific bridge access. Independently advertised ACPI/WMI controls and available SMC sensors remain usable. The diagnostic stage explains what is missing. |
| Identity sources disagree, or different profiles match | Model-specific access is disabled. No first-match selection or forced profile. |
| Missing second fan, powered-off GPU, invalid sample, or a failed getter | Only that reading becomes unavailable; other sensors and the model identity remain intact. SMC adapters clear failed readings instead of keeping old values. |
| Kext absent, unsupported control personality, incompatible protocol, or safe mode | The dashboard remains accessible with a recovery notice. Firmware controls are unavailable; native battery, SMC and supported USB RGB access do not require a VPC connection. |
| Driver terminates or reconnects during an asynchronous request | Connection generations reject obsolete results. Pending controls, stale ranges and firmware state are cleared. USB RGB remains independent. |
| Multiple matching RGB controllers | Control is disabled until the additional controllers are disconnected; discovery does not choose an arbitrary device. |
| Permission denial, device busy, malformed firmware result, or allocation failure | The affected operation fails and reports its reason. Accepted commands require readback; failed writes are not retried automatically. |
| Firmware changes after preferences were saved | VPC settings use the firmware digest and profile identity as their storage scope. Unknown firmware without a stable identity does not restore saved controls. |
| Sleep, client close/crash, or driver stop after ThinkPad fan edits | The driver attempts to return modified fans to automatic mode. Selector writes, reads and restoration run as one serialized transaction. Failed selector restoration disables further fan access. |
| CPU power profile changes outside the app after an edit | Original limits are retained for the modified profile. Further power-limit edits are blocked in other profiles; return to the modified profile to restore them. The driver never applies one profile's saved limits to another. |

The legacy raw EC write selector and arbitrary VPC write property are unsupported. ThinkPad fan control uses the appended atomic fan selector (`ThinkFanProtocolVersion=1`); existing read selector numbers are preserved. Fan stop requires both the app preference and the explicit `-reyfanstop` boot argument. CPU power access remains opt-in with `-reycpupower`.

An AML call that hangs inside firmware cannot be made safe by a user-space timeout. `-reysafe`, WMI/bridge isolation flags and unavailable-control behavior provide recovery paths; firmware operations and restoration still need real-hardware tests. A successful build or mocked transaction test does not establish support for every Lenovo model, BIOS revision or macOS version.

## Verification scope

Portable C++ tests execute the same profile selector, SMBIOS parser, sensor validation and fan transaction code used by the kext. They cover every declared machine/BIOS row, duplicate rows, conflicting evidence, missing identity, malformed SMBIOS records, sensor bounds, and injected transaction failures. The native test runs with AddressSanitizer and UndefinedBehaviorSanitizer on macOS/Linux. Swift support tests cover model-name fallbacks, profile fingerprints and sensor decoding; Python tests cover profile generation, schemas, collection tools and release integration. Debug/Release builds and fixture rendering verify integration, not hardware compatibility.


## Messages, language and live values

The English and Vietnamese catalogs cover UI labels, alerts, accessibility text, OSD notifications, app errors and known canonical driver reasons. Presentation translates canonical driver text; raw registry keys, protocol values and exported firmware snapshots remain unchanged. Runtime values and error codes are inserted through localized format templates. Catalog tests check key coverage, duplicate keys and format-argument parity; native support tests exercise Vietnamese messages with live-value placeholders.

Model display may use a verified PCI subsystem mapping even when the original SMBIOS identity is spoofed. This does not approve a firmware write profile. Diagnostics shows the app revision, the loaded driver's version and its firmware match state separately. The app polls visible telemetry at 500 ms; firmware feature states refresh every two seconds, with an explicit refresh fallback for older drivers. Stale snapshots disable firmware controls and do not display cached sensor values as live. Missing power ranges, fan steps or current values are not replaced with invented hardware limits.

The login helper is embedded inside the app for macOS 11/12. It opens the main app at login and exits; it neither installs nor loads a kext. macOS 13 and newer use `SMAppService.mainApp`. Copying the app includes its helper, while login registration changes only when the user changes Start with macOS. The helper uses the enclosing app's localization resources and language preference for its error dialog.

### Firmware identity and diagnostic logging

The driver selects a model profile from a unique machine-type or declared Lenovo PCI subsystem match together with the DSDT OEM table. A BIOS family, when available, must agree with that profile; a BIOS version update within the family does not require a new hash. Missing original SMBIOS information does not prevent a PCI match. Conflicting or ambiguous evidence disables model-specific access. Each native ACPI sensor is read and validated independently; identifying a profile does not authorize raw EC writes. Reviewed fingerprints remain an optional diagnostic identity source and a separate requirement for the raw-offset bridge. The overview shows detected hardware without a missing-fingerprint warning; Diagnostics reports the actual matching source.

`-reytrace` enables diagnostic firmware-call traces. Traces are limited to 128 calls per WMI instance and four initial VPC refreshes/sensor samples; start/end pairs use the same trace decision. Remove `-reytrace` for normal use. Detailed telemetry emits one sample summary per four samples (normally two seconds), or every twenty samples when disabled, in Debug builds. Release builds omit those debug summaries. Successful BMF synchronization and repeated GUID matches no longer emit per-item logs.
