# Lenovo Legion Custom Fan Curve Control: Technical Research & EC Specification

**Target Hardware**: Lenovo Legion 7 2021 (16ACHg6 / R9000K 2021, Machine Type 82N6, BIOS GKCN, PCI 17aa:3a58, ITE IT8227E EC) and related Legion Gen 5/6/7 models
**Date**: 2026-11-20
**Status**: Verified & Active Reference
**Project Integration**: ReYogaSMC Kernel Driver (`IdeaVPCFan.cpp`), Privilege Broker (`ReYogaSMCFanHelper`), and macOS App (`ReYogaSMCApp`)

---

## 1. Executive Summary

Custom fan curve regulation on modern Lenovo Legion laptops requires interacting directly with extended registers on the Embedded Controller (EC). Unlike ThinkPad machines that accept simple ACPI fan levels (`0x00` to `0x07`, `0x40`, `0x80`), Legion laptops feature independent dual fan blowers (Fan 1 for CPU, Fan 2 for GPU/VRAM) driven by continuous 10-point temperature-to-RPM curves loaded into EC RAM.

This document synthesizes empirical reverse engineering from the foundational utility `LegionFanControl` (by smoky) and five major open-source projects—`johnfanv2/LenovoLegionLinux`, `BartoszCichecki/LenovoLegionToolkit`, `rango886/LegionFanEmbeddedController`, `Kangarroar/Legion-Fan-Controller`, and `Rodpad/LeGo2-Fan-Control`—alongside local `HardwareProfiles/` definitions to provide an authoritative, verified specification for custom fan curve operations in ReYogaSMC.

---

## 2. Hardware Identity & EC Identification

### 2.1 Target Machine Architecture
- **Model**: Lenovo Legion 7 16ACHg6 (and Chinese domestic market counterpart R9000K 2021)
- **Machine Type**: `82N6`
- **Motherboard / Subsystem ID**: `17aa:3a58` (OEM Table ID: `CB-01`)
- **BIOS Family**: `GKCN` (e.g., GKCN46WW, GKCN50WW, GKCN54WW)
- **Embedded Controller (EC)**: ITE IT8227E-192 / IT8227E Super I/O & Keyboard Controller
- **ACPI Device Path**: `\_SB.PCI0.LPC0.EC0`

### 2.2 EC Identification Registers
The ITE IT8227 EC exposes hardcoded identification registers in its extended configuration space at offset `0x2000`:

| Register | Name | Expected Value | Description |
|---|---|---|---|
| `0x2000` | `ECHIPID1` | `0x82` | First byte of ITE Chip ID |
| `0x2001` | `ECHIPID2` | `0x27` | Second byte of ITE Chip ID (`0x8227`) |
| `0x2002` | `ECHIPVER` | `0x02` (or revision) | Silicon stepping / firmware revision byte |
| `0x2003` | `ECDEBUG` | Dynamic | Diagnostic register |

*Verification Citation*:
- `LenovoLegionLinux` (`kernel_module/legion-laptop.c:364-367, 646`): `.check_embedded_controller_id = true`, `.embedded_controller_id = 0x8227`.
- `LegionFanEmbeddedController` (`Utils.cs:181-184`): `ITE_REGISTER_MAP` defines `ECHIPID1 = 0x2000`, `ECHIPID2 = 0x2001`.
- `Legion-Fan-Controller` (`LegionEcReader.cs:282-285`): Verifies `0x82` and `0x27` prior to initiating any fan read or write transaction.

---

## 3. EC Bus Access Mechanisms

The IT8227 extended RAM can be accessed via two distinct hardware mechanisms on x86 platforms:

```
[Userspace App / Helper]
        │
   (IOUserClient)
        │
   [ReYogaSMC]
        │
   ┌────┴────────────────────────┐
   │                             │
[Method A: SystemMemory MMIO]   [Method B: Super I/O LPC Ports]
   0xFE00D400 (Size 0x600)         Port 0x4E (Index), Port 0x4F (Data)
   Mapped 1:1 to EC 0xC400         Direct hardware I/O instructions
   (Safe, race-free, ACPI)         (Host I/O port contention risks)
```

### 3.1 Method A: ACPI SystemMemory MMIO Window (Preferred)
The Legion BIOS DSDT defines a physical memory window under `\_SB.PCI0.LPC0.EC0` via `OperationRegion (ERAX, SystemMemory, 0xFE00D400, 0xFF)`.

In ReYogaSMC, this window is expanded via the reviewed SSDT overlay (`SSDT-ReYoga.template.dsl`) to `OperationRegion (RYER, SystemMemory, 0xFE00D400, 0x600)`, covering physical addresses `0xFE00D400` through `0xFE00D9FF`.

This physical range maps **1:1** to extended EC RAM base `0xC400`:
$$\text{Physical Address} = \text{0xFE00D400} + (\text{EC\_Register} - \text{0xC400})$$

**Advantages for macOS / ReYogaSMC**:
1. Completely avoids x86 `inb`/`outb` I/O port instructions that can trigger race conditions with the host OS LPC controller.
2. Directly compatible with IOKit `IOMemoryDescriptor` / `IOMemoryMap` or ACPI Method invocations (`RYFS`, `RYFA`, `RYRC`).
3. Fully documented in `HardwareProfiles/legion7-16achg6.json:24-41`.

### 3.2 Method B: Super I/O LPC Direct Port I/O (Reference)
In Linux bare-metal drivers, extended EC RAM is alternatively addressed through Super I/O index/data ports `0x4E` and `0x4F`:
1. Select base address register via `0x200A` (`BADRSEL`).
2. Write the 16-bit target address (MSB then LSB) to index port `0x4E`.
3. Read or write the payload byte through data port `0x4F`.

*Verification Citation*:
- `LenovoLegionLinux` (`legion-laptop.c:4550-4650`): `ecram_read` and `ecram_write` via Super I/O port pair `0x4E`/`0x4F`.
- `LeGo2-Fan-Control` (`main.py:189-215`): WinRing0 port I/O mapping.

---

## 4. Exact Register & Memory Map

The following table provides the comprehensive memory mapping for Legion IT8227 EC fan regulation, detailing both the native EC RAM address and the corresponding ACPI SystemMemory MMIO offset:

| EC RAM Address | MMIO Offset (`0xFE00D400 +`) | Field Name | Width | Type | Description |
|---|---|---|---|---|---|
| `0xC420` | `0x020` | `EXT_POWERMODE` (`SPMO`) | 8-bit | RW | Power mode: `1` = Quiet, `2` = Balanced, `3` = Performance |
| `0xC4AB` | `0x0AB` | `EXT_LOCKFANCONTROLLER` | 8-bit | RW | Manual lock: `0x08` = Lock to target RPM, `0x00` = Auto |
| `0xC534` | `0x134` | `EXT_FAN_CUR_POINT` (`RYCP`) | 8-bit | RW | Active curve trip point index currently evaluated by EC |
| `0xC535` | `0x135` | `EXT_FAN_POINTS_SIZE` (`RYCS`)| 8-bit | RW | Active curve point count (Factory default: `10` / `0x0A`) |
| `0xC536` | `0x136` | `EXT_MINIFANCURVE_ON_COOL` | 8-bit | RW | Low-temperature override: `0x04` = Enabled, `0xA0` = Disabled |
| `0xC538` | `0x138` | `EXT_CPU_TEMP_INPUT` (`RYCT`) | 8-bit | RO | Live CPU Temperature in degrees Celsius (°C) |
| `0xC539` | `0x139` | `EXT_GPU_TEMP_INPUT` (`RYGT`) | 8-bit | RO | Live GPU Temperature in degrees Celsius (°C) |
| `0xC53A` | `0x13A` | `EXT_VRM_TEMP_INPUT` | 8-bit | RO | Live VRM / Motherboard sensor temperature in °C |
| `0xC540..0xC549` | `0x140..0x149` | `EXT_FAN1_BASE` (`RYB0`) | 10B | RW | Fan 1 (CPU) 10-point speed table in units of 100 RPM |
| `0xC550..0xC559` | `0x150..0x159` | `EXT_FAN2_BASE` (`RYB1`) | 10B | RW | Fan 2 (GPU) 10-point speed table in units of 100 RPM |
| `0xC560..0xC569` | `0x160..0x169` | `EXT_FAN_ACC_BASE` | 10B | RW | Fan acceleration interval steps between points (default 2) |
| `0xC570..0xC579` | `0x170..0x179` | `EXT_FAN_DEC_BASE` | 10B | RW | Fan deceleration interval steps between points (default 2) |
| `0xC580..0xC589` | `0x180..0x189` | `EXT_CPU_TEMP` | 10B | RW | CPU Upper temperature trip points in °C (Step-up trigger)|
| `0xC590..0xC599` | `0x190..0x199` | `EXT_CPU_TEMP_HYST` | 10B | RW | CPU Lower temperature trip points in °C (Step-down trigger)|
| `0xC5A0..0xC5A9` | `0x1A0..0x1A9` | `EXT_GPU_TEMP` | 10B | RW | GPU Upper temperature trip points in °C (Step-up trigger)|
| `0xC5B0..0xC5B9` | `0x1B0..0x1B9` | `EXT_GPU_TEMP_HYST` | 10B | RW | GPU Lower temperature trip points in °C (Step-down trigger)|
| `0xC5C0..0xC5C9` | `0x1C0..0x1C9` | `EXT_VRM_TEMP` | 10B | RW | VRM Upper temperature trip points in °C |
| `0xC5D0..0xC5D9` | `0x1D0..0x1D9` | `EXT_VRM_TEMP_HYST` | 10B | RW | VRM Lower temperature trip points in °C |
| `0xC5E0..0xC5E1` | `0x1E0..0x1E1` | `EXT_FAN1_RPM` (`RYR0`) | 16-bit | RO | Fan 1 (CPU) live tachometer reading (16-bit unsigned RPM) |
| `0xC5E2..0xC5E3` | `0x1E2..0x1E3` | `EXT_FAN2_RPM` (`RYR1`) | 16-bit | RO | Fan 2 (GPU) live tachometer reading (16-bit unsigned RPM) |
| `0xC5FE` | `0x1FE` | `FAN_TABLE_CHG_COUNTER1` (`RYC0`)| 8-bit | RW | Handshake counter 1 (Must zero before table update) |
| `0xC5FF` | `0x1FF` | `FAN_TABLE_CHG_COUNTER2` (`RYC1`)| 8-bit | RW | Handshake counter 2 (Must zero before table update) |
| `0xC600..0xC601` | `0x200..0x201` | `EXT_FAN1/2_TARGET_RPM` | 16-bit | RW | Target manual RPM when controller is locked (`0xC4AB = 0x08`)|
| `0xC634` | `0x234` | `CPU_FAN_LEVEL` (`RYL0`) | 8-bit | RW | EC internal evaluated thermal level for CPU |
| `0xC635` | `0x235` | `GPU_FAN_LEVEL` (`RYL1`) | 8-bit | RW | EC internal evaluated thermal level for GPU |
| `0xC636` | `0x236` | `HST_FAN_LEVEL` (`RYL2`) | 8-bit | RW | EC internal evaluated thermal level for secondary sensors |

---

## 5. Fan Curve Architecture & 10-Point Schema

### 5.1 Speed Granularity
Fan curve speeds are expressed as 8-bit integers representing units of **100 RPM**:
$$\text{Fan RPM} = \text{Register Value} \times 100$$
- Value `22` = 2,200 RPM.
- Value `35` = 3,500 RPM.
- Value `45` = 4,500 RPM (Typical maximum rated speed for Legion 7 2021).

### 5.2 Dual Hysteresis Trip Points
To prevent rapid, annoying fan speed fluctuations ("hunting") when temperatures hover near a trip boundary, the IT8227 firmware evaluates two distinct thresholds for every point $i \in [0, 9]$:
1. **Upper Threshold (`0xC580 + i` CPU, `0xC5A0 + i` GPU)**: The temperature must *rise to or exceed* this value to switch from point $i-1$ up to point $i$.
2. **Lower Threshold (`0xC590 + i` CPU, `0xC5B0 + i` GPU)**: The temperature must *drop below* this value to switch down from point $i$ to point $i-1$.

*Invariant Rule*:
$$\text{Lower Threshold}[i] < \text{Upper Threshold}[i] \quad \text{with} \quad (\text{Upper} - \text{Lower}) \ge 3^\circ\text{C}$$

### 5.3 Typical Factory Curve Reference Table (Balanced Profile)
Below is the verified factory baseline curve extracted from Legion 7 16ACHg6 BIOS GKCN:

| Point ($i$) | Upper Temp (°C) | Lower Temp (°C) | Fan 1 RPM | Fan 2 RPM | Accel / Decel |
|---|---|---|---|---|---|
| 0 | 45 | 38 | 0 (or 1600) | 0 (or 1600) | 2 / 2 |
| 1 | 52 | 44 | 1900 | 1900 | 2 / 2 |
| 2 | 58 | 50 | 2200 | 2200 | 2 / 2 |
| 3 | 64 | 56 | 2500 | 2500 | 2 / 2 |
| 4 | 70 | 62 | 2800 | 2800 | 2 / 2 |
| 5 | 76 | 68 | 3200 | 3200 | 2 / 2 |
| 6 | 82 | 74 | 3600 | 3600 | 2 / 2 |
| 7 | 88 | 80 | 4000 | 4000 | 2 / 2 |
| 8 | 94 | 86 | 4300 | 4300 | 2 / 2 |
| 9 | 100 | 92 | 4500 | 4500 | 2 / 2 |

---

## 6. Table Update Handshake Protocol

Because the EC firmware runs continuous asynchronous thermal loops, modifying multi-byte curve tables in EC RAM without synchronization causes the EC to read inconsistent state, resulting in fan stalls or sudden full-blast spikes.

### 6.1 Handshake Sequence Steps
The verified update protocol across `LenovoLegionLinux` and `LegionFanEmbeddedController` proceeds in exact order:

```
Step 1: Invalidate Change Counters
        EC[0xC5FE] = 0x00
        EC[0xC5FF] = 0x00

Step 2: Write Speed & Step Tables
        EC[0xC540..0xC549] = Fan 1 Speed Table (10 Bytes)
        EC[0xC550..0xC559] = Fan 2 Speed Table (10 Bytes)
        EC[0xC560..0xC569] = Acceleration Steps (10 Bytes)
        EC[0xC570..0xC579] = Deceleration Steps (10 Bytes)

Step 3: Write Temperature Thresholds
        EC[0xC580..0xC589] = CPU Upper Temp Thresholds (10 Bytes)
        EC[0xC590..0xC599] = CPU Lower Temp Hysteresis (10 Bytes)
        EC[0xC5A0..0xC5A9] = GPU Upper Temp Thresholds (10 Bytes)
        EC[0xC5B0..0xC5B9] = GPU Lower Temp Hysteresis (10 Bytes)
        (Optional: EC[0xC5C0..0xC5D9] for VRM/IC)

Step 4: Configure Curve Metadata
        EC[0xC535] = Point Count (e.g., 0x0A)
        EC[0xC536] = 0xA0 (Disable mini-fan curve idle override)

Step 5: Force EC Re-Evaluation Handshake
        EC[0xC534] = 0x00 (Reset active curve point index)
        EC[0xC634] = 0x00 (Reset internal CPU thermal level)
        EC[0xC635] = 0x00 (Reset internal GPU thermal level)
        EC[0xC636] = 0x00 (Reset internal sensor thermal level)
```

### 6.2 Significance of Resetting Level Registers (`0xC634..0xC636`)
If `0xC534` and `0xC634..0xC636` are not zeroed following a table write, the EC continues to operate under its previously cached evaluation state. It will not apply the newly loaded curve until temperatures swing sufficiently to cross the old curve's outer boundaries. Zeroing these registers forces the EC thermal engine to restart evaluation immediately from index 0.

*Verification Citation*:
- `LenovoLegionLinux` (`legion-laptop.c:6308-6355`):
  ```c
  ecram_write(ecram, 0xC5FE, 0);
  ecram_write(ecram, 0xC5FF, 0);
  ...
  ecram_write(ecram, 0xC535, fancurve->size);
  ecram_write(ecram, 0xC534, 0);
  ecram_write(ecram, 0xC634, 0);
  ecram_write(ecram, 0xC635, 0);
  ecram_write(ecram, 0xC636, 0);
  ```
- `Legion-Fan-Controller` (`LegionEcWriter.cs:115-150`): Implements identical zeroing on `FAN_TABLE_CHG_COUNTER`, `FAN_CUR_POINT`, and `CPU_FAN_LEVEL`.

---

## 7. Safe Reversion Mechanisms to Firmware Auto Control

Hardware safety requires reliable, immediate reversion to factory default fan management whenever custom software relinquishes control, disconnects, crashes, or sleeps.

There are three independent hardware-supported mechanisms to restore factory Auto mode:

### 7.1 Mechanism 1: Table Restoration from Memory Cache (`RYFA`)
When ReYogaSMC initializes, it captures the untouched factory tables from `0xC540..0xC5D9` into driver memory (and ACPI buffer `RYO0` / `RYO1`). Reversion copies the factory tables back to EC RAM and executes the re-evaluation reset (`RYRC`).

### 7.2 Mechanism 2: ACPI Reversion Method (`RYFA`)
In `SSDT-ReYoga.template.dsl`, method `RYFA()` performs atomic reversion:
```asl
Method (RYFA, 0, Serialized)
{
    If ({{power_mode_field}} == RYPM)
    {
        If (RYA0) { RYB0 = RYO0 }
        If (RYA1) { RYB1 = RYO1 }
        If (RYA0 || RYA1) { RYRC () }
    }
    RYA0 = Zero
    RYA1 = Zero
    RYP0 = Zero
    RYP1 = Zero
    Return (Zero)
}
```

### 7.3 Mechanism 3: Power Mode Reset via `SPMO` (`0xC420`)
The IT8227 firmware ROM stores the canonical factory curves for Quiet, Balanced, and Performance modes. Whenever `0xC420` (`SPMO`) is written (or the user presses Fn+Q), the EC firmware automatically wipes the active curves in RAM and reloads the default factory curves from flash ROM.
- Toggling or refreshing `SPMO` via ACPI method `SBMC` or writing to `0xC420` provides a clean hardware-level reset.

*Verification Citation*:
- `LenovoLegionLinux` (`legion-laptop.c:2575-2578`): Documents automatic curve reload on power profile switch.
- `LeGo2-Fan-Control` (`main.py:370-375`): Releases manual control back to EC automatic thermal control in `finally` cleanup by zeroing `REG_OVERRIDE_WRITE` (`0xC6C8`). For standard Legion laptops, writing `0xC420` (`SPMO`) resets EC curve RAM to ROM defaults, whereas Legion Go handheld firmware uses `REG_POWER_MODE = 0xC683`.

---

## 8. Safety Bounds, Guardrails & Edge Cases

To guarantee system stability and prevent hardware damage or thermal runaway, any custom curve implementation must enforce rigid guardrails and handle hardware-driven state transitions:

```
   ┌──────────────────────────────────────────────────────────────┐
   │                OVER-TEMPERATURE EMERGENCY PANIC              │
   │           CPU >= 101°C   OR   GPU >= 95°C                    │
   │        --> EC Forces 100% Full Speed (Hardware Trip)         │
   └──────────────────────────────────────────────────────────────┘
                                  ▲
   ┌──────────────────────────────┴───────────────────────────────┐
   │                 DRIVER & HELPER SAFETY BOUNDS                │
   │  - Temperature Range: [30°C, 95°C] (Active Points)           │
   │  - Sentinel Padding: 0x7F (127°C) for unused slots (i >= N)  │
   │  - Fn+Q / Mode Change: Invalidate lease & revert on SPMO chg │
   │  - Floor Clamping: Curve Point RPM >= Factory Baseline       │
   │  - Hysteresis: Upper Trip - Lower Trip >= 3°C                │
   │  - Stale Telemetry: Sanitize RPM > 20000 or 0xFFFF to 0      │
   │  - Lease Watchdog: 6-second heartbeat; reverts on timeout    │
   └──────────────────────────────────────────────────────────────┘
```

### 8.1 Input Temperature Range & Sentinel Value Padding
- **Active Trip Point Bounds**: Temperature trip points for active curve points must be strictly bounded within $[30^\circ\text{C}, 95^\circ\text{C}]$. Any point requesting a trip temperature below $30^\circ\text{C}$ or above $95^\circ\text{C}$ must be rejected by input validation.
- **10-Point Hardware Table Layout**: The physical IT8227 EC RAM table is fixed at 10 entries (`0xC540..0xC549` for speeds, `0xC580..0xC5B9` for temperatures). When a custom curve contains fewer than 10 points ($N < 10$, where $N \ge 1$), the active curve size is programmed into `EXT_FAN_POINTS_SIZE` (`0xC535` = $N$).
- **Sentinel Value `0x7F` (127°C) Padding**: Unused slots ($i \ge N$, from index $N$ through 9) must be populated with sentinel value `0x7F` ($127^\circ\text{C}$) in `EXT_CPU_TEMP`, `EXT_CPU_TEMP_HYST`, `EXT_GPU_TEMP`, and `EXT_GPU_TEMP_HYST`, and `0` for speed entries. Because $127^\circ\text{C}$ is beyond maximum system operational thermal thresholds, this sentinel value guarantees that the EC hardware comparator never triggers evaluation on unpopulated curve slots.
- **Driver / App Validation Contract**: Input validation in `IdeaVPCFan.cpp` and `ReYogaSMCApp` must validate $[30^\circ\text{C}, 95^\circ\text{C}]$ strictly for active points ($0 \le i < N$). It must explicitly permit `0x7F` as sentinel padding for unused slots ($i \ge N$) and must **not** reject valid short curves due to the padding value.

### 8.2 Fn+Q / Power Mode Transition Contract
- **Firmware ROM Reload Behavior**: When the user presses the Fn+Q hotkey or changes the system power profile (e.g., between Quiet, Balanced, and Performance) via software (Vantage, Legion Zone, or ACPI/WMI call), the EC firmware immediately executes an internal reset of its RAM curve tables:
  1. The EC immediately wipes user-defined curve tables in EC RAM (`0xC540..0xC5B9`).
  2. The EC reloads the factory default curves from flash ROM corresponding to the newly selected power mode (`SPMO`).
- **Driver / App Synchronization Contract**:
  1. **Transition Tracking**: The driver and app must track power mode transitions by monitoring `SPMO` (`0xC420`), ACPI notifications (e.g., from `\_SB.PCI0.LPC0.EC0`), and VPC hotkey event notifications (`0x02` or `0x11`).
  2. **Immediate Lease Invalidation**: Upon detecting any power mode change, the driver must immediately cancel any active custom curve lease and transition its internal fan state back to `Auto` / `Default`.
  3. **Watchdog Cancellation**: The watchdog heartbeat timer must cease renewing custom curves until the user explicitly reapplies a custom curve for the new power profile.
  4. **Prevention of Desynchronization**: Without this invalidation contract, a dangerous race occurs where the driver assumes a custom curve lease is active while the EC hardware is already running on the newly reloaded ROM curve, or the driver watchdog periodically re-injects an old custom curve over the user's newly selected power mode, defeating the user's intentional mode switch.

### 8.3 Minimum Factory Floor Clamping
- Custom curves must never allow fan speeds lower than what the factory firmware requires for a given thermal load.
- If a user configures a target RPM lower than the factory baseline for point $i$, the driver/SSDT clamps the speed up to the factory floor:
  $$\text{Target RPM}[i] = \max(\text{User Target RPM}[i], \text{Factory Baseline RPM}[i])$$
- Enforced in ACPI `RYFS`:
  ```asl
  Local4 = DerefOf (Local0 [Local3])
  If (Local4 < Local2) { Local0 [Local3] = Local2 }
  ```

### 8.4 Hardware Over-Temperature Panic Thresholds
- The IT8227 firmware features hardwired over-temperature overrides:
  - **CPU Panic**: If CPU temperature reaches $\ge 101^\circ\text{C}$.
  - **GPU Panic**: If GPU temperature reaches $\ge 95^\circ\text{C}$.
- In panic state, the EC overrides all RAM curve tables, disables manual controller lock, and forces both fans to maximum possible RPM until temperatures cool safely below trip thresholds.

### 8.5 Active Lease Watchdog Contract
- ReYogaSMC driver must implement an active lease timer (`IOTimerEventSource`):
  - **Heartbeat frequency**: App sends lease refresh every $1000\text{ ms}$.
  - **Lease expiration timeout**: $6000\text{ ms}$ (6 seconds).
  - **Failure actions**: On client disconnect, application crash, helper termination, or system sleep (`setPowerState`), the watchdog automatically invokes `restorePlatformFans()` / `RYFA()` to revert EC back to firmware Auto control.

### 8.6 SafeMode Guard
- The driver must inspect the kernel boot arguments for `-reysafe`. If present, all fan curve write operations must be disabled fail-closed (`verified_writes = 0`), permitting only read-only telemetry.

---

## 9. Citations & References

### 9.1 Open-Source Reference Implementations
1. **LenovoLegionLinux (`johnfanv2/LenovoLegionLinux`)**
   - Repository: `https://github.com/johnfanv2/LenovoLegionLinux`
   - Verified Commit: `ff72e4c2b437ec605d5f2e34c5b34111c57c9cc0`
   - Key Files:
     - `kernel_module/legion-laptop.c:364-395` (Register offset declarations for `ec_register_offsets_v0`)
     - `kernel_module/legion-laptop.c:643-666` (`model_v0` definition, chip ID `0x8227`, MMIO `0xC400`, size `0x300`)
     - `kernel_module/legion-laptop.c:4550-4650` (Super I/O port `0x4E`/`0x4F` protocol)
     - `kernel_module/legion-laptop.c:6250-6357` (`fancurve_write`, handshake counters `0xC5FE`/`0xC5FF`, level reset `0xC634..0xC636`)

2. **LenovoLegionToolkit (`BartoszCichecki/LenovoLegionToolkit`)**
   - Repository: `https://github.com/BartoszCichecki/LenovoLegionToolkit`
   - Verified Commit: `0bb045be29c4fd772ba9887a3507b6a9b0b56d58`
   - Key Files:
     - `LenovoLegionToolkit.Lib/Utils/Compatibility.cs:175-190` (Model capability detection)
     - `LenovoLegionToolkit.Lib/Controllers/GodMode/GodModeController.cs:1424-1429, 988-1020` (Curve validation in `IsValidFanTableAsync` and table verification in `SetFanTableWithVerifyAsync`)
     - `LenovoLegionToolkit.Lib/System/Management/WMI.LenovoFanMethod.cs:12-36` (`Fan_Set_Table` and `Fan_Set_FullSpeed` WMI command methods)

3. **LegionFanEmbeddedController (`rango886/LegionFanEmbeddedController`)**
   - Repository: `https://github.com/rango886/LegionFanEmbeddedController`
   - Verified Commit: `067bf4b3eba7c76e83eebba919a947098d5fee0c`
   - Key Files:
     - `Utils.cs:39-100` (ITE Super I/O indexing protocol via ports `0x4E`/`0x4F`)
     - `Utils.cs:181-215` (`ITE_REGISTER_MAP` definitions, chip ID `0x8227` verification)
     - `config/silent1.json` (10-point JSON fan curve profile definitions)

4. **Legion-Fan-Controller (`Kangarroar/Legion-Fan-Controller`)**
   - Repository: `https://github.com/Kangarroar/Legion-Fan-Controller`
   - Verified Commit: `033e5b959692d60af373b671dbf741466248e1b8`
   - Key Files:
     - `Lenovo Fan Controller/Hardware/LegionEcWriter.cs:102-157` (`FAN_TABLE_CHG_COUNTER = 0xC5FE`, `FAN_CUR_POINT = 0xC534`, `CPU_FAN_LEVEL = 0xC634`)
     - `Lenovo Fan Controller/Hardware/LegionEcReader.cs:240-358` (Tachometer reading at `0xC5E0..0xC5E3`, temperature readings at `0xC538..0xC539`)

5. **LeGo2-Fan-Control (`Rodpad/LeGo2-Fan-Control`)**
   - Repository: `https://github.com/Rodpad/LeGo2-Fan-Control`
   - Verified Commit: `de1a45e06c129afe7a7752224b077c3044d2d69d`
   - Key Files:
     - `main.py:189-215` (Direct Super I/O port access routines)
     - `main.py:370-375` (Foolproof safety catch in `finally` block: writes 0 to `REG_OVERRIDE_WRITE` (`0xC6C8`) and `REG_OVERRIDE_WRITE + 1` (`0xC6C9`) to explicitly release manual override back to EC automatic thermal control; note that Legion Go utilizes `REG_POWER_MODE = 0xC683` whereas standard Legion 7 16ACHg6 uses `0xC420` (`SPMO`))

### 9.2 Proprietary Reference Utility: LegionFanControl
- **Utility**: `LegionFanControl`
- **Website**: `https://www.legionfancontrol.com/`
- **Author**: smoky
- **Target Hardware**: Lenovo Legion 7 (2020 Gen 5, 2021 Gen 6 16ACHg6, 2022 Gen 7), Legion 5 / 5 Pro
- **Architecture & Approach**:
  - Operates as a Windows background service paired with a desktop GUI.
  - Interacts with the ITE IT8227 EC through low-level kernel driver port I/O to read hardware sensors and program curve registers in extended EC RAM.
  - Implements custom fan curve profiles tailored for Quiet, Balanced, and Performance modes on Legion 7 2021, custom temperature hysteresis, and manual fan lock capabilities.
- **Historical Significance & EC Register Correlation**:
  - *LegionFanControl* was the earliest widely adopted utility to prove that Lenovo Legion laptops support custom runtime fan curves without permanent BIOS modifications.
  - Identified that the IT8227 EC loads continuous 10-point temperature and fan speed tables in extended RAM starting at `0xC540`, rather than relying solely on monolithic BIOS-controlled fan steps.
  - Demonstrated the necessity of continuous background lease management and safe fallback to Auto control when the control software exits.
  - Its empirical findings directly paved the way for subsequent open-source implementations (`LegionFanEmbeddedController`, `LenovoLegionLinux`, `LenovoLegionToolkit`).

### 9.3 Local Repository Artifacts
1. `HardwareProfiles/legion7-16achg6.json`:
   - Lines 23–41: MMIO base `0xFE00D400`, size `0x600`, register offsets (`fan1_curve: 0x140`, `fan2_curve: 0x150`, `fan1_rpm: 0x1E0`, `fan2_rpm: 0x1E2`, `cpu_temp: 0x138`, `gpu_temp: 0x139`, `update_counter1: 0x1FE`, `curve_point: 0x134`, `internal_cpu_level: 0x234`).
2. `HardwareProfiles/SSDT-ReYoga.template.dsl`:
   - Lines 15–28: `OperationRegion (RYER, SystemMemory, {{ec_base}}, {{ec_size}})`.
   - Lines 109–116: Method `RYRC` level re-evaluation reset.
   - Lines 139–179: Method `RYFS` custom curve write with factory floor enforcement.
   - Lines 180–195: Method `RYFA` safe reversion to factory curve.
