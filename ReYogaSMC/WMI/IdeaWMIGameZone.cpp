// SPDX-License-Identifier: GPL-2.0-only
// Original work: Copyright (c) 2020 Zhen.

#include "IdeaWMI.hpp"
#include <pexpert/pexpert.h>

OSDefineMetaClassAndStructors(IdeaWMIGameZone, ReYogaWMI);

const char *IdeaWMIGameZone::registerEvent(OSString *guid, UInt32 id) {
    if (guid->isEqualTo(GAME_ZONE_TEMP_WMI_EVENT))
        tempEvent = id;
    else if (guid->isEqualTo(GAME_ZONE_OC_WMI_EVENT))
        OCEvent = id;
    else if (guid->isEqualTo(GAME_ZONE_GPU_WMI_EVENT))
        GPUEvent = id;
    else if (guid->isEqualTo(GAME_ZONE_FAN_WMI_EVENT))
        fanEvent = id;
    else if (guid->isEqualTo(GAME_ZONE_KEY_WMI_EVENT))
        keyEvent = id;
    else if (guid->isEqualTo(GAME_ZONE_SMART_FAN_EVENT))
        smartFanEvent = id;
    else if (guid->isEqualTo(GAME_ZONE_THERMAL_EVENT))
        thermalEvent = id;
    else if (guid->isEqualTo(GAME_ZONE_CHARGE_EVENT))
        chargeEvent = id;
    else
        return nullptr;
    return feature;
}

bool IdeaWMIGameZone::getGameZoneData(UInt32 query, UInt32 *result) {
    IOReturn ret;
    OSNumber *in;

    in = OSNumber::withNumber(0ULL, 32);
    if (in == nullptr)
        return false;
    ret = YWMI->evaluateInteger(GAME_ZONE_DATA_WMI_METHOD, 0, query, result, in, true);
    OSSafeReleaseNULL(in);

    if (ret != kIOReturnSuccess)
        AlwaysLog("Query %d evaluation failed", query);

    return (ret == kIOReturnSuccess);
}

bool IdeaWMIGameZone::setGameZoneData(UInt32 query, UInt32 value) {
    IOReturn ret;
    OSNumber *in;
    UInt32 result = 0;

    in = OSNumber::withNumber(static_cast<uint64_t>(value), 32);
    if (in == nullptr)
        return false;
    ret = YWMI->evaluateInteger(GAME_ZONE_DATA_WMI_METHOD, 0, query, &result, in, true);
    OSSafeReleaseNULL(in);

    if (ret != kIOReturnSuccess)
        AlwaysLog("Set query %d evaluation failed", query);

    return (ret == kIOReturnSuccess);
}

bool IdeaWMIGameZone::getFanSpeed(UInt32 fanId, UInt32 *result) {
    if (!hasFanMethod)
        return false;
    IOReturn ret;
    OSNumber *in = OSNumber::withNumber(static_cast<uint64_t>(fanId), 32);
    if (in == nullptr)
        return false;
    ret = YWMI->evaluateInteger(LENOVO_FAN_METHOD, 0, 7, result, in, true);
    OSSafeReleaseNULL(in);
    return (ret == kIOReturnSuccess);
}

bool IdeaWMIGameZone::getSensorTemperature(UInt32 sensorId, UInt32 *result) {
    if (!hasFanMethod)
        return false;
    IOReturn ret;
    OSNumber *in = OSNumber::withNumber(static_cast<uint64_t>(sensorId), 32);
    if (in == nullptr)
        return false;
    ret = YWMI->evaluateInteger(LENOVO_FAN_METHOD, 0, 8, result, in, true);
    OSSafeReleaseNULL(in);
    return (ret == kIOReturnSuccess);
}

bool IdeaWMIGameZone::getCPUTemperature(UInt32 *result) {
    bool ok = hasFanMethod ? getSensorTemperature(3, result) : getGameZoneData(GAME_ZONE_WMI_GET_TMP_CPU, result);
    return ok && *result < 125;
}

bool IdeaWMIGameZone::getGPUTemperature(UInt32 *result) {
    bool ok = hasFanMethod ? getSensorTemperature(4, result) : getGameZoneData(GAME_ZONE_WMI_GET_TMP_GPU, result);
    // A powered-off dGPU may return zero; the telemetry layer labels it.
    return ok && *result < 125;
}

bool IdeaWMIGameZone::supportsFanFullSpeed() {
    return hasFanMethod || (YWMI && YWMI->hasMethod(GAME_ZONE_DATA_WMI_METHOD));
}

bool IdeaWMIGameZone::setFanFullSpeed(bool enable) {
    IOReturn ret = kIOReturnUnsupported;
    OSObject *result = nullptr;
    OSNumber *in = OSNumber::withNumber(enable ? 1ULL : 0ULL, 32);
    if (in == nullptr)
        return false;
    if (hasFanMethod) {
        // On Legion WMB2 (LENOVO_FAN_METHOD): Method 2 is SET full speed
        ret = YWMI->evaluateMethod(LENOVO_FAN_METHOD, 0, 2, &result, in, true);
    }
    if (ret != kIOReturnSuccess && YWMI->hasMethod(GAME_ZONE_DATA_WMI_METHOD)) {
        // On Legion WMAA (GAME_ZONE_DATA_WMI_METHOD): Method 0x0D is SET full speed
        ret = YWMI->evaluateMethod(GAME_ZONE_DATA_WMI_METHOD, 0, GAME_ZONE_WMI_SET_FAN_COOLING, &result, in, true);
    }
    OSSafeReleaseNULL(result);
    OSSafeReleaseNULL(in);
    return (ret == kIOReturnSuccess);
}

bool IdeaWMIGameZone::getFanFullSpeed(bool *enabled) {
    removeProperty("FanFullSpeedRaw");
    if (!enabled)
        return false;
    IOReturn ret = kIOReturnUnsupported;
    UInt32 result = 0;
    if (hasFanMethod) {
        // On Legion WMB2 (LENOVO_FAN_METHOD): Method 1 is GET full speed (FCST & 1)
        ret = YWMI->evaluateInteger(LENOVO_FAN_METHOD, 0, 1, &result, nullptr, true);
    }
    if (ret != kIOReturnSuccess && YWMI->hasMethod(GAME_ZONE_DATA_WMI_METHOD)) {
        // On Legion WMAA (GAME_ZONE_DATA_WMI_METHOD): Method 0x14 is GET full speed
        ret = YWMI->evaluateInteger(GAME_ZONE_DATA_WMI_METHOD, 0, GAME_ZONE_WMI_GET_FAN_STA, &result, nullptr, true);
    }
    if (ret == kIOReturnSuccess) {
        setProperty("FanFullSpeedRaw", result, 32);
        *enabled = (result & 1) != 0;
        return true;
    }
    return false;
}

bool IdeaWMIGameZone::supportsStateLighting(UInt8 component) {
    const char *reasonKey = component == 3 ? "LogoLightingReason" : "PortLightingReason";
    const UInt8 count = YWMI->getInstanceCount(LENOVO_LIGHTING_DATA);
    if (!count || count > 32) {
        setProperty(reasonKey, !count ? "LENOVO_LIGHTING_DATA provider unavailable" : "Invalid lighting capability count");
        return false;
    }
    for (UInt32 instance = 0; instance < count; ++instance) {
        OSObject *result = nullptr;
        IOReturn status = YWMI->queryBlock(LENOVO_LIGHTING_DATA, instance, &result, true);
        auto data = OSDynamicCast(OSData, result);
        if (status == kIOReturnSuccess && data && data->getLength() == 7) {
            const auto bytes = static_cast<const UInt8 *>(data->getBytesNoCopy());
            if (bytes[0] == component) {
                setProperty(component == 3 ? "LogoLightingCapability" : "PortLightingCapability", data);
                const bool supported = bytes[1] == 1 && bytes[2] == 0 && bytes[3] >= 2;
                setProperty(reasonKey, supported ? "State-control interface advertised" : bytes[1] != 1 ? "Firmware assigns this light to another control interface; USB RGB may provide it"
                                                                                      : bytes[2] != 0   ? "Firmware does not advertise an on/off lighting type"
                                                                                                        : "Firmware does not advertise two lighting states");
                result->release();
                return supported;
            }
        }
        OSSafeReleaseNULL(result);
    }
    setProperty(reasonKey, "Lighting capability record missing or query failed");
    return false;
}

bool IdeaWMIGameZone::getYLogoStatus(bool *enabled) {
    removeProperty("YLogoRawState");
    removeProperty("YLogoRawBrightness");
    if (!hasLightingMethod || !supportsStateLighting(3))
        return false;
    if (!enabled)
        return false;
    const UInt8 component = 3;
    OSData *in = OSData::withBytes(&component, sizeof(component));
    if (in == nullptr)
        return false;
    OSObject *result = nullptr;
    IOReturn ret = YWMI->evaluateMethod(LENOVO_LIGHTING_METHOD, 0, 1, &result, in, true);
    OSSafeReleaseNULL(in);
    if (ret == kIOReturnSuccess && result) {
        OSData *data = OSDynamicCast(OSData, result);
        if (data && data->getLength() == 2) {
            const UInt8 *bytes = static_cast<const UInt8 *>(data->getBytesNoCopy());
            setProperty("YLogoRawState", bytes[0], 8);
            setProperty("YLogoRawBrightness", bytes[1], 8);
            // LCST uses 1=on. Older one-bit EC fields read back 0 for off; newer interfaces may return 2.
            if (bytes[0] > 2) {
                result->release();
                return false;
            }
            *enabled = bytes[0] == 1;
            result->release();
            return true;
        }
        result->release();
    }
    setProperty("LogoLightingReason", "WMI lighting state read failed or returned an invalid record");
    return false;
}

bool IdeaWMIGameZone::setYLogoStatus(bool enable) {
    return setComponentLighting(3, enable);
}

bool IdeaWMIGameZone::getPortLightingStatus(bool *enabled) {
    removeProperty("PortLightingRawState");
    removeProperty("PortLightingRawBrightness");
    if (!hasLightingMethod || !supportsStateLighting(5))
        return false;
    if (!enabled)
        return false;
    const UInt8 component = 5;
    OSData *in = OSData::withBytes(&component, sizeof(component));
    if (in == nullptr)
        return false;
    OSObject *result = nullptr;
    IOReturn ret = YWMI->evaluateMethod(LENOVO_LIGHTING_METHOD, 0, 1, &result, in, true);
    OSSafeReleaseNULL(in);
    if (ret == kIOReturnSuccess && result) {
        OSData *data = OSDynamicCast(OSData, result);
        if (data && data->getLength() == 2) {
            const UInt8 *bytes = static_cast<const UInt8 *>(data->getBytesNoCopy());
            setProperty("PortLightingRawState", bytes[0], 8);
            setProperty("PortLightingRawBrightness", bytes[1], 8);
            // PortsBacklightState is byte 0, matching Lenovo Legion Toolkit.
            if (bytes[0] > 2) {
                result->release();
                return false;
            }
            *enabled = bytes[0] == 1;
            result->release();
            return true;
        }
        result->release();
    }
    setProperty("PortLightingReason", "WMI lighting state read failed or returned an invalid record");
    return false;
}

bool IdeaWMIGameZone::setPortLightingStatus(bool enable) {
    return setComponentLighting(5, enable);
}

bool IdeaWMIGameZone::setComponentLighting(UInt8 component, bool enable) {
    if (!hasLightingMethod)
        return false;
    if (component != 3 && component != 5)
        return false;
    if (!supportsStateLighting(component))
        return false;
    // Acquire the firmware's software-lighting owner before applying a state.
    if (!setGameZoneData(GAME_ZONE_WMI_SET_LIGHT_CTL, 1)) {
        setProperty("LightingCommandStage", "ownership");
        return false;
    }
    setProperty("LightingCommandStage", "state");
    auto input = OSData::withBytes(&component, sizeof(component));
    if (input == nullptr)
        return false;
    OSObject *result = nullptr;
    IOReturn ret = YWMI->evaluateMethod(LENOVO_LIGHTING_METHOD, 0, 1, &result, input, true);
    input->release();
    auto data = OSDynamicCast(OSData, result);
    if (ret != kIOReturnSuccess || !data || data->getLength() != 2) {
        OSSafeReleaseNULL(result);
        return false;
    }
    // Toolkit's panel-logo and ports features use state 1/2 with level 0.
    // https://github.com/LenovoLegionToolkit-Team/LenovoLegionToolkit/blob/master/LenovoLegionToolkit.Lib/Features/PortsBacklightFeature.cs
    const auto current = static_cast<const UInt8 *>(data->getBytesNoCopy());
    if (current[0] > 2) {
        result->release();
        return false;
    }
    UInt8 bytes[3] = {component, static_cast<UInt8>(enable ? 1 : 2), 0};
    OSSafeReleaseNULL(result);
    auto payload = OSData::withBytes(bytes, sizeof(bytes));
    if (!payload)
        return false;
    ret = YWMI->evaluateMethod(LENOVO_LIGHTING_METHOD, 0, 2, &result, payload, true);
    payload->release();
    OSSafeReleaseNULL(result);
    return ret == kIOReturnSuccess;
}

void IdeaWMIGameZone::processWMI() {
    int bootArgument = 0;
    cpuPowerAccessEnabled = PE_parse_boot_argn("-reycpupower", &bootArgument, sizeof(bootArgument));
    setProperty("CPUPowerAccessEnabled", cpuPowerAccessEnabled);
    setProperty("Feature", feature);

    hasFanMethod = YWMI->hasMethod(LENOVO_FAN_METHOD);
    hasLightingMethod = YWMI->hasMethod(LENOVO_LIGHTING_METHOD);

    if (hasFanMethod)
        setProperty("LenovoFanMethod", true);
    if (hasLightingMethod)
        setProperty("LenovoLightingMethod", true);

    UInt32 result;

    if (getGameZoneData(GAME_ZONE_WMI_GET_VERSION, &result))
        setProperty("Game Zone Version", result, 32);
    else
        AlwaysLog("Failed to get version");

    // Newer firmware can advertise the legacy Game Zone fan getter but fail
    // when it is called. The table block supplies its actual instance count.
    fanCount = hasFanMethod ? YWMI->getInstanceCount(LENOVO_FAN_TABLE_DATA) : 0;
    if (!fanCount && getGameZoneData(GAME_ZONE_WMI_GET_FAN_NUM, &result))
        fanCount = result;
    if (fanCount > 16)
        fanCount = 0;
    if (fanCount)
        setProperty("Fan number", fanCount, 32);
    else
        removeProperty("Fan number");

    if (hasFanMethod && fanCount) {
        if (getFanSpeed(0, &result))
            setProperty("Fan1Speed", result, 32);
        if (fanCount > 1 && getFanSpeed(1, &result))
            setProperty("Fan2Speed", result, 32);
    } else if (!fanCount) {
        AlwaysLog("Failed to get fan number");
    }

    if (getGameZoneData(GAME_ZONE_WMI_CAP_KEYBOARD, &result))
        setProperty("Keyboard Feature", result, 32);
    else
        AlwaysLog("Failed to get keyboard feature");

    if (getGameZoneData(GAME_ZONE_WMI_GET_SMARTFAN_MODE, &result))
        setProperty("SmartFanMode", result, 32);

    if (getGameZoneData(GAME_ZONE_WMI_GET_OVER_DRIVE, &result))
        setProperty("DisplayOverDrive", result, 32);
}

void IdeaWMIGameZone::ACPIEvent(UInt32 argument) {
    if (argument == smartFanEvent) {
        UInt32 mode = 0;
        if (getGameZoneData(GAME_ZONE_WMI_GET_SMARTFAN_MODE, &mode))
            setProperty("SmartFanMode", mode, 32);
        return;
    }
    if (argument == keyEvent) {
        UInt32 state = 0;
        if (getGameZoneData(GAME_ZONE_WMI_GET_WIN_KEY, &state))
            setProperty("WinKeyLock", state, 32);
        if (getGameZoneData(GAME_ZONE_WMI_GET_TOUCHPAD, &state))
            setProperty("TouchpadLock", state, 32);
        return;
    }

    OSObject *result = nullptr;
    OSNumber *id;
    if (YWMI->getEventData(argument, &result) && (id = (OSDynamicCast(OSNumber, result))))
        DebugLog("message: ACPI notification 0x%04x - 0x%04x", argument, id->unsigned32BitValue());
    else
        AlwaysLog("message: Unknown ACPI notification 0x%04x", argument);
    OSSafeReleaseNULL(result);
}

bool IdeaWMIGameZone::getPowerLimit(UInt32 query, UInt32 range[4]) {
    // Firmware getters may initialize SystemMemory fields; never probe implicitly.
    if (!cpuPowerAccessEnabled || (query != 3 && query != 5) || !range)
        return false;
    if (!YWMI->hasMethod(LENOVO_CPU_METHOD))
        return false;
    OSObject *result = nullptr;
    auto input = OSNumber::withNumber(0ULL, 32);
    if (input == nullptr)
        return false;
    IOReturn ret = YWMI->evaluateMethod(LENOVO_CPU_METHOD, 0, query, &result, input, true);
    input->release();
    auto data = OSDynamicCast(OSData, result);
    bool valid = ret == kIOReturnSuccess && data && data->getLength() == 16;
    if (valid) {
        const auto bytes = static_cast<const UInt8 *>(data->getBytesNoCopy());
        for (unsigned i = 0; i < 4; ++i)
            range[i] = UInt32(bytes[i * 4]) | UInt32(bytes[i * 4 + 1]) << 8 |
                       UInt32(bytes[i * 4 + 2]) << 16 | UInt32(bytes[i * 4 + 3]) << 24;
        valid = range[1] > 0 && range[2] <= range[0] && range[0] <= range[3] && range[2] < range[3];
    }
    OSSafeReleaseNULL(result);
    return valid;
}

bool IdeaWMIGameZone::setPowerLimit(UInt32 query, UInt32 watts) {
    if (!cpuPowerAccessEnabled || (query != 4 && query != 6))
        return false;
    OSObject *result = nullptr;
    auto input = OSNumber::withNumber(watts, 32);
    if (input == nullptr)
        return false;
    IOReturn ret = YWMI->evaluateMethod(LENOVO_CPU_METHOD, 0, query, &result, input, true);
    input->release();
    OSSafeReleaseNULL(result);
    return ret == kIOReturnSuccess;
}
