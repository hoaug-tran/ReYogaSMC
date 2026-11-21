// SPDX-License-Identifier: GPL-2.0-only
// Original work: Copyright (c) 2020 Zhen.

#include "IdeaVPC.hpp"
#include "../WMI/IdeaWMI.hpp"
#include <pexpert/pexpert.h>
#include <IOKit/IOMemoryDescriptor.h>

// Verified EC MMIO window bounds (physical base and size come from matched ReYogaNativeProfile)
static constexpr IOByteCount kLegionMinECMMIOSize = 0x300;
static constexpr IOByteCount kLegionMaxECMMIOSize = 0x10000;

static constexpr UInt32 kLegionRegPowerMode = 0x020;         // 0xC420 EXT_POWERMODE (SPMO)
static constexpr UInt32 kLegionRegLockFan = 0x0AB;           // 0xC4AB EXT_LOCKFANCONTROLLER
static constexpr UInt32 kLegionRegCurvePoint = 0x134;        // 0xC534 EXT_FAN_CUR_POINT (RYCP)
static constexpr UInt32 kLegionRegCurveSize = 0x135;         // 0xC535 EXT_FAN_POINTS_SIZE (RYCS)
static constexpr UInt32 kLegionRegMiniCurveCool = 0x136;     // 0xC536 EXT_MINIFANCURVE_ON_COOL
static constexpr UInt32 kLegionRegCPUTempInput = 0x138;      // 0xC538 EXT_CPU_TEMP_INPUT (RYCT)
static constexpr UInt32 kLegionRegGPUTempInput = 0x139;      // 0xC539 EXT_GPU_TEMP_INPUT (RYGT)
static constexpr UInt32 kLegionRegVRMTempInput = 0x13A;      // 0xC53A EXT_VRM_TEMP_INPUT
static constexpr UInt32 kLegionRegFan1Base = 0x140;          // 0xC540..0xC549 EXT_FAN1_BASE (RYB0)
static constexpr UInt32 kLegionRegFan2Base = 0x150;          // 0xC550..0xC559 EXT_FAN2_BASE (RYB1)
static constexpr UInt32 kLegionRegFanAccBase = 0x160;        // 0xC560..0xC569 EXT_FAN_ACC_BASE
static constexpr UInt32 kLegionRegFanDecBase = 0x170;        // 0xC570..0xC579 EXT_FAN_DEC_BASE
static constexpr UInt32 kLegionRegCPUTemp = 0x180;           // 0xC580..0xC589 EXT_CPU_TEMP
static constexpr UInt32 kLegionRegCPUTempHyst = 0x190;       // 0xC590..0xC599 EXT_CPU_TEMP_HYST
static constexpr UInt32 kLegionRegGPUTemp = 0x1A0;           // 0xC5A0..0xC5A9 EXT_GPU_TEMP
static constexpr UInt32 kLegionRegGPUTempHyst = 0x1B0;       // 0xC5B0..0xC5B9 EXT_GPU_TEMP_HYST
static constexpr UInt32 kLegionRegVRMTemp = 0x1C0;           // 0xC5C0..0xC5C9 EXT_VRM_TEMP
static constexpr UInt32 kLegionRegVRMTempHyst = 0x1D0;       // 0xC5D0..0xC5D9 EXT_VRM_TEMP_HYST
static constexpr UInt32 kLegionRegFan1RPM = 0x1E0;           // 0xC5E0..0xC5E1 EXT_FAN1_RPM (RYR0)
static constexpr UInt32 kLegionRegFan2RPM = 0x1E2;           // 0xC5E2..0xC5E3 EXT_FAN2_RPM (RYR1)
static constexpr UInt32 kLegionRegCounter1 = 0x1FE;          // 0xC5FE FAN_TABLE_CHG_COUNTER1 (RYC0)
static constexpr UInt32 kLegionRegCounter2 = 0x1FF;          // 0xC5FF FAN_TABLE_CHG_COUNTER2 (RYC1)
static constexpr UInt32 kLegionRegCPULevel = 0x234;          // 0xC634 CPU_FAN_LEVEL (RYL0)
static constexpr UInt32 kLegionRegGPULevel = 0x235;          // 0xC635 GPU_FAN_LEVEL (RYL1)
static constexpr UInt32 kLegionRegHSTLevel = 0x236;          // 0xC636 HST_FAN_LEVEL (RYL2)

static UInt64 legionFanTimeMS() {
    UInt64 absolute = 0, nanoseconds = 0;
    clock_get_uptime(&absolute);
    absolutetime_to_nanoseconds(absolute, &nanoseconds);
    return nanoseconds / 1000000;
}

bool IdeaVPC::hasVerifiedLegionCurveProfile() const {
    if (safeMode || !nativeProfile)
        return false;
    if (nativeProfile->fields[ReYogaSensor::Fan1][0] == '\0' ||
        nativeProfile->fields[ReYogaSensor::Fan2][0] == '\0')
        return false;
    if (!nativeProfile->verifiedWrites ||
        nativeProfile->ecBase == 0 ||
        nativeProfile->ecSize < kLegionMinECMMIOSize ||
        nativeProfile->ecSize > kLegionMaxECMMIOSize ||
        nativeProfile->curvePointsMax == 0 ||
        nativeProfile->curvePointsMax > 10 ||
        !dsdtMMIOVerified)
        return false;
    if (legionBridge) {
        UInt32 verified = 0;
        if (legionBridgeVersion < 2 || !ec ||
            ec->evaluateInteger("RYVW", &verified) != kIOReturnSuccess ||
            verified != 1)
            return false;
    }
    return true;
}

bool IdeaVPC::isLegionFanCurveSupported() const {
    return hasVerifiedLegionCurveProfile() &&
           mmioBase != nullptr &&
           legionFanWatchdog != nullptr;
}

bool IdeaVPC::initMMIOWindow() {
    if (mmioBase != nullptr)
        return true;
    if (safeMode || !hasVerifiedLegionCurveProfile())
        return false;
    const IOPhysicalAddress physBase = static_cast<IOPhysicalAddress>(nativeProfile->ecBase);
    const IOByteCount size = static_cast<IOByteCount>(nativeProfile->ecSize);
    mmioDescriptor = IOMemoryDescriptor::withPhysicalAddress(physBase, size, kIODirectionInOut);
    if (!mmioDescriptor)
        return false;
    mmioMap = mmioDescriptor->createMappingInTask(kernel_task, 0, kIOMapAnywhere | kIOMapInhibitCache);
    if (!mmioMap) {
        mmioDescriptor->release();
        mmioDescriptor = nullptr;
        return false;
    }
    mmioBase = reinterpret_cast<volatile UInt8 *>(mmioMap->getVirtualAddress());
    if (!mmioBase) {
        freeMMIOWindow();
        return false;
    }
    mmioPhysBase = physBase;
    mmioSize = size;
    return true;
}

void IdeaVPC::freeMMIOWindow() {
    if (mmioMap) {
        mmioMap->release();
        mmioMap = nullptr;
    }
    if (mmioDescriptor) {
        mmioDescriptor->release();
        mmioDescriptor = nullptr;
    }
    mmioBase = nullptr;
    mmioPhysBase = 0;
    mmioSize = 0;
}

UInt8 IdeaVPC::readMMIO8(UInt32 offset) {
    if (mmioBase && offset < mmioSize)
        return mmioBase[offset];
    return 0;
}

UInt16 IdeaVPC::readMMIO16(UInt32 offset) {
    if (mmioBase && mmioSize >= 2 && offset < mmioSize - 1)
        return static_cast<UInt16>(mmioBase[offset]) | (static_cast<UInt16>(mmioBase[offset + 1]) << 8);
    return 0;
}

void IdeaVPC::writeMMIO8(UInt32 offset, UInt8 value) {
    if (mmioBase && offset < mmioSize && !safeMode)
        mmioBase[offset] = value;
}

bool IdeaVPC::initLegionFanControls() {
    if (safeMode || !hasVerifiedLegionCurveProfile())
        return false;
    if (!initMMIOWindow()) {
        AlwaysLog("LegionFan: failed to map MMIO window");
        return false;
    }
    if (!captureFactoryCurveTable()) {
        AlwaysLog("LegionFan: failed to capture valid factory curve table");
        freeMMIOWindow();
        factoryCurveCaptured = false;
        return false;
    }
    if (!legionFanWatchdog) {
        if (!workLoop) {
            freeMMIOWindow();
            factoryCurveCaptured = false;
            return false;
        }
        legionFanWatchdog = IOTimerEventSource::timerEventSource(this,
            OSMemberFunctionCast(IOTimerEventSource::Action, this, &IdeaVPC::expireLegionFanCurve));
        if (!legionFanWatchdog || workLoop->addEventSource(legionFanWatchdog) != kIOReturnSuccess) {
            AlwaysLog("LegionFan: failed to register watchdog timer");
            OSSafeReleaseNULL(legionFanWatchdog);
            freeMMIOWindow();
            factoryCurveCaptured = false;
            return false;
        }
        legionFanWatchdog->enable();
    }
    return mmioBase != nullptr && legionFanWatchdog != nullptr && factoryCurveCaptured;
}

void IdeaVPC::initPlatformControls() {
    // Legion capability is synchronized after initNativeProfile() and initBridge() via syncLegionFanCapability().
}

void IdeaVPC::exitPlatformControls() {
    if (legionFanWatchdog) {
        legionFanWatchdog->cancelTimeout();
        legionFanWatchdog->disable();
        if (workLoop)
            workLoop->removeEventSource(legionFanWatchdog);
        OSSafeReleaseNULL(legionFanWatchdog);
    }
    restorePlatformFans();
    freeMMIOWindow();
    factoryCurveCaptured = false;
}

bool IdeaVPC::validateFanCurveTable(const LegionFanCurveTable &table, bool isRestoration, bool allowFactoryTemps) const {
    const UInt8 maxPoints = (nativeProfile && nativeProfile->curvePointsMax >= 1 && nativeProfile->curvePointsMax <= 10)
        ? nativeProfile->curvePointsMax
        : 10;
    if (table.pointCount < 1 || table.pointCount > maxPoints)
        return false;

    const UInt8 maxTemp = (isRestoration || allowFactoryTemps) ? 105 : 95;

    // Validate active points [0 .. pointCount - 1]
    for (UInt8 i = 0; i < table.pointCount; ++i) {
        const auto &p = table.points[i];

        // 1. Temperature range [30, maxTemp] deg C for active points
        if (p.upperTemp < 30 || p.upperTemp > maxTemp)
            return false;

        // 2. Hysteresis checking: >= 3 deg C, and lower < upper
        if (p.lowerTemp >= p.upperTemp || (p.upperTemp - p.lowerTemp) < 3)
            return false;

        // 3. Monotonicity: upper temperatures strictly increasing
        if (i > 0 && p.upperTemp <= table.points[i - 1].upperTemp)
            return false;
        if (i > 0 && p.lowerTemp < table.points[i - 1].lowerTemp)
            return false;

        // 4. Fan speed upper bounds (<= 6000 RPM) and 100 RPM granularity
        if (p.fan1RPM > 6000 || p.fan2RPM > 6000)
            return false;
        if ((p.fan1RPM % 100 != 0) || (p.fan2RPM % 100 != 0))
            return false;

        // 5. Fan speeds non-decreasing
        if (i > 0 && (p.fan1RPM < table.points[i - 1].fan1RPM || p.fan2RPM < table.points[i - 1].fan2RPM))
            return false;
    }

    // Validate inactive points [pointCount .. 9]
    for (UInt8 i = table.pointCount; i < 10; ++i) {
        const auto &p = table.points[i];
        // Inactive slots must use sentinel 0x7F (127 C) and speed 0
        if (p.upperTemp != 0x7F || p.lowerTemp != 0x7F || p.fan1RPM != 0 || p.fan2RPM != 0)
            return false;
    }

    return true;
}

bool IdeaVPC::captureFactoryCurveTable() {
    if (factoryCurveCaptured)
        return true;
    if (!mmioBase || !nativeProfile)
        return false;

    const UInt8 maxPoints = (nativeProfile->curvePointsMax >= 1 && nativeProfile->curvePointsMax <= 10)
        ? nativeProfile->curvePointsMax
        : 10;
    const UInt8 size = readMMIO8(kLegionRegCurveSize);
    if (size < 1 || size > maxPoints)
        return false;

    LegionFanCurveTable captured{};
    captured.pointCount = size;
    for (UInt8 i = 0; i < size; ++i) {
        const UInt8 sp1 = readMMIO8(kLegionRegFan1Base + i);
        const UInt8 sp2 = readMMIO8(kLegionRegFan2Base + i);
        const UInt8 acc = readMMIO8(kLegionRegFanAccBase + i);
        const UInt8 dec = readMMIO8(kLegionRegFanDecBase + i);
        const UInt8 up = readMMIO8(kLegionRegCPUTemp + i);
        const UInt8 low = readMMIO8(kLegionRegCPUTempHyst + i);
        if (up == 0x7F || up < 30 || up > 105)
            return false;
        const UInt16 r1 = static_cast<UInt16>(sp1) * 100;
        const UInt16 r2 = static_cast<UInt16>(sp2) * 100;
        if (r1 > 6000 || r2 > 6000)
            return false;
        captured.points[i].upperTemp = up;
        captured.points[i].lowerTemp = low;
        captured.points[i].fan1RPM = r1;
        captured.points[i].fan2RPM = r2;
        captured.points[i].accel = acc ? acc : 2;
        captured.points[i].decel = dec ? dec : 2;
    }
    for (UInt8 i = size; i < 10; ++i) {
        captured.points[i].upperTemp = 0x7F;
        captured.points[i].lowerTemp = 0x7F;
        captured.points[i].fan1RPM = 0;
        captured.points[i].fan2RPM = 0;
        captured.points[i].accel = 2;
        captured.points[i].decel = 2;
    }

    if (!validateFanCurveTable(captured, true, true))
        return false;

    factoryCurveTable = captured;
    capturedPowerMode = readMMIO8(kLegionRegPowerMode);
    factoryCurveCaptured = true;
    return true;
}

IOReturn IdeaVPC::applyLegionFanCurveTable(const LegionFanCurveTable &table, bool isRestoration, bool allowFactoryTemps) {
    if (safeMode)
        return kIOReturnUnsupported;
    if (!validateFanCurveTable(table, isRestoration, allowFactoryTemps))
        return kIOReturnBadArgument;
    if (!mmioBase)
        return kIOReturnNotReady;
    if (!captureFactoryCurveTable())
        return kIOReturnIOError;

    // Create clamped working table (never lower active speeds below factory floor)
    LegionFanCurveTable clamped = table;
    if (!isRestoration) {
        const UInt8 overlap = clamped.pointCount < factoryCurveTable.pointCount ? clamped.pointCount : factoryCurveTable.pointCount;
        for (UInt8 i = 0; i < overlap; ++i) {
            const UInt16 min1 = factoryCurveTable.points[i].fan1RPM;
            const UInt16 min2 = factoryCurveTable.points[i].fan2RPM;
            if (clamped.points[i].fan1RPM < min1)
                clamped.points[i].fan1RPM = min1;
            if (clamped.points[i].fan2RPM < min2)
                clamped.points[i].fan2RPM = min2;
            if (i > 0) {
                if (clamped.points[i].fan1RPM < clamped.points[i - 1].fan1RPM)
                    clamped.points[i].fan1RPM = clamped.points[i - 1].fan1RPM;
                if (clamped.points[i].fan2RPM < clamped.points[i - 1].fan2RPM)
                    clamped.points[i].fan2RPM = clamped.points[i - 1].fan2RPM;
            }
        }
    }

    // Handshake sequence as per Docs/Legion-Custom-Fan-Curve-Research.md 6.1:
    // Step 1: Invalidate Change Counters
    writeMMIO8(kLegionRegCounter1, 0x00);
    writeMMIO8(kLegionRegCounter2, 0x00);

    // Step 2: Write Speed & Step Tables (all 10 slots)
    for (UInt8 i = 0; i < 10; ++i) {
        writeMMIO8(kLegionRegFan1Base + i, static_cast<UInt8>(clamped.points[i].fan1RPM / 100));
        writeMMIO8(kLegionRegFan2Base + i, static_cast<UInt8>(clamped.points[i].fan2RPM / 100));
        writeMMIO8(kLegionRegFanAccBase + i, clamped.points[i].accel ? clamped.points[i].accel : 2);
        writeMMIO8(kLegionRegFanDecBase + i, clamped.points[i].decel ? clamped.points[i].decel : 2);
    }

    // Step 3: Write Temperature Thresholds (all 10 slots)
    for (UInt8 i = 0; i < 10; ++i) {
        writeMMIO8(kLegionRegCPUTemp + i, clamped.points[i].upperTemp);
        writeMMIO8(kLegionRegCPUTempHyst + i, clamped.points[i].lowerTemp);
        writeMMIO8(kLegionRegGPUTemp + i, clamped.points[i].upperTemp);
        writeMMIO8(kLegionRegGPUTempHyst + i, clamped.points[i].lowerTemp);
    }

    // Step 4: Configure Curve Metadata
    writeMMIO8(kLegionRegCurveSize, clamped.pointCount);
    writeMMIO8(kLegionRegMiniCurveCool, 0xA0); // Disable mini-fan curve idle override

    // Step 5: Clear fan-controller lock and force EC re-evaluation handshake
    writeMMIO8(kLegionRegLockFan, 0x00);
    writeMMIO8(kLegionRegCurvePoint, 0x00);
    writeMMIO8(kLegionRegCPULevel, 0x00);
    writeMMIO8(kLegionRegGPULevel, 0x00);
    writeMMIO8(kLegionRegHSTLevel, 0x00);

    // Readback verification across all 10 slots and lock register
    LegionFanCurveTable readback{};
    const IOReturn readStatus = readbackLegionFanCurveTable(readback);
    if (readStatus != kIOReturnSuccess || readMMIO8(kLegionRegLockFan) != 0x00) {
        AlwaysLog("LegionFan: curve readback or lock clear failed");
        if (!isRestoration)
            restorePlatformFansGated();
        return kIOReturnIOError;
    }

    if (readback.pointCount != clamped.pointCount) {
        AlwaysLog("LegionFan: pointCount mismatch (wrote %u, read %u)", clamped.pointCount, readback.pointCount);
        if (!isRestoration)
            restorePlatformFansGated();
        return kIOReturnIOError;
    }
    for (UInt8 i = 0; i < 10; ++i) {
        if (readback.points[i].upperTemp != clamped.points[i].upperTemp ||
            readback.points[i].lowerTemp != clamped.points[i].lowerTemp ||
            readback.points[i].fan1RPM != clamped.points[i].fan1RPM ||
            readback.points[i].fan2RPM != clamped.points[i].fan2RPM ||
            readMMIO8(kLegionRegGPUTemp + i) != clamped.points[i].upperTemp ||
            readMMIO8(kLegionRegGPUTempHyst + i) != clamped.points[i].lowerTemp) {
            AlwaysLog("LegionFan: point %u mismatch after write", i);
            if (!isRestoration)
                restorePlatformFansGated();
            return kIOReturnIOError;
        }
    }

    if (isRestoration) {
        activeCurveTable = factoryCurveTable;
        customFanCurveActive = false;
    } else {
        activeCurveTable = clamped;
        customFanCurveActive = true;
    }
    return kIOReturnSuccess;
}

IOReturn IdeaVPC::readbackLegionFanCurveTable(LegionFanCurveTable &table) {
    if (!mmioBase)
        return kIOReturnNotReady;

    const UInt8 rawSize = readMMIO8(kLegionRegCurveSize);
    if (rawSize == 0 || rawSize > 10)
        return kIOReturnIOError;
    table.pointCount = rawSize;

    for (UInt8 i = 0; i < 10; ++i) {
        table.points[i].fan1RPM = static_cast<UInt16>(readMMIO8(kLegionRegFan1Base + i)) * 100;
        table.points[i].fan2RPM = static_cast<UInt16>(readMMIO8(kLegionRegFan2Base + i)) * 100;
        table.points[i].accel = readMMIO8(kLegionRegFanAccBase + i);
        table.points[i].decel = readMMIO8(kLegionRegFanDecBase + i);
        table.points[i].upperTemp = readMMIO8(kLegionRegCPUTemp + i);
        table.points[i].lowerTemp = readMMIO8(kLegionRegCPUTempHyst + i);
    }
    return kIOReturnSuccess;
}

IOReturn IdeaVPC::engageFullSpeed() {
    if (safeMode)
        return kIOReturnUnsupported;
    if (legionBridge && ec && ec->validateObject("RYFF") == kIOReturnSuccess) {
        auto argument = OSNumber::withNumber(1ULL, 32);
        if (!argument)
            return kIOReturnNoMemory;
        OSObject *arguments[] = {argument};
        UInt32 ecResult = 0;
        const IOReturn status = ec->evaluateInteger("RYFF", &ecResult, arguments, 1);
        argument->release();
        if (status != kIOReturnSuccess)
            return status;
        if (ecResult != 0)
            return kIOReturnIOError;
        bool fs = true;
        if (wmig && wmig->getFanFullSpeed(&fs) && !fs)
            return kIOReturnIOError;
        fullSpeedEngaged = true;
        return kIOReturnSuccess;
    }
    if (wmig) {
        if (!wmig->setFanFullSpeed(true))
            return kIOReturnIOError;
        bool fs = false;
        if (!wmig->getFanFullSpeed(&fs) || !fs)
            return kIOReturnIOError;
        fullSpeedEngaged = true;
        return kIOReturnSuccess;
    }
    return kIOReturnUnsupported;
}

IOReturn IdeaVPC::disengageFullSpeed() {
    if (safeMode)
        return kIOReturnUnsupported;
    if (legionBridge && ec && ec->validateObject("RYFF") == kIOReturnSuccess) {
        auto argument = OSNumber::withNumber(static_cast<UInt64>(0), 32);
        if (!argument)
            return kIOReturnNoMemory;
        OSObject *arguments[] = {argument};
        UInt32 ecResult = 0;
        const IOReturn status = ec->evaluateInteger("RYFF", &ecResult, arguments, 1);
        argument->release();
        if (status != kIOReturnSuccess)
            return status;
        if (ecResult != 0)
            return kIOReturnIOError;
        bool fs = false;
        if (wmig && wmig->getFanFullSpeed(&fs) && fs)
            return kIOReturnIOError;
        fullSpeedEngaged = false;
        return kIOReturnSuccess;
    }
    if (wmig) {
        if (!wmig->setFanFullSpeed(false))
            return kIOReturnIOError;
        bool fs = true;
        if (!wmig->getFanFullSpeed(&fs) || fs)
            return kIOReturnIOError;
        fullSpeedEngaged = false;
        return kIOReturnSuccess;
    }
    return fullSpeedEngaged ? kIOReturnUnsupported : kIOReturnSuccess;
}

IOReturn IdeaVPC::readHardwareFanControl(UInt32 fan, UInt8 &controlOut) {
    if (fan > 1)
        return kIOReturnBadArgument;
    if (fan && getProperty("Dual fan") != kOSBooleanTrue)
        return kIOReturnUnsupported;

    bool wmiReportedFS = false;
    bool wmiFS = false;
    if (wmig && wmig->getFanFullSpeed(&wmiFS)) {
        wmiReportedFS = true;
        if (wmiFS) {
            controlOut = 0x47;
            return kIOReturnSuccess;
        }
    }
    if (!wmiReportedFS && fullSpeedEngaged && activeFanControl[fan] == 0x47) {
        controlOut = 0x47;
        return kIOReturnSuccess;
    }

    if (mmioBase) {
        if (readMMIO8(kLegionRegLockFan) != 0x00)
            return kIOReturnIOError;
        if (!factoryCurveCaptured) {
            if (!customFanCurveActive && activeFanControl[fan] == 0x84) {
                controlOut = 0x84;
                return kIOReturnSuccess;
            }
            return kIOReturnNotReady;
        }
        const UInt8 size = readMMIO8(kLegionRegCurveSize);
        if (size == 0 || size > 10 || size != factoryCurveTable.pointCount)
            return kIOReturnIOError;
        if (readMMIO8(kLegionRegPowerMode) != capturedPowerMode) {
            controlOut = 0x84;
            return kIOReturnSuccess;
        }
        const UInt32 baseOffset = (fan == 0) ? kLegionRegFan1Base : kLegionRegFan2Base;
        if (activeFanControl[fan] >= 1 && activeFanControl[fan] <= 7 && activeTargetRPM[fan] > 0) {
            for (UInt8 i = 0; i < size; ++i) {
                const UInt16 actualRPM = static_cast<UInt16>(readMMIO8(baseOffset + i)) * 100;
                const UInt16 floorRPM = (fan == 0) ? factoryCurveTable.points[i].fan1RPM
                                                   : factoryCurveTable.points[i].fan2RPM;
                const UInt32 expected = activeTargetRPM[fan] > floorRPM ? activeTargetRPM[fan] : floorRPM;
                if (actualRPM < expected) {
                    controlOut = 0x84;
                    return kIOReturnSuccess;
                }
            }
            controlOut = activeFanControl[fan];
            return kIOReturnSuccess;
        }
        for (UInt8 i = 0; i < size; ++i) {
            const UInt16 actualRPM = static_cast<UInt16>(readMMIO8(baseOffset + i)) * 100;
            const UInt16 factoryRPM = (fan == 0) ? factoryCurveTable.points[i].fan1RPM
                                                 : factoryCurveTable.points[i].fan2RPM;
            if (actualRPM != factoryRPM)
                return kIOReturnIOError;
        }
        controlOut = 0x84;
        return kIOReturnSuccess;
    }

    if (legionBridge && ec && ec->validateObject("RYFM") == kIOReturnSuccess) {
        UInt32 ryfm = 0;
        if (ec->evaluateInteger("RYFM", &ryfm) != kIOReturnSuccess)
            return kIOReturnIOError;
        if (activeFanControl[fan] >= 1 && activeFanControl[fan] <= 7 && activeTargetRPM[fan] > 0) {
            const char *getter = (fan == 0) ? "RYG0" : "RYG1";
            UInt32 readbackRPM = 0;
            if ((ryfm & (1U << fan)) == 0 ||
                ec->evaluateInteger(getter, &readbackRPM) != kIOReturnSuccess ||
                readbackRPM < activeTargetRPM[fan]) {
                controlOut = 0x84;
                return kIOReturnSuccess;
            }
            controlOut = activeFanControl[fan];
            return kIOReturnSuccess;
        }
        controlOut = (ryfm & (1U << fan)) == 0 ? 0x84 : activeFanControl[fan];
        return kIOReturnSuccess;
    }

    return kIOReturnUnsupported;
}

IOReturn IdeaVPC::accessPlatformFanCurve(UInt32 fan, UInt32 requested, UInt8 output[3]) {
    if (!output || fan > 1 || !((requested >= 1 && requested <= 7) || requested == 0x47))
        return kIOReturnBadArgument;
    if (!legionFanWatchdog || getProperty("SafeMode") == kOSBooleanTrue)
        return kIOReturnUnsupported;
    if (fan && getProperty("Dual fan") != kOSBooleanTrue)
        return kIOReturnUnsupported;
    if (!commandGate || isInactive())
        return kIOReturnNotReady;
    struct Request {
        UInt32 fan, target;
        UInt8 *output;
    } request{fan, requested, output};
    return commandGate->runAction([](OSObject *owner, void *context, void *, void *, void *) -> IOReturn {
        auto self = static_cast<IdeaVPC *>(owner);
        auto request = static_cast<Request *>(context);
        if (self->stopping || self->isInactive())
            return kIOReturnNotAttached;
        const UInt64 prevDeadline = self->legionFanLease.deadline[request->fan];
        const bool running = self->legionFanLease.active();
        self->legionFanLease.renew(request->fan, legionFanTimeMS());
        if (!running)
            self->legionFanWatchdog->setTimeoutMS(1000);
        const IOReturn status = self->accessLegionFanGated(request->fan, request->target, request->output);
        if (status == kIOReturnBusy || status == kIOReturnUnsupported ||
            status == kIOReturnBadArgument || status == kIOReturnNotReady) {
            self->legionFanLease.deadline[request->fan] = prevDeadline;
            if (!self->legionFanLease.active())
                self->legionFanWatchdog->cancelTimeout();
        }
        return status;
    }, &request);
}

void IdeaVPC::expireLegionFanCurve(OSObject *, IOTimerEventSource *) {
    if (!commandGate)
        return;
    commandGate->runAction([](OSObject *owner, void *, void *, void *, void *) -> IOReturn {
        auto self = static_cast<IdeaVPC *>(owner);
        if (self->stopping || !self->legionFanWatchdog)
            return kIOReturnNotAttached;
        const UInt64 now = legionFanTimeMS();
        for (unsigned fan = 0; fan < 2; ++fan) {
            if (!self->legionFanLease.expired(fan, now))
                continue;
            UInt8 output[3]{};
            if (self->accessLegionFanGated(fan, 0x84, output) == kIOReturnSuccess) {
                self->legionFanLease.cancel(fan);
                self->setProperty("ThinkFanCurveStatus", "Watchdog confirmed BIOS Auto");
            } else {
                self->setProperty("ThinkFanStatus", "Curve watchdog: automatic fan restoration pending");
            }
        }
        if (self->legionFanLease.active())
            self->legionFanWatchdog->setTimeoutMS(1000);
        return kIOReturnSuccess;
    });
}

IOReturn IdeaVPC::accessPlatformFan(UInt32 fan, UInt32 requested, UInt8 output[3]) {
    if (!output || fan > 1 || (requested != ReYogaControl::kThinkFanQueryRPM && !ReYogaControl::validThinkFanLevel(requested)))
        return kIOReturnBadArgument;
    if (getProperty("SafeMode") == kOSBooleanTrue)
        return kIOReturnUnsupported;
    int bootArgument = 0;
    if (requested == 0 && !PE_parse_boot_argn("-reyfanstop", &bootArgument, sizeof(bootArgument)))
        return kIOReturnNotPermitted;
    if (!commandGate || isInactive())
        return kIOReturnNotReady;
    struct Request {
        UInt32 fan;
        UInt32 target;
        UInt8 *output;
    } request{fan, requested, output};
    return commandGate->runAction([](OSObject *owner, void *context, void *, void *, void *) -> IOReturn {
        auto self = static_cast<IdeaVPC *>(owner);
        auto request = static_cast<Request *>(context);
        if (self->stopping || self->isInactive())
            return kIOReturnNotAttached;
        const IOReturn status = self->accessLegionFanGated(request->fan, request->target, request->output);
        if (status == kIOReturnSuccess && request->target != ReYogaControl::kThinkFanQueryRPM)
            self->legionFanLease.cancel(request->fan);
        return status;
    }, &request);
}

IOReturn IdeaVPC::accessLegionFanGated(UInt32 fan, UInt32 requested, UInt8 output[3]) {
    if (!output || fan > 1)
        return kIOReturnBadArgument;
    if (fan && getProperty("Dual fan") != kOSBooleanTrue)
        return kIOReturnUnsupported;

    if (requested == ReYogaControl::kThinkFanQueryRPM) {
        UInt8 ctrl = 0;
        const IOReturn ctrlStatus = readHardwareFanControl(fan, ctrl);
        if (ctrlStatus != kIOReturnSuccess)
            return ctrlStatus;
        UInt32 rpm = 0;
        const IOReturn rpmStatus = readPlatformFanRPM(fan, rpm, nullptr);
        if (rpmStatus != kIOReturnSuccess)
            return rpmStatus;
        output[0] = static_cast<UInt8>(rpm & 0xff);
        output[1] = static_cast<UInt8>((rpm >> 8) & 0xff);
        output[2] = ctrl;
        return kIOReturnSuccess;
    }

    if (safeMode)
        return kIOReturnUnsupported;

    const UInt8 prevControl = activeFanControl[fan];
    const UInt32 prevTargetRPM = activeTargetRPM[fan];

    if (requested == 0x80 || requested == 0x84) {
        const bool otherFanActive = legionFanLease.deadline[1 - fan] != 0;
        if (!otherFanActive) {
            const IOReturn restoreStatus = restorePlatformFansGated();
            if (restoreStatus != kIOReturnSuccess)
                return restoreStatus;
        } else {
            if ((fullSpeedEngaged || activeFanControl[fan] == 0x47) && activeFanControl[1 - fan] != 0x47) {
                const IOReturn fsStatus = disengageFullSpeed();
                if (fsStatus != kIOReturnSuccess)
                    return fsStatus;
            }
            if (mmioBase && captureFactoryCurveTable()) {
                LegionFanCurveTable partial = customFanCurveActive ? activeCurveTable : factoryCurveTable;
                for (UInt8 i = 0; i < partial.pointCount && i < factoryCurveTable.pointCount; ++i) {
                    if (fan == 0)
                        partial.points[i].fan1RPM = factoryCurveTable.points[i].fan1RPM;
                    else
                        partial.points[i].fan2RPM = factoryCurveTable.points[i].fan2RPM;
                }
                const IOReturn applyStatus = applyLegionFanCurveTable(partial, false, true);
                if (applyStatus != kIOReturnSuccess)
                    return applyStatus;
                activeFanControl[fan] = 0x84;
                activeTargetRPM[fan] = 0;
                legionFanLease.cancel(fan);
            } else {
                return kIOReturnUnsupported;
            }
        }
    } else if (requested == 0x40 || requested == 0x47) {
        const IOReturn fsStatus = engageFullSpeed();
        if (fsStatus != kIOReturnSuccess)
            return fsStatus;
        activeFanControl[fan] = 0x47;
        activeTargetRPM[fan] = 0;
    } else if (requested >= 1 && requested <= 7) {
        if ((fullSpeedEngaged || activeFanControl[fan] == 0x47) && activeFanControl[1 - fan] != 0x47) {
            const IOReturn fsStatus = disengageFullSpeed();
            if (fsStatus != kIOReturnSuccess)
                return fsStatus;
        }
        if (fullSpeedEngaged && activeFanControl[1 - fan] == 0x47)
            return kIOReturnBusy;

        UInt32 targetRPM = 0;
        if (mmioBase && captureFactoryCurveTable() && factoryCurveTable.pointCount >= 1) {
            const UInt8 last = factoryCurveTable.pointCount - 1;
            const UInt16 minRPM = (fan == 0) ? factoryCurveTable.points[0].fan1RPM : factoryCurveTable.points[0].fan2RPM;
            const UInt16 maxRPM = (fan == 0) ? factoryCurveTable.points[last].fan1RPM : factoryCurveTable.points[last].fan2RPM;
            if (maxRPM < 100)
                return kIOReturnIOError;
            const UInt32 baseMin = minRPM > 0 ? minRPM : ((static_cast<UInt32>(maxRPM) + 6U) / 7U);
            const UInt32 rawRPM = baseMin + ((static_cast<UInt32>(maxRPM) - baseMin) * (requested - 1U)) / 6U;
            targetRPM = ((rawRPM + 50U) / 100U) * 100U;
            if (targetRPM > 6000)
                targetRPM = 6000;
            if (targetRPM < minRPM)
                targetRPM = minRPM;
        } else if (legionBridge && ec && ec->validateObject(fan == 0 ? "RYM0" : "RYM1") == kIOReturnSuccess) {
            UInt32 maxRPM = 0;
            if (ec->evaluateInteger(fan == 0 ? "RYM0" : "RYM1", &maxRPM) != kIOReturnSuccess || maxRPM < 100 || maxRPM > 6000)
                return kIOReturnIOError;
            const UInt32 rawRPM = (maxRPM * requested) / 7U;
            targetRPM = ((rawRPM + 50U) / 100U) * 100U;
            if (targetRPM < 100)
                targetRPM = 100;
            if (targetRPM > maxRPM)
                targetRPM = maxRPM;
        } else {
            return kIOReturnNotReady;
        }

        if (legionBridge && ec && ec->validateObject("RYFS") == kIOReturnSuccess) {
            UInt32 verified = 0;
            if (legionBridgeVersion < 2 || ec->evaluateInteger("RYVW", &verified) != kIOReturnSuccess || verified != 1)
                return kIOReturnUnsupported;
            OSObject *args[] = {OSNumber::withNumber(fan, 32), OSNumber::withNumber(targetRPM, 32)};
            if (!args[0] || !args[1]) {
                OSSafeReleaseNULL(args[0]);
                OSSafeReleaseNULL(args[1]);
                return kIOReturnNoMemory;
            }
            UInt32 ecResult = 1;
            const IOReturn ryfsStatus = ec->evaluateInteger("RYFS", &ecResult, args, 2);
            args[0]->release();
            args[1]->release();
            if (ryfsStatus != kIOReturnSuccess)
                return ryfsStatus;
            if (ecResult != 0)
                return kIOReturnIOError;
        } else if (mmioBase) {
            if (!captureFactoryCurveTable())
                return kIOReturnIOError;
            LegionFanCurveTable nextTable = customFanCurveActive ? activeCurveTable : factoryCurveTable;
            for (UInt8 i = 0; i < nextTable.pointCount && i < factoryCurveTable.pointCount; ++i) {
                if (fan == 0) {
                    const UInt16 floorRPM = factoryCurveTable.points[i].fan1RPM;
                    nextTable.points[i].fan1RPM = static_cast<UInt16>(targetRPM > floorRPM ? targetRPM : floorRPM);
                } else {
                    const UInt16 floorRPM = factoryCurveTable.points[i].fan2RPM;
                    nextTable.points[i].fan2RPM = static_cast<UInt16>(targetRPM > floorRPM ? targetRPM : floorRPM);
                }
            }
            const IOReturn applyStatus = applyLegionFanCurveTable(nextTable, false, true);
            if (applyStatus != kIOReturnSuccess)
                return applyStatus;
        } else {
            return kIOReturnUnsupported;
        }

        activeFanControl[fan] = static_cast<UInt8>(requested);
        activeTargetRPM[fan] = targetRPM;
    } else if (requested == 0) {
        return kIOReturnUnsupported;
    } else {
        return kIOReturnBadArgument;
    }

    UInt8 hwCtrl = 0;
    const IOReturn hwStatus = readHardwareFanControl(fan, hwCtrl);
    if (hwStatus != kIOReturnSuccess) {
        activeFanControl[fan] = prevControl;
        activeTargetRPM[fan] = prevTargetRPM;
        return hwStatus;
    }

    bool confirmed = false;
    if (requested == 0x80 || requested == 0x84)
        confirmed = (hwCtrl & 0x80) != 0 || (activeFanControl[1 - fan] == 0x47 && (hwCtrl & 0x40) != 0);
    else if (requested == 0x40 || requested == 0x47)
        confirmed = (hwCtrl & 0x40) != 0;
    else
        confirmed = hwCtrl == requested;

    if (!confirmed) {
        activeFanControl[fan] = prevControl;
        activeTargetRPM[fan] = prevTargetRPM;
        return kIOReturnIOError;
    }

    UInt32 rpm = 0;
    const IOReturn rpmStatus = readPlatformFanRPM(fan, rpm, nullptr);
    if (rpmStatus == kIOReturnSuccess) {
        output[0] = static_cast<UInt8>(rpm & 0xff);
        output[1] = static_cast<UInt8>((rpm >> 8) & 0xff);
    } else {
        output[0] = 0xff;
        output[1] = 0xff;
    }
    output[2] = hwCtrl;
    return kIOReturnSuccess;
}

IOReturn IdeaVPC::readPlatformFanRPM(UInt32 fan, UInt32 &rpm, UInt8 *control) {
    if (fan > 1)
        return kIOReturnBadArgument;
    if (fan && getProperty("Dual fan") != kOSBooleanTrue)
        return kIOReturnUnsupported;

    UInt32 readRPM = 0;
    bool gotRPM = false;

    if (mmioBase) {
        const UInt32 offset = (fan == 0) ? kLegionRegFan1RPM : kLegionRegFan2RPM;
        readRPM = readMMIO16(offset);
        if (readRPM < 20000)
            gotRPM = true;
    }

    if (!gotRPM && ec) {
        const char *acpiRPM = (fan == 0) ? "RYR0" : "RYR1";
        UInt32 raw = 0;
        if (ec->evaluateInteger(acpiRPM, &raw) == kIOReturnSuccess && raw < 20000) {
            readRPM = raw;
            gotRPM = true;
        } else if (nativeProfile && nativeProfile->fields[fan ? ReYogaSensor::Fan2 : ReYogaSensor::Fan1][0] != '\0') {
            const char *path = nativeProfile->fields[fan ? ReYogaSensor::Fan2 : ReYogaSensor::Fan1];
            const char *leaf = path;
            while (const char *dot = strchr(leaf, '.'))
                leaf = dot + 1;
            if ((ec->evaluateInteger(leaf, &raw) == kIOReturnSuccess ||
                 (vpc && vpc->evaluateInteger(leaf, &raw) == kIOReturnSuccess)) &&
                raw < 0xFFFF) {
                const UInt32 scaled = raw * (nativeProfile->scales[fan ? ReYogaSensor::Fan2 : ReYogaSensor::Fan1]);
                if (scaled < 20000) {
                    readRPM = scaled;
                    gotRPM = true;
                }
            }
        }
    }

    if (!gotRPM || readRPM >= 20000 || readRPM == 0xFFFF) {
        rpm = 0;
        if (control)
            *control = 0xff;
        return kIOReturnUnderrun;
    }

    rpm = readRPM;

    if (control) {
        UInt8 hwCtrl = 0xff;
        if (readHardwareFanControl(fan, hwCtrl) == kIOReturnSuccess)
            *control = hwCtrl;
        else
            *control = 0xff;
    }

    return kIOReturnSuccess;
}

void IdeaVPC::restorePlatformFans() {
    if (!commandGate || getProperty("SafeMode") == kOSBooleanTrue)
        return;
    commandGate->runAction([](OSObject *owner, void *, void *, void *, void *) -> IOReturn {
        auto self = static_cast<IdeaVPC *>(owner);
        return self->restorePlatformFansGated();
    });
}

IOReturn IdeaVPC::restorePlatformFansGated(bool ecReloadedCurve) {
    legionFanLease.cancel(0);
    legionFanLease.cancel(1);
    if (legionFanWatchdog)
        legionFanWatchdog->cancelTimeout();
    activeFanControl[0] = 0x84;
    activeFanControl[1] = 0x84;
    activeTargetRPM[0] = 0;
    activeTargetRPM[1] = 0;

    IOReturn status = kIOReturnSuccess;
    const bool wasCustomActive = customFanCurveActive;

    const bool modeSwitched = ecReloadedCurve ||
        (mmioBase && factoryCurveCaptured && readMMIO8(kLegionRegPowerMode) != capturedPowerMode);
    if (modeSwitched) {
        customFanCurveActive = false;
        factoryCurveCaptured = false;
    } else if (wasCustomActive && factoryCurveCaptured && mmioBase && !safeMode) {
        const IOReturn applyStatus = applyLegionFanCurveTable(factoryCurveTable, true);
        if (applyStatus != kIOReturnSuccess)
            status = applyStatus;
        else
            customFanCurveActive = false;
    } else {
        customFanCurveActive = false;
    }

    if (legionBridge && ec && ec->validateObject("RYFA") == kIOReturnSuccess && !safeMode) {
        UInt32 result = 0;
        const IOReturn ryfaStatus = ec->evaluateInteger("RYFA", &result);
        if (ryfaStatus != kIOReturnSuccess || result != 0)
            status = kIOReturnIOError;
    }

    if (!safeMode && (fullSpeedEngaged || getProperty(fullFanPrompt) == kOSBooleanTrue)) {
        const IOReturn fsStatus = disengageFullSpeed();
        if (fsStatus != kIOReturnSuccess && status == kIOReturnSuccess)
            status = fsStatus;
    }

    if (mmioBase && !safeMode) {
        writeMMIO8(kLegionRegLockFan, 0x00);
        writeMMIO8(kLegionRegCurvePoint, 0x00);
        writeMMIO8(kLegionRegCPULevel, 0x00);
        writeMMIO8(kLegionRegGPULevel, 0x00);
        writeMMIO8(kLegionRegHSTLevel, 0x00);
        if (readMMIO8(kLegionRegLockFan) != 0x00)
            status = kIOReturnIOError;
    }

    removeProperty("ThinkFanStatus");
    return status;
}
