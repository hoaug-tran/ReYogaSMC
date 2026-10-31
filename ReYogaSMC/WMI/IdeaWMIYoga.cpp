// SPDX-License-Identifier: GPL-2.0-only
// Original work: Copyright (c) 2020 Zhen.

#include "IdeaWMI.hpp"

OSDefineMetaClassAndStructors(IdeaWMIYoga, ReYogaWMI);

const char *IdeaWMIYoga::registerEvent(OSString *guid, UInt32 id) {
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
    if (in == nullptr)
        return;
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

IOReturn IdeaWMIYoga::setPowerState(unsigned long powerStateOrdinal, IOService *whatDevice) {
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
