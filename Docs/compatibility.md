# Compatibility and release checks

The deployment target is macOS 11. Newer APIs need an availability check and a working fallback. There is no upper-version restriction; macOS 26 still needs its own runtime validation.

| Area | Required evidence |
| :--- | :--- |
| Driver loading | Correct OpenCore paths and dependencies, one driver variant, clean boot and shutdown |
| App identity | Same installed path, bundle ID and signing requirement across launches and updates |
| Privacy | Accessibility and Input Monitoring granted/denied, relaunch, revoked permissions, retry |
| Login | Helper on 11/12; ServiceManagement registration on newer versions, enabled/disabled and relaunch |
| Firmware commands | Capability, requested value, command result, readback and visible effect |
| Cooling | Valid sensor units, automatic cooling, restore, mode transitions; no writes without reviewed evidence |
| Power | AC/battery transitions, sleep/wake and reset to saved values |
| Interface | Menu bar placement, dark/light mode, missing-driver recovery and unavailable controls |
| Export | Unknown firmware still produces a report, disassembly failures visible, private data reviewed |

The supplied Legion profile has unvalidated fan writes disabled. Do not certify it from compilation or a shared model name. Enabling writes requires model-specific hardware validation.

Release packages must distinguish signed/notarized distribution from unsigned development output. Never claim privacy persistence from a build made with `CODE_SIGNING_ALLOWED=NO`. Signing identity is controlled by the distributor; a repository cannot supply the private signing credential.

## Dependency baseline

The dependency lock uses Lilu 1.7.2 and VirtualSMC 1.3.8. Lilu 1.7.2 includes the AMDSupport lockup/panic fix for macOS 26; the preceding release enabled macOS 26 loading without a beta flag. See the [Lilu changelog](https://github.com/acidanthera/Lilu/blob/master/Changelog.md). VirtualSMC documents macOS 26 and below as enabled by default in its [README](https://github.com/acidanthera/VirtualSMC).

Those dependency capabilities do not certify ReYogaSMC's firmware controls or the companion UI. Validate the complete boot and hardware flow on the target OS. Keep graphics, audio and input-driver troubleshooting separate from a confirmed ReYoga command failure, and include those dependencies when a report involves a shared interface.
