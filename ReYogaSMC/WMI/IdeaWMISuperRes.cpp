// SPDX-License-Identifier: GPL-2.0-only
// Original work: Copyright (c) 2020 Zhen.

#include "IdeaWMI.hpp"

OSDefineMetaClassAndStructors(IdeaWMISuperRes, ReYogaWMI);

const char *IdeaWMISuperRes::registerEvent(OSString *guid, UInt32 id) {
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
    if (in == nullptr)
        return;
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
    if (in == nullptr)
        return;
    ret = YWMI->evaluateInteger(SUPER_RES_DATA_WMI_METHOD, 0, SUPER_RES_DATA_WMI_CAP, &value, in, true);
    OSSafeReleaseNULL(in);

    if (ret != kIOReturnSuccess) {
        AlwaysLog(updateFailure, "Super resolution");
        return;
    }
    setProperty("Supported", value);
}

IOReturn IdeaWMISuperRes::setProperties(OSObject *props) {
    if (!commandGate)
        return kIOReturnNotReady;
    if (!OSDynamicCast(OSDictionary, props))
        return kIOReturnBadArgument;
    return commandGate->runAction([](OSObject *owner, void *properties, void *, void *, void *) -> IOReturn {
        static_cast<IdeaWMISuperRes *>(owner)->setPropertiesGated(static_cast<OSObject *>(properties));
        return kIOReturnSuccess;
    },
                                  props);
}

void IdeaWMISuperRes::setPropertiesGated(OSObject *props) {
    OSDictionary *dict = OSDynamicCast(OSDictionary, props);
    if (!dict)
        return;

    OSCollectionIterator *i = OSCollectionIterator::withCollection(dict);
    if (i) {
        while (OSString *key = OSDynamicCast(OSString, i->getNextObject())) {
            if (key->isEqualTo("ECMonitor")) {
                auto value = ReYogaProperty::get<OSBoolean>(dict, "ECMonitor");
                if (!value) {
                    AlwaysLog(valueInvalid, "ECMonitor");
                    continue;
                }
                IOReturn ret;
                OSNumber *in;
                UInt32 result;

                in = OSNumber::withNumber(0ULL, 32);
                if (in == nullptr)
                    continue;
                ret = YWMI->evaluateInteger(SUPER_RES_DATA_WMI_METHOD, 0,
                                            value->getValue() ? SUPER_RES_DATA_WMI_START : SUPER_RES_DATA_WMI_STOP, &result, in, true);
                OSSafeReleaseNULL(in);

                if (ret != kIOReturnSuccess || result != 1) {
                    AlwaysLog(toggleError, "ECMonitor", ret ?: result);
                    removeProperty("ECMonitor started");
                } else {
                    setProperty("ECMonitor started", value);
                    DebugLog(toggleSuccess, "ECMonitor", value->getValue() ? SUPER_RES_DATA_WMI_START : SUPER_RES_DATA_WMI_STOP, value->getValue() ? "start" : "stop");
                }
            } else {
                AlwaysLog("Unknown property %s", key->getCStringNoCopy());
            }
        }
        i->release();
    }

    return;
}
