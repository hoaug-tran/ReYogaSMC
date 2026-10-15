# Differential diagnosis

| Candidate | Evidence and prediction | Cheapest separating check | Status |
|---|---|---|---|
| Early ACPI/EC/WMI access | `IdeaVPC::start` reaches virtual `updateAll`; WMI examination triggers another full update and starts 500 ms telemetry. User's macOS log now confirms safe-mode initialization and `VPC service published (safe=1)`, and the user reached the desktop. | Split legacy ACPI, WMI and bridge paths with diagnostic flags | leading group narrowed; exact failing call unverified |
| Kext/dependency or personality failure | If causal, safe mode still fails before/while the service attaches. | Compare verbose/panic logs with kext disabled and with `-reysafe` | rival, unverified |
| SSDT bridge namespace or SystemMemory mapping | If causal, removing only SSDT-ReYoga while retaining the safe kext changes the outcome, or panic names ACPI/bridge methods. | A/B SSDT with safe mode and inspect panic | rival, unverified |

The present patch adds a model-independent isolation switch. It does not claim the hardware root cause is proven without a target-machine boot and panic evidence.

## Windows evidence, 2026-10-15

Host: LENOVO 82N6, BIOS GKCN65WW, EC 1.65. DSDT SHA-256 is `2aee605fef946088d900a5bc54db3dad8777894fa26bd1f6cc3a96d77e70d1f5`, already reviewed by the shipped profile. Original tables and local inventory are under `build/legion-windows-20261015`; elevated live getters are in `build/legion-windows-admin.json`. These raw exports are excluded from Git.

| Interface | Observed value | Implication |
|---|---|---|
| Game Zone version / Smart Fan mode | 13 / 3 | Mode 3 is currently active; it is a sample, not a default |
| Legacy Game Zone fan count/speed/max | Invalid object | Advertising a WMI method does not prove it works |
| LENOVO_FAN_TABLE_DATA | Two instances | Use runtime instance count rather than assuming two fans |
| Fan method RPM / sensor temperature | 3000, 3000 RPM / CPU 80, GPU 57 C | Native fan backend works; legacy temperature getters returned zero |
| Short-term CPU power | current 88, min 10, max 88, step 1 W | Bounds come from firmware, not a model constant |
| Long-term CPU power | current 70, min 10, max 70, step 1 W | Bounds come from firmware, not a model constant |
| Fan cooling capability / full-speed state | 0 / false | Getter availability alone must not enable the setter |
| Logo lighting record 3 | interface 0, type 1 | RGB backend; binary WMI state control unavailable |
| Port lighting record 5 | interface 1, type 0, two states; state 1 | WMI state control advertised and currently on |
| Display overdrive | capability 1, state 1 | Advertised and currently enabled |
| Win-key / touchpad lock | capability 1 / 1, state 0 / 0 | Advertised and currently unlocked |
| GetSmartFanSetting / GetPowerChargeMode | WmiMethodId 46 / 47 | Correct shared ABI constants to 0x2E / 0x2F |

DSDT confirms battery masks 0x20 / 0x04 and SBMC command pairs 3/5 and 7/8. No change to those values is justified. It also confirms WMB3 power-limit getters initialize CPP1/CPP2 in SystemMemory when zero, and recalculate CPP4 before dispatch; these getters are not side-effect-free. This strengthens the early-firmware-access hypothesis but does not identify the actual macOS panic site.

The pasted CI log identifies a separate, confirmed compiler failure: `checkKernelArgument` is undeclared in the Alter target. Use `PE_parse_boot_argn` with its explicit pexpert header. Safe mode must also reject the sensor plugin, standalone WMI and DYVPC matching, and acknowledge PM callbacks without restarting hardware access.

## Safe-boot evidence and next patch

[verified — supplied macOS boot log] At 3.907054 s IdeaVPC skips ACPI/EC initialization; at 3.907071 s it publishes with safe=1. Matching and the passive service work in this configuration. This does not validate firmware methods or exclude a parser defect reached only outside safe mode. The same log has XHCS namespace lookup failures in USB `_STA`; attribution to this boot-loop is unproven.

[verified — code and reviewed DSDT] `updateFeatureStatus` previously queried the two CPU power ranges, then queried them again to advertise reset. Firmware getters can initialize SystemMemory fields, so automatic capability refresh was not passive. CPU power access now requires explicit `-reycpupower`, enforced by both low-level getter/setter and feature availability; reset reuses the two range results. This removes a confirmed unsafe implicit-probing design, not a proven exclusive cause of the boot-loop.

Added model-independent `-reynowmi` across IdeaVPC, standalone WMI and DYVPC; `-reynobridge` skips IdeaVPC RYxx discovery and dependent paths. `-reytrace` brackets WMI calls and VPC refresh/telemetry groups. Initialization logs bracket EC readiness, base VPC, _CFG, capabilities, EC sensor validation and BMF parsing. These are diagnostics, not a timeout: a firmware call can still hang inside Apple's ACPI evaluator.

Local validation: 24 Python tests (including five source-level safety regressions), syntax checks of six affected C++ translation units in both main and Alter variants, and whitespace validation pass. These checks do not prove macOS runtime safety.
