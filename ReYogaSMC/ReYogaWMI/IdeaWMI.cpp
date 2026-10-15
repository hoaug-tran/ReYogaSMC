//  SPDX-License-Identifier: GPL-2.0-only
//
//  IdeaWMI.cpp
//  ReYogaSMC
//
//  Created by Zhen on 2020/6/23.
//  Copyright © 2020 Zhen. All rights reserved.
//

#include "IdeaWMI.hpp"

ReYogaWMI* ReYogaWMI::withIdeaWMI(WMI *provider) {
    ReYogaWMI* dev = nullptr;

    if ((provider->hasMethod(GSENSOR_WMI_EVENT, ACPI_WMI_EVENT) && provider->hasMethod(GSENSOR_DATA_WMI_METHOD)) ||
        (provider->hasMethod(GSENSOR_WMI_EVENT_EXT, ACPI_WMI_EVENT) && provider->hasMethod(GSENSOR_DATA_WMI_METHOD_EXT))) {
        dev = OSTypeAlloc(IdeaWMIYoga);
        dev->isPMsupported = true;
    } else if (provider->hasMethod(PAPER_LOOKING_WMI_EVENT, ACPI_WMI_EVENT)) {
        dev = OSTypeAlloc(IdeaWMIPaper);
    } else if (provider->hasMethod(SUPER_RES_WMI_EVENT, ACPI_WMI_EVENT)) {
        dev = OSTypeAlloc(IdeaWMISuperRes);
    } else if (provider->hasMethod(BAT_INFO_WMI_STRING, ACPI_WMI_EXPENSIVE | ACPI_WMI_STRING)) {
        dev = OSTypeAlloc(IdeaWMIBattery);
    } else if (provider->hasMethod(GAME_ZONE_DATA_WMI_METHOD) || provider->hasMethod(LENOVO_FAN_METHOD)) {
        dev = OSTypeAlloc(IdeaWMIGameZone);
    } else {
        dev = OSTypeAlloc(ReYogaWMI);
    }

    OSDictionary *dictionary = OSDictionary::withCapacity(1);

    dev->iname = provider->getName();
    dev->YWMI = provider;

    if (!dev->init(dictionary))
        OSSafeReleaseNULL(dev);

    dictionary->release();
    return dev;
}

OSDefineMetaClassAndStructors(IdeaWMIYoga, ReYogaWMI);

const char* IdeaWMIYoga::registerEvent(OSString *guid, UInt32 id) {
    if (!guid->isEqualTo(GSENSOR_WMI_EVENT)) {
        if (!guid->isEqualTo(GSENSOR_WMI_EVENT_EXT))
            return nullptr;
        extension = true;
    }
    YogaEvent = id;
    return feature;
}

void IdeaWMIYoga::ACPIEvent(UInt32 argument) {
    if (argument != YogaEvent) {
        super::ACPIEvent(argument);
        return;
    }

    DebugLog("message: ACPI notification 0x%02X", argument);
    updateYogaMode();
}

void IdeaWMIYoga::processWMI() {
    setProperty("Feature", feature);
}

void IdeaWMIYoga::updateYogaMode() {
    IOReturn ret;
    OSNumber *in;
    UInt32 value;

    in = OSNumber::withNumber(0ULL, 32);
    ret = YWMI->evaluateInteger(extension ? GSENSOR_DATA_WMI_METHOD_EXT : GSENSOR_DATA_WMI_METHOD,
                                0, GSENSOR_DATA_WMI_UASGE_MODE, &value, in, true);
    OSSafeReleaseNULL(in);

    if (ret != kIOReturnSuccess) {
        setProperty("YogaMode", false);
        AlwaysLog(updateFailure, "YogaMode");
        return;
    }

    DebugLog("YogaMode: %d", value);
    bool sync = updateTopCase();
    if (YogaMode == value && sync)
        return;

    bool clamshellMode = false;

    switch (value) {
        case kYogaMode_laptop:
            setTopCase(true);
            setProperty("YogaMode", "Laptop");
            break;

        case kYogaMode_tablet:
            if (YogaMode == kYogaMode_laptop || !sync)
                setTopCase(clamshellMode);
            setProperty("YogaMode", "Tablet");
            break;

        case kYogaMode_stand:
            if (YogaMode == kYogaMode_laptop || !sync)
                setTopCase(clamshellMode);
            setProperty("YogaMode", "Stand");
            break;

        case kYogaMode_tent:
            if (YogaMode == kYogaMode_laptop || !sync)
                setTopCase(clamshellMode);
            setProperty("YogaMode", "Tent");
            break;

        default:
            AlwaysLog("Unknown yoga mode: %d", value);
            setProperty("YogaMode", value, 32);
            return;
    }
    YogaMode = value;
    dispatchMessage(kSMC_YogaEvent, &YogaMode);
}

void IdeaWMIYoga::stop(IOService *provider) {
    if (YogaMode != kYogaMode_laptop) {
        DebugLog("Re-enabling top case");
        setTopCase(true);
    }
    super::stop(provider);
}

IOReturn IdeaWMIYoga::setPowerState(unsigned long powerStateOrdinal, IOService * whatDevice) {
    if (super::setPowerState(powerStateOrdinal, whatDevice) != kIOPMAckImplied)
        return kIOReturnInvalid;

    if (powerStateOrdinal == 0) {
        if (YogaMode != kYogaMode_laptop) {
            DebugLog("Re-enabling top case");
            setTopCase(true);
        }
    } else {
        updateYogaMode();
    }

    return kIOPMAckImplied;
}

OSDefineMetaClassAndStructors(IdeaWMIPaper, ReYogaWMI);

const char* IdeaWMIPaper::registerEvent(OSString *guid, UInt32 id) {
    if (guid->isEqualTo(PAPER_LOOKING_WMI_EVENT)) {
        paperEvent = id;
        return feature;
    }
    return nullptr;
}

void IdeaWMIPaper::ACPIEvent(UInt32 argument) {
    if (argument != paperEvent) {
        super::ACPIEvent(argument);
        return;
    }

    DebugLog("message: ACPI notification 0x%02X, toggle FnLock", argument);
    // force enable keyboard and touchpad
    setTopCase(true);
    dispatchMessage(kSMC_FnlockEvent, NULL);
}

void IdeaWMIPaper::processWMI() {
    setProperty("Feature", feature);
}

OSDefineMetaClassAndStructors(IdeaWMISuperRes, ReYogaWMI);

const char* IdeaWMISuperRes::registerEvent(OSString *guid, UInt32 id) {
    if (guid->isEqualTo(SUPER_RES_WMI_EVENT)) {
        SREvent = id;
        return feature;
    }
    return nullptr;
}

void IdeaWMISuperRes::ACPIEvent(UInt32 argument) {
    if (argument != SREvent) {
        super::ACPIEvent(argument);
        return;
    }

    IOReturn ret;
    OSNumber *in;
    UInt32 value;

    in = OSNumber::withNumber(0ULL, 32);
    ret = YWMI->evaluateInteger(SUPER_RES_DATA_WMI_METHOD, 0, SUPER_RES_DATA_WMI_VALUE, &value, in, true);
    OSSafeReleaseNULL(in);

    if (ret != kIOReturnSuccess) {
        AlwaysLog(updateFailure, "Super resolution");
        DebugLog("message: ACPI notification 0x%02X, toggle FnLock", argument);
    } else {
        DebugLog("message: ACPI notification 0x%02X %d, toggle FnLock", argument, value);
    }

    // force enable keyboard and touchpad
    setTopCase(true);
    dispatchMessage(kSMC_FnlockEvent, NULL);
}

void IdeaWMISuperRes::processWMI() {
    setProperty("Feature", feature);

    IOReturn ret;
    OSNumber *in;
    UInt32 value;

    in = OSNumber::withNumber(0ULL, 32);
    ret = YWMI->evaluateInteger(SUPER_RES_DATA_WMI_METHOD, 0, SUPER_RES_DATA_WMI_CAP, &value, in, true);
    OSSafeReleaseNULL(in);

    if (ret != kIOReturnSuccess) {
        AlwaysLog(updateFailure, "Super resolution");
        return;
    }
    setProperty("Supported", value);
}

IOReturn IdeaWMISuperRes::setProperties(OSObject *props) {
    if (!commandGate) return kIOReturnNotReady;
    if (!OSDynamicCast(OSDictionary, props)) return kIOReturnBadArgument;
    return commandGate->runAction([](OSObject *owner, void *properties, void *, void *, void *) -> IOReturn {
        static_cast<IdeaWMISuperRes *>(owner)->setPropertiesGated(static_cast<OSObject *>(properties));
        return kIOReturnSuccess;
    }, props);
}

void IdeaWMISuperRes::setPropertiesGated(OSObject* props) {
    OSDictionary* dict = OSDynamicCast(OSDictionary, props);
    if (!dict)
        return;

    OSCollectionIterator* i = OSCollectionIterator::withCollection(dict);
    if (i) {
        while (OSString* key = OSDynamicCast(OSString, i->getNextObject())) {
            if (key->isEqualTo("ECMonitor")) {
                OSBoolean *value;
                getPropertyBoolean("ECMonitor");
                IOReturn ret;
                OSNumber *in;
                UInt32 result;

                in = OSNumber::withNumber(0ULL, 32);
                ret = YWMI->evaluateInteger(SUPER_RES_DATA_WMI_METHOD, 0,
                                            value->getValue() ? SUPER_RES_DATA_WMI_START : SUPER_RES_DATA_WMI_STOP, &result, in, true);
                OSSafeReleaseNULL(in);

                if (ret != kIOReturnSuccess || result != 1) {
                    AlwaysLog(toggleError, "ECMonitor", ret ?: result);
                } else {
                    DebugLog(toggleSuccess, "ECMonitor", value->getValue() ? SUPER_RES_DATA_WMI_START : SUPER_RES_DATA_WMI_STOP, value->getValue() ? "start" : "stop");
                }
                setProperty("ECMonitor started", value);
            } else {
                AlwaysLog("Unknown property %s", key->getCStringNoCopy());
            }
        }
        i->release();
    }

    return;
}


OSDefineMetaClassAndStructors(IdeaWMIBattery, ReYogaWMI);

void IdeaWMIBattery::processWMI() {
    setProperty("Feature", "Battery Information");
    // only execute once for WMI_EXPENSIVE
    OSArray *BatteryInfo = OSArray::withCapacity(3);
    getBatteryInfo(WBAT_BAT0_BatMaker, BatteryInfo);
    getBatteryInfo(WBAT_BAT0_HwId, BatteryInfo);
    getBatteryInfo(WBAT_BAT0_MfgDate, BatteryInfo);
    setProperty("BatteryInfo", BatteryInfo);
    BatteryInfo->release();
}

bool IdeaWMIBattery::getBatteryInfo(UInt32 index, OSArray *bat) {
    IOReturn ret;
    OSObject *result = nullptr;
    OSString *info;

    ret = YWMI->queryBlock(BAT_INFO_WMI_STRING, index, &result);
    if (ret != kIOReturnSuccess) {
        AlwaysLog("WBAT evaluation failed");
    } else if ((info = OSDynamicCast(OSString, result)) == nullptr) {
        ret = kIOReturnInvalid;
        AlwaysLog("WBAT result not a string");
    } else {
        AlwaysLog("WBAT %d %s", index, info->getCStringNoCopy());
        bat->setObject(info);
    }

    OSSafeReleaseNULL(result);

    return (ret == kIOReturnSuccess);
}

OSDefineMetaClassAndStructors(IdeaWMIGameZone, ReYogaWMI);

bool IdeaWMIGameZone::getGamzeZoneData(UInt32 query, UInt32 *result) {
    IOReturn ret;
    OSNumber *in;

    in = OSNumber::withNumber(0ULL, 32);
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
    ret = YWMI->evaluateInteger(LENOVO_FAN_METHOD, 0, 7, result, in, true);
    OSSafeReleaseNULL(in);
    return (ret == kIOReturnSuccess);
}

bool IdeaWMIGameZone::getSensorTemperature(UInt32 sensorId, UInt32 *result) {
    if (!hasFanMethod)
        return false;
    IOReturn ret;
    OSNumber *in = OSNumber::withNumber(static_cast<uint64_t>(sensorId), 32);
    ret = YWMI->evaluateInteger(LENOVO_FAN_METHOD, 0, 8, result, in, true);
    OSSafeReleaseNULL(in);
    return (ret == kIOReturnSuccess);
}

bool IdeaWMIGameZone::getCPUTemperature(UInt32 *result) {
    bool ok = hasFanMethod ? getSensorTemperature(3, result) :
        getGamzeZoneData(GAME_ZONE_WMI_GET_TMP_CPU, result);
    return ok && *result < 125;
}

bool IdeaWMIGameZone::getGPUTemperature(UInt32 *result) {
    bool ok = hasFanMethod ? getSensorTemperature(4, result) :
        getGamzeZoneData(GAME_ZONE_WMI_GET_TMP_GPU, result);
    // A powered-off dGPU may return zero; the telemetry layer labels it.
    return ok && *result < 125;
}

bool IdeaWMIGameZone::setFanFullSpeed(bool enable) {
    if (!hasFanMethod)
        return false;
    IOReturn ret;
    OSObject *result = nullptr;
    const UInt8 state = enable ? 1 : 0;
    OSData *in = OSData::withBytes(&state, sizeof(state));
    if (!in) return false;
    // LENOVO_FAN_METHOD accepts a one-byte buffer; a successful call may have no return object.
    ret = YWMI->evaluateMethod(LENOVO_FAN_METHOD, 0, 2, &result, in, true);
    OSSafeReleaseNULL(result);
    OSSafeReleaseNULL(in);
    return (ret == kIOReturnSuccess);
}

bool IdeaWMIGameZone::getFanFullSpeed(bool *enabled) {
    removeProperty("FanFullSpeedRaw");
    if (!enabled) return false;
    if (!hasFanMethod)
        return false;
    IOReturn ret;
    UInt32 result = 0;
    ret = YWMI->evaluateInteger(LENOVO_FAN_METHOD, 0, 1, &result, nullptr, true);
    if (ret == kIOReturnSuccess) {
        setProperty("FanFullSpeedRaw", result, 32);
        *enabled = result != 0;
    }
    return (ret == kIOReturnSuccess);
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
                setProperty(reasonKey, supported ? "State-control interface advertised" :
                    bytes[1] != 1 ? "Firmware assigns this light to another control interface; USB RGB may provide it" :
                    bytes[2] != 0 ? "Firmware does not advertise an on/off lighting type" : "Firmware does not advertise two lighting states");
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
    if (!enabled) return false;
    const UInt8 component = 3;
    OSData *in = OSData::withBytes(&component, sizeof(component));
    if (!in) return false;
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
            if (bytes[0] > 2) { result->release(); return false; }
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
    if (!enabled) return false;
    const UInt8 component = 5;
    OSData *in = OSData::withBytes(&component, sizeof(component));
    if (!in) return false;
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
            if (bytes[0] > 2) { result->release(); return false; }
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
    if (!hasLightingMethod) return false;
    if (component != 3 && component != 5) return false;
    if (!supportsStateLighting(component)) return false;
    // Acquire the firmware's software-lighting owner before applying a state.
    if (!setGameZoneData(GAME_ZONE_WMI_SET_LIGHT_CTL, 1)) {
        setProperty("LightingCommandStage", "ownership");
        return false;
    }
    setProperty("LightingCommandStage", "state");
    auto input = OSData::withBytes(&component, sizeof(component));
    if (input == nullptr) return false;
    OSObject *result = nullptr;
    IOReturn ret = YWMI->evaluateMethod(LENOVO_LIGHTING_METHOD, 0, 1, &result, input, true);
    input->release();
    auto data = OSDynamicCast(OSData, result);
    if (ret != kIOReturnSuccess || !data || data->getLength() != 2) { OSSafeReleaseNULL(result); return false; }
    // Toolkit's panel-logo and ports features use state 1/2 with level 0.
    // https://github.com/LenovoLegionToolkit-Team/LenovoLegionToolkit/blob/master/LenovoLegionToolkit.Lib/Features/PortsBacklightFeature.cs
    const auto current = static_cast<const UInt8 *>(data->getBytesNoCopy());
    if (current[0] > 2) { result->release(); return false; }
    UInt8 bytes[3] = {component, static_cast<UInt8>(enable ? 1 : 2), 0};
    OSSafeReleaseNULL(result);
    auto payload = OSData::withBytes(bytes, sizeof(bytes));
    if (!payload) return false;
    ret = YWMI->evaluateMethod(LENOVO_LIGHTING_METHOD, 0, 2, &result, payload, true);
    payload->release();
    OSSafeReleaseNULL(result);
    return ret == kIOReturnSuccess;
}

void IdeaWMIGameZone::processWMI() {
    setProperty("Feature", feature);

    hasFanMethod = YWMI->hasMethod(LENOVO_FAN_METHOD);
    hasLightingMethod = YWMI->hasMethod(LENOVO_LIGHTING_METHOD);

    if (hasFanMethod)
        setProperty("LenovoFanMethod", true);
    if (hasLightingMethod)
        setProperty("LenovoLightingMethod", true);

    UInt32 result;

    if (getGamzeZoneData(GAME_ZONE_WMI_GET_VERSION, &result))
        setProperty("Game Zone Version", result, 32);
    else
        AlwaysLog("Failed to get version");

    // Newer firmware can advertise the legacy Game Zone fan getter but fail
    // when it is called. The table block supplies its actual instance count.
    fanCount = hasFanMethod ? YWMI->getInstanceCount(LENOVO_FAN_TABLE_DATA) : 0;
    if (!fanCount && getGamzeZoneData(GAME_ZONE_WMI_GET_FAN_NUM, &result))
        fanCount = result;
    if (fanCount > 16) fanCount = 0;
    if (fanCount) setProperty("Fan number", fanCount, 32);
    else removeProperty("Fan number");

    if (hasFanMethod && fanCount) {
        if (getFanSpeed(0, &result))
            setProperty("Fan1Speed", result, 32);
        if (fanCount > 1 && getFanSpeed(1, &result))
            setProperty("Fan2Speed", result, 32);
    } else if (!fanCount) {
        AlwaysLog("Failed to get fan number");
    }

    if (getGamzeZoneData(GAME_ZONE_WMI_CAP_KEYBOARD, &result))
        setProperty("Keyboard Feature", result, 32);
    else
        AlwaysLog("Failed to get keyboard feature");

    if (getGamzeZoneData(GAME_ZONE_WMI_GET_SMARTFAN_MODE, &result))
        setProperty("SmartFanMode", result, 32);

    if (getGamzeZoneData(GAME_ZONE_WMI_GET_OVER_DRIVE, &result))
        setProperty("DisplayOverDrive", result, 32);
}

void IdeaWMIGameZone::ACPIEvent(UInt32 argument) {
    if (argument == smartFanEvent) {
        UInt32 mode = 0;
        if (getGamzeZoneData(GAME_ZONE_WMI_GET_SMARTFAN_MODE, &mode))
            setProperty("SmartFanMode", mode, 32);
        return;
    }
    if (argument == keyEvent) {
        UInt32 state = 0;
        if (getGamzeZoneData(GAME_ZONE_WMI_GET_WIN_KEY, &state))
            setProperty("WinKeyLock", state, 32);
        if (getGamzeZoneData(GAME_ZONE_WMI_GET_TOUCHPAD, &state))
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

const char* IdeaWMIGameZone::registerEvent(OSString *guid, UInt32 id) {
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

// Firmware supplies current/step/min/max as four little-endian dwords.
bool IdeaWMIGameZone::getPowerLimit(UInt32 query, UInt32 range[4]) {
    if (!YWMI->hasMethod(LENOVO_CPU_METHOD)) return false;
    OSObject *result = nullptr;
    auto input = OSNumber::withNumber(0ULL, 32);
    if (input == nullptr) return false;
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
    OSObject *result = nullptr;
    auto input = OSNumber::withNumber(watts, 32);
    if (input == nullptr) return false;
    IOReturn ret = YWMI->evaluateMethod(LENOVO_CPU_METHOD, 0, query, &result, input, true);
    input->release();
    OSSafeReleaseNULL(result);
    return ret == kIOReturnSuccess;
}
