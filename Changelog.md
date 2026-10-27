# Releases

## 2.1.1

### ThinkPad fan control

- Add Custom Curve for ThinkPads with the fan-control protocol, EC read/write access, a driver watchdog and a fresh CPU temperature. Availability is checked per interface and fan, rather than by model name.
- Choose BIOS Auto, a fixed manual level or a temperature curve in Cooling. A curve can request levels 1-7 or Full Speed; manual Apply stays disabled while it runs. Full Speed remains a separate firmware mode, not a promised RPM.
- Apply higher curve levels immediately. Lower levels wait for a 3°C temperature drop and 10 seconds to avoid repeated speed changes. The curve requests Full Speed at 95°C and stops if temperature data becomes invalid or stops arriving.
- Run periodic curve commands off the main thread. Ignore late results after changing modes or reconnecting the driver. Save curve points per firmware and fan without saving an active curve as a manual startup level.
- Request BIOS Auto when a curve stops, the app quits, the connection closes or the system sleeps. Independent watchdogs request Auto if curve updates stop and retry failed restoration while the driver remains loaded. Curves require an explicit restart after sleep or reconnecting.
- Keep Auto, Full Speed and manual levels distinct throughout app and driver commands. Check the returned control mode before accepting a change, and leave Auto recovery available after a failed manual command.
- Decode fan RPM as a little-endian value. Treat `0xFFFF` as unavailable, rather than zero RPM, without rejecting an otherwise accepted control command. Use the native `HSPD` reading when the raw EC interface is unavailable.
- Share timestamped RPM and mode readings between Overview and Cooling. Refresh visible readings every 500 ms, reject samples older than a control command and expire readings after three seconds. Keep the manual slider where the user placed it until Apply is pressed.
- Avoid accessing the second-fan selector on single-fan systems. On supported dual-fan systems, preserve unrelated selector bits, check selector changes and keep failed restoration pending for an Auto recovery attempt.

### Power profiles, battery and shortcuts

- Select the advertised MMC thermal interface before PSC when both are present. Retain profile support after a firmware error so switching can be retried.
- Read the active MMC/PSC state instead of assuming the requested profile was accepted. Ignore the CQL bit when decoding the mode, and report unavailable when firmware does not expose a valid active profile.
- Read profiles hidden by lap mode through the available MMC/PSC state without disabling lap mode. Balanced disables the selected thermal function without resetting unrelated thermal functions.
- Keep the Power Profile section visible when the current mode cannot be read. Show firmware errors and provide a refresh/retry action.
- Detect secondary-battery addressing from the firmware response. Hide battery selection on single-battery systems and use the primary battery when individual selection is unavailable.
- Make the ThinkPad settings shortcut toggle the ReYogaSMC controls window. Keep a separate System Settings action, migrate the old default mapping and add Reset to defaults for shortcuts.
- Show why direct CPU power-limit controls are unavailable on ThinkPad instead of presenting them as supported thermal-profile controls.

### ACPI and hardware identity

- Add Generate ThinkPad SSDT and Verify ThinkPad SSDT to Diagnostics. Generation requires a matching driver and local `iasl`; it does not install files into OpenCore.
- Capture the running DSDT and SSDTs with their table hashes and live EC/HKEY helper status. Check table signatures, lengths and checksums, and disassemble each table with the others available for external references.
- Check EC/HKEY paths, the real EC's `PNP0C09` identity, helper argument counts and existing declarations. Preserve valid helpers and add only those missing. Reject conflicting objects or helper definitions that are present in a table but inactive in the running namespace.
- Before adding raw EC helpers, compare native `HFSP` and `HSPD` field widths and offsets with the layout reported by the driver. Unknown, dynamic or mismatched layouts require firmware review; sensor addresses are not inferred from another model.
- Keep helper declarations available when OpenCore renames `_OSI` to `XOSI`. Keep firmware OS flags conditional, and avoid redefining existing methods.
- Export DSL, compiled AML and an analysis file with source locations, layout checks and compiler output. After reboot, verify the recorded AML, helper availability, EC write capability and fresh fan readback.
- Refuse an arbitrary EC selection when a fallback search finds multiple matching devices.
- Expand the laptop-name catalog and read original model/BIOS strings from SMBIOS tables. Exclude serial numbers from model detection, reject conflicting identity matches and keep generic laptop names when no match is available.

### App and diagnostics

- Keep saved USB RGB settings from blocking unrelated firmware lighting controls. Restore colors only for the matching RGB profile, validate imported color data and bound saved/imported JSON sizes.
- Include driver properties, sensor timestamps, CPU/GPU temperature sources, command results and curve transitions in diagnostics. Record transport errors, failed readback and pending Auto recovery separately.
- Add local macOS system, loaded-kext and kernel-log collection, with an administrator-approved CPU power/thermal sample. Preserve individual command failures and keep unprivileged output if authorization is cancelled.
- Redact serial numbers and platform UUIDs in nested diagnostic data. Limit collected output and command duration; keep reports local until the user chooses to share them.
- Explain whether fan control is blocked by missing EC helpers, an old driver, Safe Mode or a recovery error. Link missing-helper guidance to Diagnostics and keep the reason for a stopped curve visible after Auto recovers.
- Complete English and Vietnamese fan-control, ACPI and recovery messages. Keep firmware paths, register values and protocol keys unchanged by translation.

### Build and packaging

- Keep DerivedData and intermediates inside each build directory by default. Normal builds preserve existing output; cleaning removes known build products without following symlinks into external directories or deleting unrelated user files.
- Include localization-only changes in release detection. Use archive filenames in `SHA256SUMS.txt` so checksums can be verified after downloading release assets into one directory.
- Build pull requests with Xcode and check the support adapters alongside app/kext builds. Validate packaged versions before publishing.

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
