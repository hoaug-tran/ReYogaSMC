// SPDX-License-Identifier: GPL-2.0-only
// Original work: Copyright (c) 2020 Zhen.

#include "ThinkVPC.hpp"

void ThinkVPC::updateNotificationMask() {
    if (hotkey_legacy) {
        OSObject *result = nullptr;
        if (vpc->evaluateObject(getHKEYmask, &result) != kIOReturnSuccess)
            AlwaysLog(toggleFailure, "LegacyNotificationMask");
        else
            setProperty("HKEY Setting", result);
        OSSafeReleaseNULL(result);
    } else {
        OSDictionary *KBDPresent = OSDictionary::withCapacity(3);
        if (KBDPresent) {
            getNotificationMask(1, KBDPresent);
            getNotificationMask(2, KBDPresent);
            getNotificationMask(3, KBDPresent);
            setProperty("HKEY Setting", KBDPresent);
            KBDPresent->release();
        }
    }
}

void ThinkVPC::getNotificationMask(UInt32 index, OSDictionary *KBDPresent) {
    UInt32 result;
    if (evaluateIntegerParam(getHKEYmask, &result, index) != kIOReturnSuccess) {
        AlwaysLog(toggleFailure, __func__);
        return;
    }

    switch (index) {
    case 1:
        ReYogaProperty::setNumber(KBDPresent, "DHKN", result, 32);
        break;

    case 2:
        ReYogaProperty::setNumber(KBDPresent, "DHKE", result, 32);
        break;

    case 3:
        ReYogaProperty::setNumber(KBDPresent, "DHKF", result, 32);
        break;

    default:
        break;
    }
}

bool ThinkVPC::setNotificationMask(UInt32 i, UInt32 all_mask, UInt32 offset, bool enable) {
    OSObject *params[] = {
        OSNumber::withNumber(i + offset + 1, 32),
        OSNumber::withNumber(enable, 32),
    };

    if (!params[0] || !params[1]) {
        OSSafeReleaseNULL(params[0]);
        OSSafeReleaseNULL(params[1]);
        return false;
    }

    IOReturn ret = vpc->evaluateObject(setHKEYmask, nullptr, params, 2);
    params[0]->release();
    params[1]->release();

    if (ret != kIOReturnSuccess) {
        AlwaysLog("set HKEY mask BIT %x failed", i);
        return false;
    }
    DebugLog("set HKEY mask BIT %x", i);
    return true;
}

void ThinkVPC::exportACPITables() {
    auto tables = OSArray::withCapacity(16);
    auto evidence = OSDictionary::withCapacity(10);
    bool complete = tables && evidence && vpc && ec && getProperty("SafeMode") != kOSBooleanTrue;
    unsigned total = 0;
    if (complete) {
        ReYogaProperty::setNumber(evidence, "FanControlOffset", ReYogaControl::kThinkFanControlOffset, 32);
        ReYogaProperty::setNumber(evidence, "FanRPMOffset", ReYogaControl::kThinkFanRPMOffset, 32);
        ReYogaProperty::setNumber(evidence, "FanSelectorOffset", ReYogaControl::kThinkFanSelectorOffset, 32);
        complete = getProperty("ACPIECPath") && getProperty("ACPIHKEYPath");
    }
    if (complete) {
        for (unsigned index = 0; index <= 256; ++index) {
            const OSData *table = vpc->getACPITableData(index ? "SSDT" : "DSDT", index ? index - 1 : 0);
            if (!table) {
                if (!index)
                    complete = false;
                break;
            }
            if (index == 256 || table->getLength() < 36 || table->getLength() > 1024 * 1024 ||
                total + table->getLength() > 16 * 1024 * 1024) {
                complete = false;
                break;
            }
            total += table->getLength();
            if (!tables->setObject(const_cast<OSData *>(table))) {
                complete = false;
                break;
            }
        }
    }
    if (complete) {
        const char *helpers[]{"CSSI", "RE1B", "WE1B", "RECB", "WECB"};
        for (unsigned i = 0; i < 5; ++i)
            evidence->setObject(helpers[i], (i ? ec : vpc)->validateObject(helpers[i]) == kIOReturnSuccess ? kOSBooleanTrue : kOSBooleanFalse);
        evidence->setObject("ECPath", getProperty("ACPIECPath"));
        evidence->setObject("HKEYPath", getProperty("ACPIHKEYPath"));
        if (auto capability = getProperty("EC Capability"))
            evidence->setObject("ECCapability", capability);
        setProperty("ExportedACPITables", tables);
        setProperty("ThinkPadACPIEvidence", evidence);
    }
    setProperty("ACPIExportStatus", static_cast<UInt32>(complete ? kIOReturnSuccess : kIOReturnNotReady), 32);
    AlwaysLog("ACPI namespace export complete=%u tables=%u bytes=%u", complete, tables ? tables->getCount() : 0, total);
    OSSafeReleaseNULL(tables);
    OSSafeReleaseNULL(evidence);
}
