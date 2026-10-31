# Compatibility

ReYogaSMC supports firmware interfaces, not every feature on every laptop. Check Diagnostics for the driver, sensor sources and reasons for unavailable controls.

## ThinkPad

ThinkPad uses HKEY and EC methods. It does not need a Lenovo JSON profile for hotkeys, backlight, charge thresholds or supported DYTC power profiles.

| Feature | Requirements and limits |
| --- | --- |
| Charge thresholds | Start: 0-99%; stop: 1-100%. Firmware must support the operation and accept the ordering. |
| Battery selection | Shown only when firmware supports individual battery addressing. |
| Power profiles | A supported DYTC MMC/PSC interface and a readable current mode. Polling preserves lap mode. |
| Fan RPM | A supported EC/helper or native fan-reading method. Failed readings show unavailable. |
| Manual/Full Speed | ThinkPad fan protocol and EC read/write access. Requests must pass mode readback. |
| Custom Curve | Manual control requirements, a driver watchdog and fresh CPU temperature. Other fan backends do not use this curve engine. |

The driver never substitutes a previously requested profile for a missing firmware reading. CQL/CSC states use available read methods; if those methods fail, the current mode stays unavailable.

Fan level 0 requires both the app's fan-stop preference and `-reyfanstop`. BIOS Auto and Full Speed are separate firmware modes. Full Speed does not promise a specific RPM.

Curves request Auto when data becomes stale, the app closes, the driver disconnects or the system sleeps. A watchdog requests Auto when updates stop. Failed restoration remains an error. Curves require an explicit restart after wake/reconnect. Saved startup fan modes are opt-in and tied to the firmware identity.

## IdeaPad, Yoga, Legion and LOQ

Generic battery, keyboard and USB controls use available ACPI methods. Game Zone WMI is not required for these controls. Conservation mode uses the firmware's charge target; the percentage varies by model.

Native ACPI sensors use the [profile catalog](../HardwareProfiles/README.md). Matching requires a valid Lenovo DSDT, OEM table ID and a unique machine-type or declared PCI subsystem match. A reported BIOS family must agree. Conflicting identities disable model-specific access.

Each sensor is checked separately. Failed native reads may use a supported WMI source. A model match does not enable raw-offset writes. Bridge generation needs a reviewed firmware fingerprint and complete bridge data; manual fan writes need separate write/recovery validation. Current ACPI profiles keep those writes disabled.

Legion Game Zone controls vary by firmware:
- **Full Speed mode**: Older models (e.g. Y540, Y740) support `NCMD(0x59, 0x70)` and report non-zero fan cooling capability. On modern revisions (such as Legion 7 16ACHg6 with GKCN BIOS, for example), Lenovo dropped this command from the EC firmware and reports capability `0x0C` as `0`. ReYogaSMC verifies capability `0x0C` and only exposes Full Speed when supported by firmware.
- **Dual-sensor thermal cooling on macOS**: On laptops with shared thermal architecture (heatpipes or unified vapor chamber), the EC regulates fan speed based on both CPU and GPU temperatures. Because the dedicated GPU is disabled on macOS (e.g. via `SSDT-dGPU-OFF`), its temperature sensor stays cold. The firmware's internal thermal table keeps the GPU fan around idle/low speed (~2500-2700 RPM) and acoustic limits cap the CPU fan around ~3000-3500 RPM. Because only one side of the cooling assembly actively exhausts air under single-chip load, CPU temperatures naturally sit higher than under Windows where both fans spin up together.
- **Manual fan curves**: Raw writes into the EC internal memory tables are intentionally disabled. Direct EC RAM modifications on Legion hardware risk immediate power-offs and thermal lockups.
- **CPU power access**: Disabled by default, including getters. `-reycpupower` enables supported requests; range, step and readback checks still apply. Saved limits stay associated with the power profile that was edited.

## HP and Intel HID

HP WMI exports mapped numeric sensors and supported events. It handles legacy/modern sensor packages, decimal modifiers, Celsius/Fahrenheit/Kelvin temperatures, RPM and length-prefixed UTF-16LE strings. Invalid lengths, encodings, state lists, sensor types and units are rejected.

Only mapped sensor names are exported. This does not cover every HP model. The separate Elite x2 brightness interface is not implemented. Intel HID support is limited to the events handled by the driver.

## Temperatures and lighting

The app prefers valid AppleSMC temperatures and falls back to driver firmware readings. Common optional providers are:

| Hardware | Optional provider |
| --- | --- |
| AMD Ryzen CPU | [SMCProcessorAMD](https://github.com/trulyspinach/SMCAMDProcessor) |
| Intel CPU | [SMCProcessor](https://github.com/acidanthera/VirtualSMC) |
| Supported AMD GPU | [SMCRadeonSensors](https://github.com/ChefKissInc/SMCRadeonSensors) |

An iGPU does not always expose a separate GPU temperature. A failed fan read is unavailable; a valid stopped fan is zero RPM.

The ITE c968 backend requires the expected USB/HID interfaces and report sizes. Multiple matching controllers leave control unavailable. Sent RGB reports confirm USB transport, not the physical LED color. Breathing and Spectrum effects need the app to remain open.

Visible readings refresh every 500 ms. Background firmware refreshes normally run every two seconds. Stale snapshots disable firmware controls while independent battery, SMC and USB sources remain available.

## ACPI patches

Use [ThinkPad helper generation](../README.md#thinkpad-acpi-helpers) when possible. These files are examples for manual review, not universal patches.

| Sample | Purpose |
| --- | --- |
| [SSDT-ThinkPad.dsl](../ReYogaSMC/ACPIExamples/SSDT-ThinkPad.dsl) | ThinkPad EC helpers and OS compatibility declarations |
| [SSDT-ECRW.dsl](../ReYogaSMC/ACPIExamples/SSDT-ECRW.dsl) | Standalone EC byte read/write helpers |
| [SSDT-THINK.dsl](../ReYogaSMC/ACPIExamples/SSDT-THINK.dsl) | Legacy ThinkPad OS flags, LEDs and thermal fields |
| [SSDT-RCSM.dsl](../ReYogaSMC/ACPIExamples/SSDT-RCSM.dsl) | IdeaPad/Yoga lid-query switch; requires the correct renamed firmware query |
| [SSDT-WMIS.dsl](../ReYogaSMC/ACPIExamples/SSDT-WMIS.dsl) | Return a missing WMI wrapper result in the shown namespace |
| [SSDT-YVPC.dsl](../ReYogaSMC/ACPIExamples/SSDT-YVPC.dsl) | Add a VPC matching device under the reviewed EC path |

Check paths, offsets and existing methods before loading an example. Do not combine overlapping helpers or remove required battery patches to make a sample compile.

## Boot arguments

Add only the arguments needed for your setup or diagnosis.

| Argument | Effect |
| --- | --- |
| `-reysafe` | Skip ACPI/WMI hardware probes and block firmware writes |
| `-reynobridge` | Disable native profile matching and RYID bridge discovery; keep generic interfaces |
| `-reynowmi` | Disable vendor WMI probing |
| `-reycpupower` | Allow supported Legion CPU power-limit access |
| `-reyfanstop` | Allow ThinkPad manual level 0 when the app also allows fan stop |
| `-reytrace` | Log firmware call entry/exit; limited to 128 calls per WMI instance and initial IdeaVPC samples |

Remove tracing arguments after diagnosis. A user-space timeout cannot cancel an ACPI method stuck inside firmware.

For installation, permissions and error reports, see the [README](../README.md).
