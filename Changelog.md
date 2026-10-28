# Releases

## 2.2.0

### ThinkPad fans and power profiles

- Add Custom Curve with editable temperature points, levels 1–7 and Full Speed. Require EC read/write helpers, a driver watchdog and a fresh CPU temperature.
- Put BIOS Auto, Manual, Custom Curve and Full Speed in one mode picker. Auto and Full Speed apply immediately; Manual and Custom Curve use Apply. Editing a draft leaves the running curve unchanged.
- Raise curve levels immediately. Lower levels wait for a 3°C temperature drop and 10 seconds. Request Full Speed at 95°C.
- Stop curves and request BIOS Auto on stale temperature data, sleep, disconnect and app shutdown. A driver watchdog also requests Auto when updates stop. Curves require an explicit restart after wake or reconnect.
- Share timestamped fan readings between Overview and Cooling. Reject old samples, preserve the manual slider draft and show failed readings as unavailable.
- Check fan-mode readback, preserve selector bits on dual-fan systems and keep Auto recovery available after failed manual commands. Avoid the selector on single-fan systems.
- Read the active DYTC profile through supported MMC/PSC methods when CQL or CSC hides it. Remove requested-profile cache values from firmware readback and keep lap mode unchanged while polling.
- Keep the Power Profile section visible after read errors, with a retry action. Do not enable profile changes without a valid current mode.
- Save fan drafts by firmware and fan. Make startup fan-mode restore opt-in; do not replay old global levels on an unidentified device or restart an active curve automatically.

### Controls and saved settings

- Detect secondary-battery addressing from firmware. Hide battery selection when individual addressing is unavailable.
- Keep explicit keyboard-backlight Off separate from idle timeout Off. Keypress restores idle lighting without overriding explicit Off. Accept timeouts from 0 to 3600 seconds and reject invalid saved values.
- Skip saved controls whose readback already matches, coalesce queued changes to the same control and bound the pending queue. User actions cancel pending startup restoration.
- Check current control values, power ranges, fan steps and firmware identity before enabling or restoring controls. Recheck CPU power limits at execution.
- Require matching request IDs and completed readback before reporting success or saving settings. A pending readback that never matches remains a failure.
- Keep fan controls and wake handling active when the menu icon is hidden. Reject late callbacks and new hardware work after shutdown or connection replacement.
- Separate the ThinkPad System Settings shortcut from the app controls action and add Reset to defaults for event mappings.

### ACPI and device profiles

- Add Generate ThinkPad SSDT and Verify ThinkPad SSDT in Diagnostics. Capture running ACPI tables and helper status; add only missing helpers after checking paths, signatures, checksums, method arguments and EC field layout.
- Preserve existing valid helpers and required battery patches. Reject conflicting declarations and unknown layouts. Keep generated helpers working with OpenCore `_OSI` renames.
- Export DSL, compiled AML and an analysis file. Verify the recorded AML and live fan readback after reboot; installation remains manual.
- Use an installed iasl first. If none is found, download a pinned macOS binary, check SHA-256 and keep it in the app's own directory. Never overwrite an existing compiler.
- Compile in a temporary directory and validate the new AML before replacing an output file. Preserve source, previous AML and compiler logs on failure.
- Expand the model-name catalog and parse original SMBIOS records without using serial numbers for identity. Reject conflicting model matches.
- Correct LOQ 15AHP9 matching to 83DX/NZCN. Remove IdeaPad 82EY from the Legion 5 profile and Legion Pro 7 82WQ from the Pro 5 profile. Reject machine types assigned to different model names.
- Decode bounded HP WMI UTF-16LE strings and reject malformed sensor records, invalid lengths and empty state lists.
- Require the expected HID usage when matching the ITE c968 RGB controller. Correct LED names while preserving numeric IDs and old import aliases.

### App and diagnostics

- Split app services, views, driver connections, event actions and firmware backends by responsibility. Keep dialogs and HUD formatting outside hardware services.
- Keep navigation and saved power drafts tied to stable keys instead of translated labels.
- Restore USB RGB settings only for the matching controller profile. Check imported colors and file sizes; keep unrelated firmware lighting controls available.
- Add English and Vietnamese fan, ACPI, permission and recovery messages. Preserve firmware keys, paths and register values during translation.
- Export sensor sources, timestamps, control results, curve transitions and local system logs. Redact serial numbers and platform UUIDs; limit command duration and output size.
- Separate failed update attempts from successful checks, retry after a cooldown and ignore cancelled or stopped requests.
- Clear stale Login Items errors after a successful retry on macOS 11/12. Preserve Detailed Logging settings across reconnects and stop new logging requests after shutdown.

### Driver, build and tests

- Check kernel allocations and unwind partial startup. Keep callback, workloop and user-client resources alive until their users finish; block firmware operations during teardown.
- Keep build output inside the checkout, protect unrelated files during cleaning and verify locked dependency downloads before reuse.
- Record source manifests during builds, reject changed source during packaging and include build provenance with archive checksums.
- Keep native app/kext checks on pull requests and publishing separate from validation.
- Add production-code replays for device controls, readback, restore, reconnect, shutdown, backlight, fan recovery, ACPI, Login Items and update checks. Add a device-flow runner with separate software, native-build and hardware results.
- Fix repeated support-resource copies and write generated headers with LF line endings on Windows.

## 2.1.0

### Driver

- Fix the DYTC notification feedback path on ThinkPad T490 (20N3, BIOS 1.85): reading status no longer issues SET commands that generate further `0x6032` notifications. Read current state after writes.
- Add PSC thermal profiles when firmware advertises PSC without MMC, including T490 BIOS 1.85. Use Quiet/Balanced/Performance levels 3/5/7 before DYTC revision 9 and 1/3/4 from revision 9; preserve lap mode and set PSC Balanced without resetting other thermal functions.
- Serialize ThinkPad fan transactions, restore the second-fan selector, verify accepted levels and attempt automatic-mode restoration on sleep, client close or driver stop. Fan level zero requires `-reyfanstop`.
- Restore ThinkPad hotkey state and masks after wake, serialize ACPI notifications with control requests, and check ACPI parameter allocations before issuing commands.
- Serialize user-client requests, block firmware access in safe mode and disable the legacy raw EC write interfaces.
- Match native sensor profiles using machine type or declared PCI subsystem IDs together with DSDT identity; reject conflicting matches. Keep sensor availability and write permission separate from model recognition.
- Validate ACPI sensor values independently with WMI fallback. Failed SMC readings become unavailable; a valid stopped fan remains zero RPM.
- Support both HP numeric-sensor layouts, decimal modifiers and temperature units. Reject malformed BIOS responses, duplicate sensor keys, fault states and changed sensor types; export consecutive fan indices.
- Check Lenovo WMI parameter allocations and publish EC monitor state only after firmware accepts the command. Supply all three arguments to WMI methods and bound descriptor parsing and diagnostic traces.
- Keep generic IdeaPad controls available without Game Zone WMI, verify conservation-mode changes, remove the unimplemented `CH0B` key and preserve saved CPU power limits across external profile changes.
- Restrict ThinkPad/ECRW sample namespaces to Darwin, serialize byte access and fix the missing namespace declaration in the WMIS sample.

### Hardware profiles

- Expand the catalog to 21 native ACPI profiles for Legion, LOQ, IdeaPad Gaming and Yoga Slim models. See [hardware profiles](HardwareProfiles/README.md) for matching and validation requirements.
- Preserve quoted strings in source fingerprints. Require reviewed fingerprints and complete bridge data for raw-offset SSDT generation; fan writes still require separate hardware validation.

### App

- Replace the preference pane with Overview, Device, Cooling, Battery, Lighting and Diagnostics views, plus Settings. Keep independent battery, SMC and USB RGB access available without a VPC connection.
- Rename `ReYogaSMCNC.app` and its helper to `ReYogaSMC.app` and `ReYogaSMCHelper.app`, migrating existing preferences.
- Add Bluetooth privacy usage text for the ThinkPad Fn+F10 action.
- Prefer ThinkVPC over generic HIDD during discovery, limit background ThinkPad firmware refreshes to two seconds and hide IdeaPad bridge tools on ThinkPad.
- Make speaker mute LED synchronization on wake opt-in through `ThinkMuteLEDFixup`.
- Preserve fractional CPU/GPU temperatures and display one decimal. Add live battery capacity, health, current, power, temperature and adapter readings.
- Add English/Vietnamese localization, sentence-case English labels, app/driver version details, firmware match state and local diagnostic export.

### Packaging and tests

- Read and write support-tool text as UTF-8 on every platform, including Windows localization checks. Run all platform tests before building and publishing; a failed test no longer cancels the other test platforms.

- Remove the Alter target and package the kext and app separately in Debug and Release configurations.
- Share signing between local builds, packaging and CI. Sign nested libraries and the helper before the app, verify signatures before UI rendering, and reject mixed package versions.
- Add portable C++ tests with address/undefined-behavior sanitizers, Swift support tests, profile/localization checks and ACPI sample compilation in CI.

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
- Distribute unsigned packages.

## 1.5.3 - YogaSMC

Upstream release: [YogaSMC 1.5.3](https://github.com/zhen-zen/YogaSMC/releases/tag/1.5.3).
Earlier changes are listed in the [upstream releases](https://github.com/zhen-zen/YogaSMC/releases).
