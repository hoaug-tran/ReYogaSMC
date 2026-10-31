// SPDX-License-Identifier: GPL-2.0-only
// Original work: Copyright (c) 2020 Zhen.

#include "ThinkVPC.hpp"
#include "ControlRequest.hpp"

bool ThinkVPC::updateConservation(const char *method, OSDictionary *bat, bool logChanges) {
    UInt32 result;
    if (evaluateIntegerParam(method, &result, batnum) != kIOReturnSuccess || (result & BIT(31))) {
        AlwaysLog(updateFailure, method);
        return false;
    }

    if (logChanges)
        DebugLog(updateSuccess, method, result);

    ReYogaProperty::setNumber(bat, method, result, 32);

    return true;
}

bool ThinkVPC::setConservation(const char *method, UInt64 value) {
    if (value > 0xff || vpc->validateObject(method) != kIOReturnSuccess)
        return false;
    UInt32 parameter = (batnum << 8) | static_cast<UInt32>(value);
    const bool start = !strcmp(method, setCMstart);
    const bool stop = !strcmp(method, setCMstop);
    if (start || stop) {
        UInt32 own = 0, other = 0;
        if (evaluateIntegerParam(start ? getCMstart : getCMstop, &own, batnum) != kIOReturnSuccess ||
            evaluateIntegerParam(start ? getCMstop : getCMstart, &other, batnum) != kIOReturnSuccess ||
            !ReYogaControl::validThresholdState(own, stop) || !ReYogaControl::validThresholdState(other, start) ||
            !ReYogaControl::validThresholdTarget(ReYogaControl::thresholdPercent(static_cast<UInt32>(value), stop), start,
                                                 ReYogaControl::thresholdPercent(other, start)))
            return false;
    } else if (!strcmp(method, setCMInhibitCharge) || !strcmp(method, setCMForceDischarge)) {
        const bool inhibit = !strcmp(method, setCMInhibitCharge);
        UInt32 capability = 0;
        if (value > 1 || evaluateIntegerParam(inhibit ? getCMInhibitCharge : getCMForceDischarge, &capability, batnum) != kIOReturnSuccess ||
            (capability & BIT(31)) || !(capability & BIT(inhibit ? 5 : 8)))
            return false;
        if (inhibit)
            parameter = (batnum << 4) | 0x00ffff00U | static_cast<UInt32>(value);
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

bool ThinkVPC::updateMutestatus(bool logChanges) {
    if (ec->evaluateInteger(getAudioMutestatus, &mutestate) != kIOReturnSuccess) {
        AlwaysLog(updateFailure, __func__);
        return false;
    }

    if (logChanges)
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

void ThinkVPC::updateBattery() {
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
    if (!bat)
        return;
    bool complete = true;
    const char *methods[] = {getCMstart, getCMstop, getCMInhibitCharge, getCMForceDischarge, getCMPeakShiftState};
    for (const char *method : methods) {
        if (vpc->validateObject(method) == kIOReturnSuccess)
            complete = updateConservation(method, bat) && complete;
    }
    if (!complete)
        AlwaysLog(updateFailure, batteryPrompt);

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
    if (!features)
        return;
    auto add = [&](const char *key, bool available, const char *reason) {
        auto feature = OSDictionary::withCapacity(3);
        if (!feature)
            return;
        feature->setObject("Available", available ? kOSBooleanTrue : kOSBooleanFalse);
        ReYogaProperty::setString(feature, "Reason", available ? "" : reason);
        ReYogaProperty::setString(feature, "Backend", "ThinkPad ACPI");
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
        if (supported)
            setProperty(keys[i], value, 32);
        else
            removeProperty(keys[i]);
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
    UInt32 profile = mode && mode->isEqualTo("Quiet") ? 1 : mode && mode->isEqualTo("Balance")                            ? 2
                                                        : mode && (!strncmp(mode->getCStringNoCopy(), "Performance", 11)) ? 3
                                                                                                                          : 0;
    const bool thermalSupported = supportsThermalProfiles();
    add("SmartFanMode", thermalSupported, "DYTC desk thermal profiles unavailable");
    if (thermalSupported) {
        if (profile != 0)
            setProperty("SmartFanMode", profile, 32);
        else
            removeProperty("SmartFanMode");
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
    ReYogaControl::ControlEnvelope envelope;
    if (!ReYogaControl::parseControlEnvelope(request, envelope))
        return;
    auto key = envelope.property;
    auto number = OSDynamicCast(OSNumber, envelope.value);
    auto boolean = OSDynamicCast(OSBoolean, envelope.value);
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
                status = setUserBacklight(target) ? kIOReturnSuccess : kIOReturnIOError;
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
    if (status == kIOReturnSuccess)
        updateAll();
    OSObject *actual = getProperty(name);
    auto result = ReYogaControl::makeControlResult(envelope, actual, commandStatus, status);
    if (!result)
        return;
    ReYogaProperty::setString(result, "Reason", status == kIOReturnSuccess ? "Firmware readback matched" : status == kIOReturnBadArgument ? "Invalid type, threshold ordering or value"
                                                                                                       : status == kIOReturnUnsupported   ? "Feature unavailable; inspect FeatureStatus"
                                                                                                                                          : "Firmware call failed or readback did not match");
    setProperty("LastControlResult", result);
    result->release();
}

void ThinkVPC::setPropertiesGated(OSObject *props) {
    OSDictionary *dict = OSDynamicCast(OSDictionary, props);
    if (!dict)
        return;

    if (auto update = OSDynamicCast(OSBoolean, dict->getObject("UpdateFans"))) {
        if (update->getValue())
            updateFans();
        return;
    }

    if (auto request = OSDynamicCast(OSDictionary, dict->getObject("ControlRequest"))) {
        controlRequest(request);
        return;
    }

    OSCollectionIterator *i = OSCollectionIterator::withCollection(dict);
    IOReturn ret;

    if (i) {
        while (OSString *key = OSDynamicCast(OSString, i->getNextObject())) {
            if (key->isEqualTo(batteryPrompt)) {
                auto value = ReYogaProperty::get<OSNumber>(dict, batteryPrompt);
                if (!value) {
                    AlwaysLog(valueInvalid, batteryPrompt);
                    continue;
                }
                if (value->unsigned64BitValue() > BAT_SECONDARY)
                    continue;
                batnum = value->unsigned32BitValue();
                updateBattery();
            } else if (key->isEqualTo("setCMstart")) {
                auto value = ReYogaProperty::get<OSNumber>(dict, "setCMstart");
                if (!value) {
                    AlwaysLog(valueInvalid, "setCMstart");
                    continue;
                }
                setConservation(setCMstart, value->unsigned64BitValue());
            } else if (key->isEqualTo("setCMstop")) {
                auto value = ReYogaProperty::get<OSNumber>(dict, "setCMstop");
                if (!value) {
                    AlwaysLog(valueInvalid, "setCMstop");
                    continue;
                }
                setConservation(setCMstop, value->unsigned64BitValue());
            } else if (key->isEqualTo("setCMInhibitCharge")) {
                auto value = ReYogaProperty::get<OSNumber>(dict, "setCMInhibitCharge");
                if (!value) {
                    AlwaysLog(valueInvalid, "setCMInhibitCharge");
                    continue;
                }
                setConservation(setCMInhibitCharge, value->unsigned64BitValue());
            } else if (key->isEqualTo("setCMForceDischarge")) {
                auto value = ReYogaProperty::get<OSNumber>(dict, "setCMForceDischarge");
                if (!value) {
                    AlwaysLog(valueInvalid, "setCMForceDischarge");
                    continue;
                }
                setConservation(setCMForceDischarge, value->unsigned64BitValue());
            } else if (key->isEqualTo("setCMPeakShiftState")) {
                auto value = ReYogaProperty::get<OSNumber>(dict, "setCMPeakShiftState");
                if (!value) {
                    AlwaysLog(valueInvalid, "setCMPeakShiftState");
                    continue;
                }
                setConservation(setCMPeakShiftState, value->unsigned64BitValue());
            } else if (key->isEqualTo("GHSL")) {
                UInt32 result;
                if (evaluateIntegerParam("GHKL", &result, 0) == kIOReturnSuccess)
                    DebugLog(updateSuccess, "GHSL", result);
                else
                    AlwaysLog(updateFailure, "GHSL");
#ifdef DEBUG
            } else if (key->isEqualTo(localePrompt)) {
                auto value = ReYogaProperty::get<OSNumber>(dict, localePrompt);
                if (!value) {
                    AlwaysLog(valueInvalid, localePrompt);
                    continue;
                }
                setKBDLocale(value->unsigned16BitValue());
            } else if (key->isEqualTo("SCPF")) {
                auto value = ReYogaProperty::get<OSNumber>(dict, "SCPF");
                if (!value) {
                    AlwaysLog(valueInvalid, "SCPF");
                    continue;
                }
                UInt32 raw = value->unsigned32BitValue();
                OSObject *params[4] = {
                    OSNumber::withNumber((raw >> 24) & 0xff, 8),
                    OSNumber::withNumber((raw >> 16) & 0xff, 8),
                    OSNumber::withNumber((raw >> 8) & 0xff, 8),
                    OSNumber::withNumber((raw & 0xff), 8)};

                if (!params[0] || !params[1] || !params[2] || !params[3]) {
                    for (auto &param : params)
                        OSSafeReleaseNULL(param);
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
                auto value = ReYogaProperty::get<OSNumber>(dict, mutePrompt);
                if (!value) {
                    AlwaysLog(valueInvalid, mutePrompt);
                    continue;
                }
                setMutestatus(value->unsigned32BitValue());
            } else if (key->isEqualTo(muteLEDPrompt)) {
                auto value = ReYogaProperty::get<OSBoolean>(dict, muteLEDPrompt);
                if (!value) {
                    AlwaysLog(valueInvalid, muteLEDPrompt);
                    continue;
                }
                setMuteLEDStatus(value->getValue());
            } else if (key->isEqualTo(micMuteLEDPrompt)) {
                auto value = ReYogaProperty::get<OSNumber>(dict, micMuteLEDPrompt);
                if (!value) {
                    AlwaysLog(valueInvalid, micMuteLEDPrompt);
                    continue;
                }
                setMicMuteLEDStatus(value->unsigned32BitValue());
            } else if (key->isEqualTo(muteSupportPrompt)) {
                auto value = ReYogaProperty::get<OSBoolean>(dict, muteSupportPrompt);
                if (!value) {
                    AlwaysLog(valueInvalid, muteSupportPrompt);
                    continue;
                }
                setMuteSupport(value->getValue());
            } else if (key->isEqualTo(beepPrompt)) {
                OSBoolean *status = OSDynamicCast(OSBoolean, dict->getObject(beepPrompt));
                if (status != nullptr) {
                    enableBeep(status->getValue());
                    continue;
                }
                auto value = ReYogaProperty::get<OSNumber>(dict, beepPrompt);
                if (!value) {
                    AlwaysLog(valueInvalid, beepPrompt);
                    continue;
                }
                setBeepStatus(value->unsigned8BitValue());
            } else if (key->isEqualTo(SSTPrompt)) {
                auto value = ReYogaProperty::get<OSNumber>(dict, SSTPrompt);
                if (!value) {
                    AlwaysLog(valueInvalid, SSTPrompt);
                    continue;
                }
                if (value->unsigned32BitValue() >= 5)
                    AlwaysLog(valueInvalid, SSTPrompt);
                else
                    setSSTStatus(value->unsigned32BitValue());
            } else if (key->isEqualTo(LEDPrompt)) {
                if (!LEDSupport) {
                    AlwaysLog(notSupported, LEDPrompt);
                    continue;
                }
                auto value = ReYogaProperty::get<OSNumber>(dict, LEDPrompt);
                if (!value) {
                    AlwaysLog(valueInvalid, LEDPrompt);
                    continue;
                }
                if (value->unsigned32BitValue() >= 0xff)
                    AlwaysLog(valueInvalid, LEDPrompt);
                else
                    setLEDStatus(value->unsigned8BitValue());
            } else if (key->isEqualTo(fanControlPrompt)) {
                auto value = ReYogaProperty::get<OSNumber>(dict, fanControlPrompt);
                if (!value) {
                    AlwaysLog(valueInvalid, fanControlPrompt);
                    continue;
                }
                updateFanControl(value->unsigned32BitValue());
            } else if (key->isEqualTo(fanSpeedPrompt)) {
                auto value = ReYogaProperty::get<OSNumber>(dict, fanSpeedPrompt);
                if (!value) {
                    AlwaysLog(valueInvalid, fanSpeedPrompt);
                    continue;
                }
                if (value->unsigned64BitValue() > 0xff) {
                    AlwaysLog(valueInvalid, fanSpeedPrompt);
                    continue;
                }
                UInt8 speed = value->unsigned8BitValue();
                if (speed > 7) {
                    speed = speed < 0x80 ? 0x47 : 0x84;
                }
                UInt8 sample[3]{};
                ret = accessThinkFan(0, speed, sample);
                if (ret == kIOReturnSuccess)
                    DebugLog(updateSuccess, fanSpeedPrompt, speed);
                else
                    AlwaysLog("%s update failed 0x%x", fanSpeedPrompt, ret);
            } else if (key->isEqualTo(updatePrompt)) {
                updateAll();
            } else {
                setPropertyGated(key->getCStringNoCopy(), dict->getObject(key));
            }
        }
        i->release();
    }

    return;
}

bool ThinkVPC::updateMuteLEDStatus(bool logChanges) {
    if (evaluateIntegerParam(getAudioMuteLED, &muteLEDstate, 0) != kIOReturnSuccess) {
        AlwaysLog(updateFailure, __func__);
        return false;
    }

    if (logChanges)
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
    OSObject *params[] = {
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

bool ThinkVPC::updateMicMuteLEDStatus(bool logChanges) {
    if (vpc->evaluateInteger(getMicMuteLED, &micMuteLEDcap) != kIOReturnSuccess) {
        AlwaysLog(updateFailure, __func__);
        return false;
    }

    if (logChanges)
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

bool ThinkVPC::updateFnLock(bool logChanges) {
    UInt32 result;
    if (vpc->evaluateInteger(getMediaKeyStatus, &result) != kIOReturnSuccess) {
        AlwaysLog(updateFailure, FnKeyPrompt);
        removeProperty(FnKeyPrompt);
        return false;
    }

    FnlockMode = result & 0x1;

    if (logChanges) {
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

bool ThinkVPC::updateBacklight(bool logChanges) {
    if (!backlightCap)
        return true;

    UInt32 state;
    if (evaluateIntegerParam(getKBDBacklightLevel, &state, 0) != kIOReturnSuccess) {
        AlwaysLog(updateFailure, backlightPrompt);
        removeProperty(backlightPrompt);
        return false;
    }

    backlightLevel = state & 0x3;

    if (logChanges) {
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

bool ThinkVPC::updateKBDLocale(bool logChanges) {
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

    if (logChanges)
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
