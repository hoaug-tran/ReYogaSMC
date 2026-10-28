// SPDX-License-Identifier: GPL-2.0-only
// Original work: Copyright (c) 2020 Zhen.

#include "ReYogaVPC.hpp"

void ReYogaVPC::setPropertiesGated(OSObject *props) {
    auto dict = OSDynamicCast(OSDictionary, props);
    if (!dict)
        return;
    // Preserve the existing exclusive export dispatch for mixed dictionaries.
    const char *exports[] = {"ExportACPITables", "ExportDSDT"};
    for (const char *key : exports) {
        auto requested = OSDynamicCast(OSBoolean, dict->getObject(key));
        if (requested) {
            setPropertyGated(key, requested);
            return;
        }
    }
    auto iterator = OSCollectionIterator::withCollection(dict);
    if (!iterator)
        return;
    while (auto key = OSDynamicCast(OSString, iterator->getNextObject()))
        setPropertyGated(key->getCStringNoCopy(), dict->getObject(key));
    iterator->release();
}

void ReYogaVPC::setPropertyGated(const char *key, OSObject *rawValue) {
    if (!key || !rawValue)
        return;
    if (!strcmp(key, "ExportACPITables")) {
        auto requested = OSDynamicCast(OSBoolean, rawValue);
        if (!requested) {
            AlwaysLog(valueInvalid, key);
            return;
        }
        removeProperty("ExportedACPITables");
        removeProperty("ThinkPadACPIEvidence");
        if (!requested->getValue())
            return;
        exportACPITables();
        return;
    }
    if (!strcmp(key, "ExportDSDT")) {
        auto requested = OSDynamicCast(OSBoolean, rawValue);
        if (!requested) {
            AlwaysLog(valueInvalid, key);
            return;
        }
        if (!requested->getValue()) {
            removeProperty("ExportedDSDT");
            return;
        }
        const OSData *table = vpc ? vpc->getACPITableData("DSDT", 0) : nullptr;
        if (table && table->getLength() >= 36 && table->getLength() <= 1024 * 1024) {
            setProperty("ExportedDSDT", const_cast<OSData *>(table));
            setProperty("ACPIExportStatus", static_cast<UInt32>(kIOReturnSuccess), 32);
            AlwaysLog("ACPI DSDT export size=%u", table->getLength());
        } else {
            removeProperty("ExportedDSDT");
            setProperty("ACPIExportStatus", static_cast<UInt32>(kIOReturnNotFound), 32);
            AlwaysLog("ACPI DSDT export unavailable");
        }
        return;
    }

    if (!strcmp(key, clamshellPrompt)) {
        if (!clamshellCap) {
            AlwaysLog(notSupported, clamshellPrompt);
            return;
        }
        auto value = OSDynamicCast(OSBoolean, rawValue);
        if (!value) {
            AlwaysLog(valueInvalid, clamshellPrompt);
            return;
        }
        updateClamshell(false);
        if (value->getValue() == clamshellMode)
            DebugLog(valueMatched, clamshellPrompt, clamshellMode);
        else
            toggleClamshell();
    } else if (!strcmp(key, backlightPrompt)) {
        auto value = OSDynamicCast(OSNumber, rawValue);
        if (!value || value->unsigned64BitValue() > 2) {
            AlwaysLog(valueInvalid, backlightPrompt);
            return;
        }
        if (!updateBacklight()) {
            AlwaysLog(notSupported, backlightPrompt);
            return;
        }
        setUserBacklight(value->unsigned32BitValue());
    } else if (!strcmp(key, autoBacklightPrompt)) {
        auto value = OSDynamicCast(OSNumber, rawValue);
        if (!value) {
            AlwaysLog(valueInvalid, autoBacklightPrompt);
            return;
        }
        if (value->unsigned64BitValue() > 0x1f) {
            AlwaysLog(valueInvalid, autoBacklightPrompt);
        } else if (value->unsigned8BitValue() == automaticBacklightMode) {
            DebugLog(valueMatched, autoBacklightPrompt, automaticBacklightMode);
        } else {
            automaticBacklightMode = value->unsigned8BitValue();
            setProperty(autoBacklightPrompt, automaticBacklightMode, 8);
        }
    } else if (!strcmp(key, backlightTimeoutPrompt)) {
        auto value = OSDynamicCast(OSNumber, rawValue);
        if (!value || value->unsigned64BitValue() > maximumBacklightTimeoutSeconds) {
            AlwaysLog(valueInvalid, backlightTimeoutPrompt);
            return;
        }
        backlightTimeout = value->unsigned32BitValue();
        setProperty(backlightTimeoutPrompt, backlightTimeout, 32);
        if (backlightPoller)
            backlightPoller->cancelTimeout();
        if (updateBacklight())
            rememberBacklight(backlightLevel);
    } else if (!strcmp(key, FnKeyPrompt)) {
        auto value = OSDynamicCast(OSBoolean, rawValue);
        if (!value) {
            AlwaysLog(valueInvalid, FnKeyPrompt);
            return;
        }
        updateFnLock();

        if (value->getValue() == FnlockMode)
            DebugLog(valueMatched, FnKeyPrompt, FnlockMode);
        else
            setFnLock(!FnlockMode);
    } else if (!strcmp(key, "ReadECOffset")) {
        if (!(ECAccessCap & ECReadCap)) {
            AlwaysLog(notSupported, "EC Read");
            return;
        }
        auto value = OSDynamicCast(OSNumber, rawValue);
        if (!value) {
            AlwaysLog(valueInvalid, "ReadECOffset");
            return;
        }
        dumpECOffset(value->unsigned32BitValue());
    } else if (!strcmp(key, "ReadECName")) {
        auto value = OSDynamicCast(OSString, rawValue);
        if (!value) {
            AlwaysLog(valueInvalid, "ReadECName");
            return;
        }
        if (value->getLength() != 4) {
            AlwaysLog("invalid length %d", value->getLength());
            return;
        }
        UInt32 result;
        if (readECName(value->getCStringNoCopy(), &result) == kIOReturnSuccess)
            AlwaysLog("%s: 0x%02x", value->getCStringNoCopy(), result);
    } else if (!strcmp(key, DYTCPSCPrompt)) {
        if (!(DYTCCap & BIT(DYTC_FUNCTION_PSC))) {
            AlwaysLog(notSupported, DYTCPSCPrompt);
            return;
        }
        auto value = OSDynamicCast(OSNumber, rawValue);
        if (!value) {
            AlwaysLog(valueInvalid, DYTCPSCPrompt);
            return;
        }
        if (value->unsigned64BitValue() > 0xf) {
            AlwaysLog(valueInvalid, DYTCPSCPrompt);
            return;
        }
        if (!setDYTC(DYTC_FUNCTION_PSC, value->unsigned8BitValue())) {
            AlwaysLog(toggleFailure, DYTCPSCPrompt);
            updateDYTC();
        } else {
            DebugLog(toggleSuccess, DYTCPSCPrompt, value->unsigned8BitValue(), "see ioreg");
        }
    } else if (!strcmp(key, DYTCPrompt)) {
        if (!DYTCCap) {
            AlwaysLog(notSupported, DYTCPrompt);
            return;
        }
        OSNumber *raw = OSDynamicCast(OSNumber, rawValue);
        if (raw != nullptr) {
            DYTC_CMD cmd = {.raw = raw->unsigned32BitValue()};
            DYTC_RESULT res;
            if (DYTCCommand(cmd, &res) && parseDYTC(res))
                AlwaysLog(toggleSuccess, DYTCPrompt, raw->unsigned32BitValue(), "see ioreg");
            else
                AlwaysLog(toggleFailure, DYTCPrompt);
            return;
        }
        auto value = OSDynamicCast(OSString, rawValue);
        if (!value) {
            AlwaysLog(valueInvalid, DYTCPrompt);
            return;
        }
        int mode;
        switch (value->getChar(0)) {
        case 'l':
        case 'L':
        case 'q':
        case 'Q':
            mode = DYTC_MODE_QUIET;
            break;

        case 'b':
        case 'B':
        case 'm':
        case 'M':
            mode = DYTC_MODE_BALANCE;
            break;

        case 'h':
        case 'H':
        case 'p':
        case 'P':
            mode = DYTC_MODE_PERFORM;
            break;

        default:
            AlwaysLog(valueInvalid, DYTCPrompt);
            return;
        }
        const UInt32 profile = mode == DYTC_MODE_QUIET ? 1 : mode == DYTC_MODE_BALANCE ? 2
                                                                                       : 3;
        if (!setThermalProfile(profile)) {
            AlwaysLog(toggleFailure, DYTCPrompt);
            updateDYTC();
        } else {
            DebugLog(toggleSuccess, DYTCPrompt, mode, "see ioreg");
        }
    } else if (!strcmp(key, updatePrompt)) {
        updateAll();
    } else {
        AlwaysLog("Unknown property %s", key);
    }
}

IOReturn ReYogaVPC::setProperties(OSObject *props) {
    if (!commandGate || isInactive())
        return kIOReturnNotReady;
    if (getProperty("SafeMode") == kOSBooleanTrue)
        return kIOReturnNotPermitted;
    if (!OSDynamicCast(OSDictionary, props))
        return kIOReturnBadArgument;
    return commandGate->runAction([](OSObject *owner, void *properties, void *, void *, void *) -> IOReturn {
        auto self = static_cast<ReYogaVPC *>(owner);
        if (self->stopping || self->isInactive())
            return kIOReturnNotAttached;
        self->setPropertiesGated(static_cast<OSObject *>(properties));
        return kIOReturnSuccess;
    },
                                  props);
}

bool ReYogaVPC::updateClamshell(bool publish) {
    if (!clamshellCap)
        return true;

    UInt32 state;
    if (vpc->evaluateInteger(getClamshellMode, &state) != kIOReturnSuccess) {
        AlwaysLog(updateFailure, clamshellPrompt);
        return false;
    }

    clamshellMode = state ? true : false;

    if (publish) {
        DebugLog(updateSuccess, clamshellPrompt, state);
        setProperty(clamshellPrompt, clamshellMode);
    }

    return true;
}

bool ReYogaVPC::toggleClamshell() {
    if (!clamshellCap)
        return true;

    UInt32 result;
    if (evaluateIntegerParam(setClamshellMode, &result, !clamshellMode) != kIOReturnSuccess) {
        AlwaysLog(toggleFailure, clamshellPrompt);
        return false;
    }

    clamshellMode = !clamshellMode;
    DebugLog(toggleSuccess, clamshellPrompt, clamshellMode, (clamshellMode ? "on" : "off"));
    setProperty(clamshellPrompt, clamshellMode);

    return true;
}

bool ReYogaVPC::dumpECOffset(UInt32 value) {
    bool ret = false;
    UInt32 size = value >> 8;
    if (size) {
        UInt32 offset = value & 0xff;
        if (offset + size > 0x100) {
            AlwaysLog("read %d bytes @ 0x%02x exceeded", size, offset);
        } else {
            OSData *result;
            if (method_recb(offset, size, &result) == kIOReturnSuccess) {
                const UInt8 *data = reinterpret_cast<const UInt8 *>(result->getBytesNoCopy());
                int len = 0x10;
                char buf[0x10 * 3 + 1]{};
                if (size > 8) {
                    AlwaysLog("%d bytes @ 0x%02x", size, offset);
                    for (int i = 0; i < size; i += len) {
                        memset(buf, 0, len * 3);
                        for (int j = 0; j < (len < size - i ? len : size - i); j++)
                            snprintf(buf + 3 * j, 4, "%02x ", data[i + j]);
                        buf[len * 3 - 1] = '\0';
                        AlwaysLog("0x%02x: %s", offset + i, buf);
                    }
                } else {
                    for (int j = 0; j < size; j++)
                        snprintf(buf + 3 * j, 4, "%02x ", data[j]);
                    buf[size * 3 - 1] = '\0';
                    AlwaysLog("%d bytes @ 0x%02x: %s", size, offset, buf);
                }
                result->release();
                ret = true;
            }
        }
    } else {
        UInt8 byte;
        if (method_re1b(value, &byte) == kIOReturnSuccess) {
            AlwaysLog("0x%02x: %02x", value, byte);
            ret = true;
        }
    }
    return ret;
}

void ReYogaVPC::exportACPITables() {
    setProperty("ACPIExportStatus", static_cast<UInt32>(kIOReturnNotReady), 32);
}
