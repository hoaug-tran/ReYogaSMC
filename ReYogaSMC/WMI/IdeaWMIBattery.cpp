// SPDX-License-Identifier: GPL-2.0-only
// Original work: Copyright (c) 2020 Zhen.

#include "IdeaWMI.hpp"

OSDefineMetaClassAndStructors(IdeaWMIBattery, ReYogaWMI);

void IdeaWMIBattery::processWMI() {
    setProperty("Feature", "Battery Information");
    // only execute once for WMI_EXPENSIVE
    OSArray *BatteryInfo = OSArray::withCapacity(3);
    if (!BatteryInfo)
        return;
    getBatteryInfo(WBAT_BAT0_BatMaker, BatteryInfo);
    getBatteryInfo(WBAT_BAT0_HwId, BatteryInfo);
    getBatteryInfo(WBAT_BAT0_MfgDate, BatteryInfo);
    setProperty("BatteryInfo", BatteryInfo);
    BatteryInfo->release();
}

bool IdeaWMIBattery::getBatteryInfo(UInt32 index, OSArray *bat) {
    if (!bat || !YWMI)
        return false;
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
        if (!bat->setObject(info))
            ret = kIOReturnNoMemory;
    }

    OSSafeReleaseNULL(result);

    return (ret == kIOReturnSuccess);
}
