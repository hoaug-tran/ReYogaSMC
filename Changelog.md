# Releases

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

- Include Windows/macOS hardware-collection launchers and firmware profiles.
- Build Debug and Release kext, app and support-tool ZIPs in GitHub Actions.
- Publish release notes from this changelog and include SHA-256 checksums.

Packages are unsigned.

## 1.5.3 — YogaSMC

Upstream release: [YogaSMC 1.5.3](https://github.com/zhen-zen/YogaSMC/releases/tag/1.5.3).
Earlier changes are listed in the [upstream releases](https://github.com/zhen-zen/YogaSMC/releases).
