# Releases

## Unreleased

- Connect ThinkPad dashboards and add keyboard, battery threshold and DYTC controls.
- Launch Siri without SystemUIServer UI scripting; preserve notification, fan menu and audio state across reconnects and device changes.
- Publish IdeaPad/Yoga controls independently of Game Zone and read reviewed native ACPI telemetry without a custom SSDT.
- Validate EC spans, battery firmware errors and threshold ordering; fix the EC debug-dump buffer overrun.
- Generate native sensor profiles from the shared firmware data.
- Keep sensor layout stable during updates and improve keyboard and VoiceOver access.
- Publish Debug and Release kext, app and tool packages with SHA-256 checksums.

Packages are unsigned.

## 2.1.1

- Keep the color panel beside the controls without dismissing the popover.
- Read CPU and GPU temperatures from installed SMC sensor providers.
- Identify Storage and Quick Charge correctly and show live battery status.

## 2.1.0

- Use ReYogaSMC source, service and bundle names, with preference migration.
- Include the L and dot icon at every app icon size.
- Keep the controls popover at a fixed size during startup and driver connection.
- Prefer firmware GPU temperatures when available.

## 2.0.6

- Separate power profiles into individual buttons.
- Remove maximum fan speed from app controls and preference restoration.

## 2.0.5

- Load battery state masks, setter commands and capability gates from firmware profiles.
- Include binary registry data in diagnostic exports.

## 2.0.0

- Add firmware profiles, a cross-platform hardware tool and local diagnostic export.
- Add USB RGB controls and persistent settings.
- Replace the preference pane with app settings.

Earlier upstream changes remain in the [original releases](https://github.com/zhen-zen/YogaSMC/releases).
