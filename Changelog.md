# Releases

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
