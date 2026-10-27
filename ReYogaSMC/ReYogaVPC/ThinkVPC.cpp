#include "ControlValidation.hpp"
#include "ThinkEvents.h"
#include "ThinkVPC.hpp"

OSDefineMetaClassAndStructors(ThinkVPC, ReYogaVPC);

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

void ThinkVPC::updateFans() {
    const unsigned count = getProperty("Dual fan") == kOSBooleanTrue ? 2 : 1;
    auto telemetry = OSDictionary::withCapacity(3);
    for (unsigned fan = 0; fan < count; ++fan) {
        UInt32 rpm = 0;
        UInt8 control = 0xff;
        const char *property = fan == 0 ? "Fan1RPM" : "Fan2RPM";
        const bool validRPM = readThinkFanRPM(fan, rpm, &control) == kIOReturnSuccess;
        if (validRPM)
            setProperty(property, rpm, 32);
        else
            removeProperty(property);
        auto reading = OSDictionary::withCapacity(2);
        if (reading) {
            if (validRPM) setPropertyNumber(reading, "RPM", rpm, 32);
            if (control != 0xff) setPropertyNumber(reading, "Control", control, 8);
            if (telemetry) telemetry->setObject(fan == 0 ? "Fan1" : "Fan2", reading);
            reading->release();
        }
    }
    if (telemetry) {
        UInt64 uptime, ns;
        clock_get_uptime(&uptime);
        absolutetime_to_nanoseconds(uptime, &ns);
        setPropertyNumber(telemetry, "SensorSampleTimeMS", ns / 1000000, 64);
        setProperty("ThinkFanTelemetry", telemetry);
        telemetry->release();
    } else {
        removeProperty("ThinkFanTelemetry");
    }
}

void ThinkVPC::updateAll() {
    updateNotificationMask();
    updateBattery(BAT_ANY);
    updateFnLock();
    updateMutestatus();
    updateMuteLEDStatus();
    updateMicMuteLEDStatus();
    updateKBDLocale();
    updateVPC();
    updateYogaMode();
    updateFans();
    super::updateAll();
    updateControlStatus();
}

bool ThinkVPC::updateConservation(const char * method, OSDictionary *bat, bool update) {
    UInt32 result;
    if (evaluateIntegerParam(method, &result, batnum) != kIOReturnSuccess || (result & BIT(31))) {
        AlwaysLog(updateFailure, method);
        return false;
    }

    if (update)
        DebugLog(updateSuccess, method, result);

    setPropertyNumber(bat, method, result, 32);

    return true;
}

bool ThinkVPC::setConservation(const char * method, UInt64 value) {
    if (value > 0xff || vpc->validateObject(method) != kIOReturnSuccess) return false;
    UInt32 parameter = (batnum << 8) | static_cast<UInt32>(value);
    const bool start = !strcmp(method, setCMstart);
    const bool stop = !strcmp(method, setCMstop);
    if (start || stop) {
        UInt32 own = 0, other = 0;
        if (evaluateIntegerParam(start ? getCMstart : getCMstop, &own, batnum) != kIOReturnSuccess ||
            evaluateIntegerParam(start ? getCMstop : getCMstart, &other, batnum) != kIOReturnSuccess ||
            !ReYogaControl::validThresholdState(own, stop) || !ReYogaControl::validThresholdState(other, start) ||
            !ReYogaControl::validThresholdTarget(ReYogaControl::thresholdPercent(static_cast<UInt32>(value), stop), start,
                ReYogaControl::thresholdPercent(other, start))) return false;
    } else if (!strcmp(method, setCMInhibitCharge) || !strcmp(method, setCMForceDischarge)) {
        const bool inhibit = !strcmp(method, setCMInhibitCharge);
        UInt32 capability = 0;
        if (value > 1 || evaluateIntegerParam(inhibit ? getCMInhibitCharge : getCMForceDischarge, &capability, batnum) != kIOReturnSuccess ||
            (capability & BIT(31)) || !(capability & BIT(inhibit ? 5 : 8))) return false;
        if (inhibit) parameter = (batnum << 4) | 0x00ffff00U | static_cast<UInt32>(value);
    }
    UInt32 result;
    if (evaluateIntegerParam(method, &result, parameter) != kIOReturnSuccess || (result & BIT(31))) {
        AlwaysLog(updateFailure, method);
        return false;
    }

    DebugLog(updateSuccess, method, result);
    updateBattery();

    return true;
}

bool ThinkVPC::updateMutestatus(bool update) {
    if (ec->evaluateInteger(getAudioMutestatus, &mutestate) != kIOReturnSuccess) {
        AlwaysLog(updateFailure, __func__);
        return false;
    }

    if (update)
        DebugLog(updateSuccess, __func__, mutestate);

    setProperty(mutePrompt, mutestate, 32);
    return true;
}

bool ThinkVPC::setMutestatus(UInt32 value) {
    updateMutestatus(false);
    if (mutestate == value) {
        DebugLog(valueMatched, mutePrompt, mutestate);
        return true;
    }

    UInt32 result;
    if (evaluateIntegerParam(setAudioMutestatus, &result, value) != kIOReturnSuccess) {
        AlwaysLog(toggleFailure, __func__);
        return false;
    }

    DebugLog(toggleSuccess, __func__, mutestate, (mutestate == 2 ? "SW" : "HW"));
    setProperty(mutePrompt, mutestate, 32);
    return true;
}

void ThinkVPC::getNotificationMask(UInt32 index, OSDictionary *KBDPresent) {
    UInt32 result;
    if (evaluateIntegerParam(getHKEYmask, &result, index) != kIOReturnSuccess) {
        AlwaysLog(toggleFailure, __func__);
        return;
    }

    switch (index) {
        case 1:
            setPropertyNumber(KBDPresent, "DHKN", result, 32);
            break;

        case 2:
            setPropertyNumber(KBDPresent, "DHKE", result, 32);
            break;

        case 3:
            setPropertyNumber(KBDPresent, "DHKF", result, 32);
            break;

        default:
            break;
    }
}

bool ThinkVPC::setNotificationMask(UInt32 i, UInt32 all_mask, UInt32 offset, bool enable) {
    OSObject* params[] = {
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

bool ThinkVPC::initVPC() {
    super::initVPC();
    setProperty("ThinkPadACPIAnalysisVersion", 1, 32);
    char path[512];
    int length = sizeof(path);
    if (ec->getPath(path, &length, gIOACPIPlane)) setProperty("ACPIECPath", path);
    length = sizeof(path);
    if (vpc->getPath(path, &length, gIOACPIPlane)) setProperty("ACPIHKEYPath", path);
    UInt32 version;

    if (vpc->evaluateInteger(getHKEYversion, &version) != kIOReturnSuccess)
    {
        AlwaysLog(initFailure, getHKEYversion);
        return false;
    }

    KBDProperty = OSDictionary::withCapacity(1);
    if (!KBDProperty) return false;
    DebugLog("HKEY interface version %x", version);
    setPropertyNumber(KBDProperty, "Version", version, 32);
    switch (version >> 8) {
        case 1:
            hotkey_legacy = true;
            updateAdaptiveKBD(0);
            break;

        case 2:
            updateAdaptiveKBD(1);
            updateAdaptiveKBD(2);
            updateAdaptiveKBD(3);
            break;

        default:
            AlwaysLog("Unknown HKEY version");
            break;
    }

    if (hotkey_all_mask) {
        for (UInt32 i = 0; i < 0x20; i++) {
            if ((hotkey_all_mask & BIT(i)) &&
                !setNotificationMask(i, hotkey_all_mask, DHKN_MASK_offset))
                break;
        }
    } else {
        AlwaysLog("Failed to acquire hotkey_all_mask");
    }
    setProperty("HKEY Property", KBDProperty);
    KBDProperty->release();

    setHotkeyStatus(true);

    UInt32 state;
    if (evaluateIntegerParam(getKBDBacklightLevel, &state, 0) == kIOReturnSuccess)
        backlightCap = BIT(KBD_BACKLIGHT_CAP_BIT) & state;

    if (!backlightCap)
        setProperty(backlightPrompt, "unsupported");

    setProperty(autoBacklightPrompt, automaticBacklightMode, 8);

    LEDSupport = (ec->validateObject(setLED) == kIOReturnSuccess);
    setProperty("LEDSupport", LEDSupport);

    yogaModeSupport = (vpc->validateObject(getMultiModeState) == kIOReturnSuccess);

    setMicMuteLEDStatus(0);
    setProperty("ControlProtocolVersion", 1, 32);
    setProperty("ThinkFanProtocolVersion", 1, 32);
    setProperty("ThinkFanTelemetryVersion", 1, 32);
    return true;
}

bool ThinkVPC::exitVPC() {
    setHotkeyStatus(false);
    return super::exitVPC();
}

bool ThinkVPC::updateAdaptiveKBD(int arg) {
    UInt32 result;

    if (!arg) {
        if (vpc->evaluateInteger(getHKEYAdaptive, &result) != kIOReturnSuccess) {
            AlwaysLog(updateFailure, __func__);
            return false;
        }
    } else {
        if (evaluateIntegerParam(getHKEYAdaptive, &result, arg) != kIOReturnSuccess) {
            AlwaysLog(updateFailure, __func__);
            return false;
        }
    }

    AlwaysLog("%s %d %x", __func__, arg, result);
    switch (arg) {
        case 0:
        case 1:
            hotkey_all_mask = result;
            setPropertyNumber(KBDProperty, "hotkey_all_mask", result, 32);
            break;

        case 2:
            if (result) {
                hotkey_adaptive_all_mask = result;
                setPropertyNumber(KBDProperty, "hotkey_adaptive_all_mask", result, 32);
            }
            break;

        case 3:
            hotkey_alter_all_mask = result;
            setPropertyNumber(KBDProperty, "hotkey_alter_all_mask", result, 32);
            break;

        default:
            AlwaysLog("Unknown MHKA command");
            break;
    }
    return true;
}

void ThinkVPC::updateBattery(bool update) {
    switch (batnum) {
        case BAT_ANY:
        case BAT_PRIMARY:
        case BAT_SECONDARY:
            break;

        default:
            batnum = BAT_PRIMARY;
            AlwaysLog(valueInvalid, batteryPrompt);
            return;
    }

    OSDictionary *bat = OSDictionary::withCapacity(5);
    if (!bat) return;
    bool complete = true;
    const char *methods[] = {getCMstart, getCMstop, getCMInhibitCharge, getCMForceDischarge, getCMPeakShiftState};
    for (const char *method : methods) {
        if (vpc->validateObject(method) == kIOReturnSuccess)
            complete = updateConservation(method, bat) && complete;
    }
    if (!complete) AlwaysLog(updateFailure, batteryPrompt);

    switch (batnum) {
        case BAT_ANY:
            setProperty("BAT_ANY", bat);
            break;

        case BAT_PRIMARY:
            setProperty("BAT_PRIMARY", bat);
            break;

        case BAT_SECONDARY:
            setProperty("BAT_SECONDARY", bat);
            break;
    }
    bat->release();
}

void ThinkVPC::updateControlStatus() {
    auto features = OSDictionary::withCapacity(6);
    if (!features) return;
    auto add = [&](const char *key, bool available, const char *reason) {
        auto feature = OSDictionary::withCapacity(3);
        if (!feature) return;
        feature->setObject("Available", available ? kOSBooleanTrue : kOSBooleanFalse);
        setPropertyString(feature, "Reason", available ? "" : reason);
        setPropertyString(feature, "Backend", "ThinkPad ACPI");
        features->setObject(key, feature);
        feature->release();
    };
    add(FnKeyPrompt, getProperty(FnKeyPrompt) && vpc->validateObject(setMediaKeyStatus) == kIOReturnSuccess, "Fn Lock getter/setter unavailable");
    add(backlightPrompt, backlightCap && vpc->validateObject(setKBDBacklightLevel) == kIOReturnSuccess, "Keyboard backlight not advertised");
    const char *batteryKeys[] = {"BAT_ANY", "BAT_PRIMARY", "BAT_SECONDARY"};
    auto battery = OSDynamicCast(OSDictionary, getProperty(batteryKeys[batnum]));
    const char *keys[] = {"ChargeStartThreshold", "ChargeStopThreshold"};
    const char *getters[] = {getCMstart, getCMstop};
    const char *setters[] = {setCMstart, setCMstop};
    for (unsigned i = 0; i < 2; ++i) {
        auto raw = battery ? OSDynamicCast(OSNumber, battery->getObject(getters[i])) : nullptr;
        UInt32 value = raw != nullptr ? raw->unsigned32BitValue() : 0;
        bool supported = raw != nullptr && ReYogaControl::validThresholdState(value, i == 1) && vpc->validateObject(setters[i]) == kIOReturnSuccess;
        value = ReYogaControl::thresholdPercent(value, i == 1);
        if (supported) setProperty(keys[i], value, 32);
        else removeProperty(keys[i]);
        auto counterpart = battery ? OSDynamicCast(OSNumber, battery->getObject(getters[1 - i])) : nullptr;
        const bool orderingKnown = counterpart != nullptr && ReYogaControl::validThresholdState(counterpart->unsigned32BitValue(), i == 0);
        add(keys[i], supported && orderingKnown, "Battery threshold capability, setter or paired threshold unavailable");
    }
    UInt32 secSample = 0;
    const bool secondaryExists = vpc->validateObject(getCMstart) == kIOReturnSuccess &&
        evaluateIntegerParam(getCMstart, &secSample, BAT_SECONDARY) == kIOReturnSuccess &&
        !(secSample & BIT(31));
    const bool individual = secondaryExists;
    if (!individual && batnum != BAT_PRIMARY) {
        batnum = BAT_PRIMARY;
    }
    setProperty("BatteryIndividualAddressing", individual);
    add("BatteryIndex", individual, "Single battery platform");
    setProperty("BatteryIndex", batnum, 32);
    auto thermal = OSDynamicCast(OSDictionary, getProperty("DYTC"));
    auto mode = thermal ? OSDynamicCast(OSString, thermal->getObject("PerfMode")) : nullptr;
    UInt32 profile = mode && mode->isEqualTo("Quiet") ? 1 : mode && mode->isEqualTo("Balance") ? 2 :
        mode && (!strncmp(mode->getCStringNoCopy(), "Performance", 11)) ? 3 : 0;
    const bool thermalSupported = supportsThermalProfiles();
    add("SmartFanMode", thermalSupported, "DYTC desk thermal profiles unavailable");
    if (thermalSupported) {
        if (profile == 0 && activeThermalProfile != 0) profile = activeThermalProfile;
        if (profile != 0) setProperty("SmartFanMode", profile, 32);
        else removeProperty("SmartFanMode");
    } else {
        removeProperty("SmartFanMode");
    }
    add("CPUBoostPower", false, "Direct CPU power-limit control is not implemented or validated for this ThinkPad. Firmware-managed performance profiles may be available through DYTC.");
    add("CPUSustainedPower", false, "Direct CPU power-limit control is not implemented or validated for this ThinkPad. Firmware-managed performance profiles may be available through DYTC.");
    add("CPUPowerReset", false, "Direct CPU power-limit control is not implemented or validated for this ThinkPad. Firmware-managed performance profiles may be available through DYTC.");
    setProperty("FeatureStatus", features);
    features->release();
}

void ThinkVPC::controlRequest(OSDictionary *request) {
    auto key = OSDynamicCast(OSString, request->getObject("Property"));
    auto id = OSDynamicCast(OSString, request->getObject("RequestID"));
    auto number = OSDynamicCast(OSNumber, request->getObject("Value"));
    auto boolean = OSDynamicCast(OSBoolean, request->getObject("Value"));
    if (!key || !id || key->getLength() > 64 || id->getLength() > 64) return;
    updateAll();
    auto features = OSDynamicCast(OSDictionary, getProperty("FeatureStatus"));
    auto feature = features ? OSDynamicCast(OSDictionary, features->getObject(key)) : nullptr;
    IOReturn status = kIOReturnUnsupported;
    const char *name = key->getCStringNoCopy();
    if (feature && feature->getObject("Available") == kOSBooleanTrue) {
        status = kIOReturnBadArgument;
        if (key->isEqualTo(FnKeyPrompt) && boolean) {
            status = setFnLock(boolean->getValue()) ? kIOReturnSuccess : kIOReturnIOError;
        } else if (number && number->unsigned64BitValue() <= 100) {
            UInt32 target = number->unsigned32BitValue();
            if (key->isEqualTo("BatteryIndex") && (target == BAT_PRIMARY ||
                (target == BAT_SECONDARY && getProperty("BatteryIndividualAddressing") == kOSBooleanTrue))) {
                batnum = target;
                status = kIOReturnSuccess;
            } else if (key->isEqualTo("SmartFanMode") && target >= 1 && target <= 3) {
                status = setThermalProfile(target) ? kIOReturnSuccess : kIOReturnIOError;
            } else if (key->isEqualTo(backlightPrompt) && target <= 2)
                status = setBacklight(target) ? kIOReturnSuccess : kIOReturnIOError;
            else if (key->isEqualTo("ChargeStartThreshold") || key->isEqualTo("ChargeStopThreshold")) {
                const bool start = key->isEqualTo("ChargeStartThreshold");
                auto other = OSDynamicCast(OSNumber, getProperty(start ? "ChargeStopThreshold" : "ChargeStartThreshold"));
                if (other && ReYogaControl::validThresholdTarget(target, start, other->unsigned32BitValue())) {
                    const UInt8 encoded = !start && target == 100 ? 0 : target;
                    status = setConservation(start ? setCMstart : setCMstop, encoded) ? kIOReturnSuccess : kIOReturnIOError;
                }
            }
        }
    }
    const IOReturn commandStatus = status;
    if (status == kIOReturnSuccess) updateAll();
    OSObject *actual = getProperty(name);
    OSObject *requested = request->getObject("Value");
    if (status == kIOReturnSuccess && (!actual || !actual->isEqualTo(requested))) status = kIOReturnIOError;
    auto result = OSDictionary::withCapacity(9);
    if (!result) return;
    result->setObject("RequestID", id);
    result->setObject("Property", key);
    if (requested) result->setObject("Requested", requested);
    if (actual) result->setObject("Actual", actual);
    setPropertyNumber(result, "Status", status, 32);
    setPropertyNumber(result, "CommandStatus", commandStatus, 32);
    result->setObject("ReadbackPending", commandStatus == kIOReturnSuccess && status != kIOReturnSuccess ? kOSBooleanTrue : kOSBooleanFalse);
    setPropertyString(result, "Reason", status == kIOReturnSuccess ? "Firmware readback matched" : status == kIOReturnBadArgument ? "Invalid type, threshold ordering or value" : status == kIOReturnUnsupported ? "Feature unavailable; inspect FeatureStatus" : "Firmware call failed or readback did not match");
    setProperty("LastControlResult", result);
    result->release();
}

void ThinkVPC::setPropertiesGated(OSObject *props) {
    OSDictionary *dict = OSDynamicCast(OSDictionary, props);
    if (!dict)
        return;

    if (auto update = OSDynamicCast(OSBoolean, dict->getObject("UpdateFans"))) {
        if (update->getValue()) updateFans();
        return;
    }

    if (auto request = OSDynamicCast(OSDictionary, dict->getObject("ControlRequest"))) {
        controlRequest(request);
        return;
    }

    OSCollectionIterator* i = OSCollectionIterator::withCollection(dict);
    IOReturn ret;

    if (i) {
        while (OSString* key = OSDynamicCast(OSString, i->getNextObject())) {
            if (key->isEqualTo(batteryPrompt)) {
                OSNumber *value;
                getPropertyNumber(batteryPrompt);
                if (value->unsigned64BitValue() > BAT_SECONDARY) continue;
                batnum = value->unsigned32BitValue();
                updateBattery();
            } else if (key->isEqualTo("setCMstart")) {
                OSNumber *value;
                getPropertyNumber("setCMstart");
                setConservation(setCMstart, value->unsigned64BitValue());
            } else if (key->isEqualTo("setCMstop")) {
                OSNumber *value;
                getPropertyNumber("setCMstop");
                setConservation(setCMstop, value->unsigned64BitValue());
            } else if (key->isEqualTo("setCMInhibitCharge")) {
                OSNumber *value;
                getPropertyNumber("setCMInhibitCharge");
                setConservation(setCMInhibitCharge, value->unsigned64BitValue());
            } else if (key->isEqualTo("setCMForceDischarge")) {
                OSNumber *value;
                getPropertyNumber("setCMForceDischarge");
                setConservation(setCMForceDischarge, value->unsigned64BitValue());
            } else if (key->isEqualTo("setCMPeakShiftState")) {
                OSNumber *value;
                getPropertyNumber("setCMPeakShiftState");
                setConservation(setCMPeakShiftState, value->unsigned64BitValue());
            } else if (key->isEqualTo("GHSL")) {
                UInt32 result;
                if (evaluateIntegerParam("GHKL", &result, 0) == kIOReturnSuccess)
                    DebugLog(updateSuccess, "GHSL", result);
                else
                    AlwaysLog(updateFailure, "GHSL");
#ifdef DEBUG
            } else if (key->isEqualTo(localePrompt)) {
                OSNumber *value;
                getPropertyNumber(localePrompt);
                setKBDLocale(value->unsigned16BitValue());
            } else if (key->isEqualTo("SCPF")) {
                OSNumber *value;
                getPropertyNumber("SCPF");
                UInt32 raw = value->unsigned32BitValue();
                OSObject* params[4] = {
                    OSNumber::withNumber((raw >> 24) & 0xff, 8),
                    OSNumber::withNumber((raw >> 16) & 0xff, 8),
                    OSNumber::withNumber((raw >> 8) & 0xff, 8),
                    OSNumber::withNumber((raw & 0xff), 8)
                };

                if (!params[0] || !params[1] || !params[2] || !params[3]) {
                    for (auto &param : params) OSSafeReleaseNULL(param);
                    continue;
                }
                ret = vpc->evaluateObject("SCPF", nullptr, params, 4);
                if (ret == kIOReturnSuccess)
                    DebugLog(updateSuccess, "SCPF", value->unsigned8BitValue());
                else
                    AlwaysLog("%s evaluation failed 0x%x", "SCPF", ret);
                params[0]->release();
                params[1]->release();
                params[2]->release();
                params[3]->release();
#endif
            } else if (key->isEqualTo(mutePrompt)) {
                OSNumber *value;
                getPropertyNumber(mutePrompt);
                setMutestatus(value->unsigned32BitValue());
            } else if (key->isEqualTo(muteLEDPrompt)) {
                OSBoolean *value;
                getPropertyBoolean(muteLEDPrompt);
                setMuteLEDStatus(value->getValue());
            } else if (key->isEqualTo(micMuteLEDPrompt)) {
                OSNumber *value;
                getPropertyNumber(micMuteLEDPrompt);
                setMicMuteLEDStatus(value->unsigned32BitValue());
            } else if (key->isEqualTo(muteSupportPrompt)) {
                OSBoolean *value;
                getPropertyBoolean(muteSupportPrompt);
                setMuteSupport(value->getValue());
            } else if (key->isEqualTo(beepPrompt)) {
                OSBoolean * status = OSDynamicCast(OSBoolean, dict->getObject(beepPrompt));
                if (status != nullptr) {
                    enableBeep(status->getValue());
                    continue;
                }
                OSNumber *value;
                getPropertyNumber(beepPrompt);
                setBeepStatus(value->unsigned8BitValue());
            } else if (key->isEqualTo(SSTPrompt)) {
                OSNumber *value;
                getPropertyNumber(SSTPrompt);
                if (value->unsigned32BitValue() >= 5)
                    AlwaysLog(valueInvalid, SSTPrompt);
                else
                    setSSTStatus(value->unsigned32BitValue());
            } else if (key->isEqualTo(LEDPrompt)) {
                if (!LEDSupport) {
                    AlwaysLog(notSupported, LEDPrompt);
                    continue;
                }
                OSNumber *value;
                getPropertyNumber(LEDPrompt);
                if (value->unsigned32BitValue() >= 0xff)
                    AlwaysLog(valueInvalid, LEDPrompt);
                else
                    setLEDStatus(value->unsigned8BitValue());
            } else if (key->isEqualTo(fanControlPrompt)) {
                OSNumber *value;
                getPropertyNumber(fanControlPrompt);
                updateFanControl(value->unsigned32BitValue());
            } else if (key->isEqualTo(fanSpeedPrompt)) {
                OSNumber *value;
                getPropertyNumber(fanSpeedPrompt);
                if (value->unsigned64BitValue() > 0xff) {
                    AlwaysLog(valueInvalid, fanSpeedPrompt);
                    continue;
                }
                UInt8 speed = value->unsigned8BitValue();
                if (speed > 7) {
                    speed = speed < 0x80 ? 0x47 : 0x84;
                }
                UInt8 sample[3] {};
                ret = accessThinkFan(0, speed, sample);
                if (ret == kIOReturnSuccess)
                    DebugLog(updateSuccess, fanSpeedPrompt, speed);
                else
                    AlwaysLog("%s update failed 0x%x", fanSpeedPrompt, ret);
            } else if (key->isEqualTo(updatePrompt)) {
                updateAll();
            } else {
                OSDictionary *entry = OSDictionary::withCapacity(1);
                if (!entry) continue;
                entry->setObject(key, dict->getObject(key));
                super::setPropertiesGated(entry);
                entry->release();
            }
        }
        i->release();
    }

    return;
}

bool ThinkVPC::updateFanControl(UInt32 status, bool update) {
    if (evaluateIntegerParam(getThermalControl, &thermalstate, status) != kIOReturnSuccess) {
        AlwaysLog(updateFailure, __func__);
        return false;
    }

    if (update) {
        DebugLog(updateSuccess, __func__, thermalstate);
    }
    setProperty(fanControlPrompt, thermalstate, 32);
    return true;
}

bool ThinkVPC::setFanControl(int level) {
    UInt32 result;
    if (evaluateIntegerParam(setThermalControl, &result, (level ? BIT(18) : 0)) != kIOReturnSuccess) {
        AlwaysLog(toggleFailure, fanControlPrompt);
        return false;
    }
    if (!result) {
        AlwaysLog(toggleFailure, "FanControl0");
        return false;
    }

    DebugLog(toggleSuccess, fanControlPrompt, (level ? BIT(18) : 0), (level ? "7" : "auto"));
    setProperty(fanControlPrompt, level, 32);
    return true;
}

bool ThinkVPC::updateMuteLEDStatus(bool update) {
    if (evaluateIntegerParam(getAudioMuteLED, &muteLEDstate, 0) != kIOReturnSuccess) {
        AlwaysLog(updateFailure, __func__);
        return false;
    }

    if (update)
        DebugLog(updateSuccess, __func__, muteLEDstate);

    setProperty(muteLEDPrompt, muteLEDstate, 32);
    return true;
}

bool ThinkVPC::setMuteSupport(bool support) {
    UInt32 result;
    IOReturn ret;

    ret = evaluateIntegerParam(setAudioMuteSupport, &result, support);
    if (ret != kIOReturnSuccess || result & TPACPI_AML_MUTE_ERROR_STATE_MASK) {
        AlwaysLog(toggleError, muteSupportPrompt, ret ?: result);
        return false;
    }

    DebugLog(toggleSuccess, muteSupportPrompt, support, (support ? "disable" : "enable"));
    setProperty(muteSupportPrompt, support);
    return true;
}

bool ThinkVPC::setBeepStatus(UInt8 status) {
    if (evaluateIntegerParam(setBeep, nullptr, status) != kIOReturnSuccess) {
        AlwaysLog(toggleFailure, beepPrompt);
        return false;
    }

    DebugLog(toggleSuccess, beepPrompt, status, (status ? "on" : "off"));
    setProperty(beepPrompt, status);
    return true;
}

bool ThinkVPC::enableBeep(bool enable) {
    if (evaluateIntegerParam(setHKEYBeep, nullptr, enable) != kIOReturnSuccess) {
        AlwaysLog(toggleFailure, beepPrompt);
        return false;
    }

    DebugLog(toggleSuccess, beepPrompt, enable, (enable ? "enabled" : "disabled"));
    setProperty(beepPrompt, enable);
    return true;
}

bool ThinkVPC::setLEDStatus(UInt8 status) {
    OSObject* params[] = {
        OSNumber::withNumber(status & 0x0f, 32),
        OSNumber::withNumber(status & 0xf0, 32),
    };

    if (!params[0] || !params[1]) {
        OSSafeReleaseNULL(params[0]);
        OSSafeReleaseNULL(params[1]);
        return false;
    }

    IOReturn ret = ec->evaluateObject(setLED, nullptr, params, 2);
    params[0]->release();
    params[1]->release();
    if (ret != kIOReturnSuccess) {
        AlwaysLog(toggleFailure, LEDPrompt);
        return false;
    }

    DebugLog(toggleSuccess, LEDPrompt, status, (status ? "on" : "off"));
    return true;
}

bool ThinkVPC::setMuteLEDStatus(bool status) {
    UInt32 result;
    if (evaluateIntegerParam(setAudioMuteLED, &result, status) != kIOReturnSuccess) {
        AlwaysLog(toggleFailure, muteLEDPrompt);
        return false;
    }

    DebugLog(toggleSuccess, muteLEDPrompt, status, (status ? "on" : "off"));
    setProperty(muteLEDPrompt, status);
    return true;
}

bool ThinkVPC::updateMicMuteLEDStatus(bool update) {
    if (vpc->evaluateInteger(getMicMuteLED, &micMuteLEDcap) != kIOReturnSuccess) {
        AlwaysLog(updateFailure, __func__);
        return false;
    }

    if (update)
        DebugLog(updateSuccess, __func__, micMuteLEDcap);

    if (micMuteLEDcap & TPACPI_AML_MIC_MUTE_HDMC)
        setProperty(micMuteLEDPrompt, "HDMC");
    else
        setProperty(micMuteLEDPrompt, micMuteLEDcap, 32);
    return true;
}

bool ThinkVPC::setMicMuteLEDStatus(UInt32 status) {
    if (evaluateIntegerParam(setMicMuteLED, nullptr, status) != kIOReturnSuccess) {
        AlwaysLog(toggleFailure, micMuteLEDPrompt);
        return false;
    }

    micMuteLEDstate = status;
    DebugLog(toggleSuccess, micMuteLEDPrompt, status, (status ? "on / blink" : "off"));
    setProperty(micMuteLEDPrompt, status, 32);
    return true;
}

IOReturn ThinkVPC::message(UInt32 type, IOService *provider, void *argument) {
    if (getProperty("SafeMode") == kOSBooleanTrue) return kIOReturnUnsupported;
    switch (type)
    {
        // TODO: determine default value for charge level
        case kSMC_getConservation:
        case kSMC_setConservation:
            break;

        case kIOACPIMessageDeviceNotification:
            if (argument && *(reinterpret_cast<UInt32 *>(argument)) == kIOACPIMessageReserved) {
                if (!commandGate || isInactive()) return kIOReturnNotReady;
                return commandGate->runAction([](OSObject *owner, void *, void *, void *, void *) -> IOReturn {
                    auto self = static_cast<ThinkVPC *>(owner);
                    if (self->isInactive()) return kIOReturnNotAttached;
                    self->updateVPC();
                    return kIOReturnSuccess;
                });
            }

        default:
            return super::message(type, provider, argument);
    }

    return kIOReturnSuccess;
}

UInt32 ThinkVPC::updateThermalMode() {
    UInt32 mode;
    if (evaluateIntegerParam(getThermalModeState, &mode, 0) != kIOReturnSuccess)
        mode = 0;
    return mode;
}

UInt32 ThinkVPC::updateYogaMode() {
    if (!yogaModeSupport)
        return 0;

    UInt32 mode;
    if (evaluateIntegerParam(getMultiModeState, &mode, 0) != kIOReturnSuccess) {
        AlwaysLog("failed to evaluate tablet mode");
        return 0;
    }

#ifdef DEBUG
    UInt32 rawMode;
    if (ec->evaluateInteger("CMMD", &rawMode) != kIOReturnSuccess)
        AlwaysLog("failed to evaluate raw tablet mode");
    else
        DebugLog("tablet mode: %x, raw: %x", mode, rawMode);
#else
    DebugLog("tablet mode: %x", mode);
#endif
    if (!validModes) {
        UInt16 type = mode >> 16;
        setProperty("MultiModeType", type, 16);
        switch (type) {
            case 1:
                validModes = TP_ACPI_MULTI_MODE_LAPTOP |
                             TP_ACPI_MULTI_MODE_TABLET |
                             TP_ACPI_MULTI_MODE_STAND_TENT;
                break;
            case 2:
                validModes = TP_ACPI_MULTI_MODE_LAPTOP |
                             TP_ACPI_MULTI_MODE_FLAT |
                             TP_ACPI_MULTI_MODE_TABLET |
                             TP_ACPI_MULTI_MODE_STAND |
                             TP_ACPI_MULTI_MODE_TENT;
                break;
            case 3:
                validModes = TP_ACPI_MULTI_MODE_LAPTOP |
                             TP_ACPI_MULTI_MODE_FLAT;
                break;
            case 4:
            case 5:
                /* In mode 4, FLAT is not specified as a valid mode. However,
                 * it can be seen at least on the X1 Yoga 2nd Generation.
                 */
                validModes = TP_ACPI_MULTI_MODE_LAPTOP |
                             TP_ACPI_MULTI_MODE_FLAT |
                             TP_ACPI_MULTI_MODE_TABLET |
                             TP_ACPI_MULTI_MODE_STAND |
                             TP_ACPI_MULTI_MODE_TENT;
                break;
                
            default:
                AlwaysLog("unknown tablet mode: %x", mode);
                validModes = TP_ACPI_MULTI_MODE_UNKNOWN;
                break;
        }
    }
    UInt32 data = mode & 0xf;
    switch (data) {
        case 1:
            if (validModes & TP_ACPI_MULTI_MODE_TABLET_LIKE)
                setTopCase(true);
            setProperty("YogaMode", "Laptop");
            break;
        case 2:
            if (validModes & TP_ACPI_MULTI_MODE_TABLET_LIKE)
                setTopCase(true);
            setProperty("YogaMode", "Flat");
            break;
        case 3:
            setTopCase(clamshellMode);
            setProperty("YogaMode", "Tablet");
            break;
        case 4:
            setTopCase(clamshellMode);
            if ((mode >> 16) == 1)
                setProperty("YogaMode", "Stand/Tent");
            else
                setProperty("YogaMode", "Stand");
            break;
        case 5:
            setTopCase(clamshellMode);
            setProperty("YogaMode", "Tent");
            break;
        default:
            setTopCase(true);
            AlwaysLog("unknown tablet mode: %x", mode);
            break;
    }
    return data;
}

void ThinkVPC::updateVPC(UInt32 event) {
    UInt32 result;
    if (vpc->evaluateInteger(getHKEYevent, &result) != kIOReturnSuccess) {
        AlwaysLog(toggleFailure, HotKeyPrompt);
        return;
    }

    if (!result) {
        DebugLog("empty HKEY event");
        return;
    }

    UInt32 data = 0;
    UInt64 time = 0;
    switch (result >> 0xC) {
        case 1:
            switch (result) {
                case TP_HKEY_EV_KBD_LIGHT:
                    updateBacklight(true);
                    data = backlightLevel;
                    if (isActive(&backlightStimulation))
                        data |= 0x10;
                    break;

                case TP_HKEY_EV_SLEEP:
                    if (!client)
                        vpc->evaluateObject(setHKEYsleep);
                    break;

                case TP_HKEY_EV_MIC_MUTE:
                    if (!client)
                        setMicMuteLEDStatus(micMuteLEDstate ? 0 : 2);
                    break;

                case TP_HKEY_EV_KEYBOARD:
                    toggleKeyboard();
                    data = Keyboardenabled;
                    break;

                default:
                    DebugLog("Hotkey(MHKP) key presses event: 0x%x", result);
                    break;
            }
            time = 1;
            break;

        case 2:
            DebugLog("Hotkey(MHKP) wakeup reason event: 0x%x", result);
            break;

        case 3:
            DebugLog("Hotkey(MHKP) bay-related wakeup event: 0x%x", result);
            break;

        case 4:
            DebugLog("Hotkey(MHKP) dock-related event: 0x%x", result);
            break;

        case 5:
            switch (result) {
                case TP_HKEY_EV_PEN_INSERTED:
                    DebugLog("tablet pen inserted into bay");
                    break;

                case TP_HKEY_EV_PEN_REMOVED:
                    DebugLog("tablet pen removed from bay");
                    break;

                case TP_HKEY_EV_TABLET_TABLET:
                    DebugLog("tablet mode");
                    break;

                case TP_HKEY_EV_TABLET_NOTEBOOK:
                    DebugLog("normal mode");
                    break;

                case TP_HKEY_EV_LID_CLOSE:
                    DebugLog("Lid closed");
                    break;

                case TP_HKEY_EV_LID_OPEN:
                    DebugLog("Lid opened");
                    break;

                case TP_HKEY_EV_BRGHT_CHANGED:
                    DebugLog("brightness changed");
                    break;

                default:
                    DebugLog("Hotkey(MHKP) unknown human interface event: 0x%x", result);
                    break;
            }
            break;

        case 6:
            switch (result) {
                case TP_HKEY_EV_THM_TABLE_CHANGED:
                    DebugLog("Thermal Table has changed");
                    break;

                case TP_HKEY_EV_THM_CSM_COMPLETED:
                    DebugLog("Thermal Control Command set completed (DYTC)");
                    updateDYTC();
                    break;

                case TP_HKEY_EV_THM_TRANSFM_CHANGED:
                    data = updateThermalMode();
                    if (data & 0x00010000)
                        DebugLog("Thermal Transformation changed: 0x%x", data);
                    else
                        AlwaysLog("Thermal Transformation changed: failed to evaluate GMTS");
                    break;

                case TP_HKEY_EV_ALARM_BAT_HOT:
                    AlwaysLog("THERMAL ALARM: battery is too hot!");
                    break;

                case TP_HKEY_EV_ALARM_BAT_XHOT:
                    AlwaysLog("THERMAL EMERGENCY: battery is extremely hot!");
                    break;

                case TP_HKEY_EV_ALARM_SENSOR_HOT:
                    AlwaysLog("THERMAL ALARM: a sensor reports something is too hot!");
                    break;

                case TP_HKEY_EV_ALARM_SENSOR_XHOT:
                    AlwaysLog("THERMAL EMERGENCY: a sensor reports something is extremely hot!");
                    break;

                case TP_HKEY_EV_AC_CHANGED:
                    DebugLog("AC status changed");
                    break;

                case TP_HKEY_EV_KEY_NUMLOCK:
                    DebugLog("Numlock");
                    time = 1;
                    break;

                case TP_HKEY_EV_KEY_FN:
                    DebugLog("Fn");
                    time = 1;
                    break;

                case TP_HKEY_EV_KEY_FN_ESC:
                    DebugLog("Fn+Esc");
                    time = 1;
                    updateFnLock();
                    data = FnlockMode;
                    break;

                case TP_HKEY_EV_LID_STATUS_CHANGED:
                    break;

                case TP_HKEY_EV_TABLET_CHANGED:
                    data = updateYogaMode();
                    if (clamshellMode) {
                        DebugLog("ClamshellMode enabled, skip Yoga mode notification");
                        return;
                    }
                    break;

                case TP_HKEY_EV_PALM_DETECTED:
                    DebugLog("palm detected hovering the keyboard");
                    break;

                case TP_HKEY_EV_PALM_UNDETECTED:
                    DebugLog("palm undetected hovering the keyboard");
                    break;

                default:
                    AlwaysLog("Hotkey(MHKP) unknown thermal alarms/notices and keyboard event: 0x%x", result);
                    break;
            }
            break;

        case 7:
            DebugLog("Hotkey(MHKP) misc event: 0x%x", result);
            break;

        default:
            DebugLog("Hotkey(MHKP) unknown event: 0x%x", result);
            break;
    }

    if (client)
        client->sendNotification(result, data);

    if (time != 0) {
        clock_get_uptime(&time);
        dispatchMessage(kPS2M_notifyKeyTime, &time);
    }
}

bool ThinkVPC::updateFnLock(bool update) {
    UInt32 result;
    if (vpc->evaluateInteger(getMediaKeyStatus, &result) != kIOReturnSuccess) {
        AlwaysLog(updateFailure, FnKeyPrompt);
        removeProperty(FnKeyPrompt);
        return false;
    }

    FnlockMode = result & 0x1;

    if (update) {
        DebugLog(toggleSuccess, FnKeyPrompt, result, (FnlockMode ? "enabled" : "disabled"));
    }
    setProperty(FnKeyPrompt, FnlockMode);
    return true;
}

bool ThinkVPC::setFnLock(bool enable) {
    UInt32 result;
    if (evaluateIntegerParam(setMediaKeyStatus, &result, enable) != kIOReturnSuccess) {
        AlwaysLog(toggleFailure, FnKeyPrompt);
        return false;
    }

    FnlockMode = enable;
    DebugLog(toggleSuccess, FnKeyPrompt, result, (FnlockMode ? "enabled" : "disabled"));
    setProperty(FnKeyPrompt, FnlockMode);
    return true;
}

bool ThinkVPC::setHotkeyStatus(bool enable) {
    UInt32 result;
    if (evaluateIntegerParam(setHKEYstatus, &result, enable) != kIOReturnSuccess) {
        AlwaysLog(toggleFailure, HotKeyPrompt);
        return false;
    }

    DebugLog(toggleSuccess, HotKeyPrompt, enable, (enable ? "enabled" : "disabled"));
    setProperty(HotKeyPrompt, enable);
    return true;
}

bool ThinkVPC::updateBacklight(bool update) {
    if (!backlightCap)
        return true;

    UInt32 state;
    if (evaluateIntegerParam(getKBDBacklightLevel, &state, 0) != kIOReturnSuccess) {
        AlwaysLog(updateFailure, backlightPrompt);
        removeProperty(backlightPrompt);
        return false;
    }

    backlightLevel = state & 0x3;

    if (update) {
        DebugLog(updateSuccess, backlightPrompt, state);
    }
    setProperty(backlightPrompt, backlightLevel, 32);
    return true;
}

bool ThinkVPC::setBacklight(UInt32 level) {
    if (level > 2 || !backlightCap)
        return false;

    UInt32 result;
    IOReturn ret;

    ret = evaluateIntegerParam(setKBDBacklightLevel, &result, level);
    if (ret != kIOReturnSuccess || result != 0) {
        AlwaysLog(toggleError, backlightPrompt, ret ?: result);
        return false;
    }

    backlightLevel = level;
    DebugLog(toggleSuccess, backlightPrompt, backlightLevel, (backlightLevel ? "on" : "off"));
    setProperty(backlightPrompt, backlightLevel, 32);

    return true;
}

bool ThinkVPC::setSSTStatus(UInt32 value) {
#ifdef DEBUG
    char const *property[5] = {"Indicator off", "Working", "Waking", "Sleeping", "Hibernating"};
#endif
    if (vpc->validateObject("CSSI") == kIOReturnSuccess) {
        if (evaluateIntegerParam("CSSI", nullptr, value) != kIOReturnSuccess) {
            AlwaysLog(toggleFailure, "SST Proxy");
            return false;
        }

        DebugLog(toggleSuccess, "SST Proxy", value, property[value]);
        return true;
    }
    if (!LEDSupport)
        return true;
    // Replicate of _SI._SST
    // 0x0: power
    // 0x7: standby
    // 0xA: thinkdot
    bool status = true;
    switch (value) {
        case 0:
            status = setLEDStatus(0x00) && setLEDStatus(0x0A) && setLEDStatus(0x07);
            break;

        case 1:
            status = setLEDStatus(0x80) && setLEDStatus(0x8A) && setLEDStatus(0x07);
            break;

        case 2:
            status = setLEDStatus(0xC0) && setLEDStatus(0xCA) && setLEDStatus(0xC7);
            break;

        case 3:
            status = setLEDStatus(0xC7) && setLEDStatus(0xC0) && setLEDStatus(0xCA);
            break;

        case 4:
            status = setLEDStatus(0xC7) && setLEDStatus(0xC0) && setLEDStatus(0xCA);
            break;

        default:
            AlwaysLog(valueInvalid, SSTPrompt);
            return false;
    }

    if (status)
        DebugLog(toggleSuccess, SSTPrompt, value, property[value]);
    else
        AlwaysLog(toggleFailure, SSTPrompt);
    return status;
}

bool ThinkVPC::updateKBDLocale(bool update) {
    IOReturn ret = vpc->validateObject(getKBDLang);
    if (ret == kIOReturnNoDevice) {
        return true;
    } else if (ret != kIOReturnSuccess) {
        AlwaysLog(updateFailure, localePrompt);
        return false;
    }

    UInt32 locale;
    if (evaluateIntegerParam(getKBDLang, &locale, 0x02000000) != kIOReturnSuccess) {
        AlwaysLog(updateFailure, localePrompt);
        return false;
    }

    if (update)
        DebugLog(updateSuccess, localePrompt, locale);
    setProperty(localePrompt, locale, 32);

    return true;
}

bool ThinkVPC::setKBDLocale(UInt32 value) {
    UInt32 result;
    if (evaluateIntegerParam(setKBDLang, &result, (value | BIT(24))) != kIOReturnSuccess) {
        AlwaysLog(toggleFailure, localePrompt);
        return false;
    }

    DebugLog(toggleSuccess, localePrompt, value, "-");
    setProperty(localePrompt, value, 32);
    return true;
}

IOReturn ThinkVPC::setPowerState(unsigned long powerStateOrdinal, IOService * whatDevice) {
    if (getProperty("SafeMode") == kOSBooleanTrue) return kIOPMAckImplied;
    if (super::setPowerState(powerStateOrdinal, whatDevice) != kIOPMAckImplied)
        return kIOReturnInvalid;

    if (powerStateOrdinal == 0) {
        restoreThinkFans();
        if (automaticBacklightMode & BIT(2))
            setSSTStatus(3);
        if ((automaticBacklightMode & BIT(3))) {
            muteLEDstateSaved = muteLEDstate;
            if (muteLEDstate)
                setMuteLEDStatus(false);
        }
        if (automaticBacklightMode & BIT(4)) {
            micMuteLEDstateSaved = micMuteLEDstate;
            if (micMuteLEDstate)
                setMicMuteLEDStatus(0);
        }
    } else {
        setHotkeyStatus(true);
        for (UInt32 i = 0; i < 32; ++i) {
            if ((hotkey_all_mask & BIT(i)) &&
                !setNotificationMask(i, hotkey_all_mask, DHKN_MASK_offset)) break;
        }
        if (automaticBacklightMode & BIT(2))
            setSSTStatus(1);
        if ((automaticBacklightMode & BIT(3)) && muteLEDstateSaved)
            setMuteLEDStatus(true);
        if ((automaticBacklightMode & BIT(4)) && micMuteLEDstateSaved)
            setMicMuteLEDStatus(micMuteLEDstateSaved);
    }

    return kIOPMAckImplied;
}
