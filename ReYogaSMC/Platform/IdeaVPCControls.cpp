// SPDX-License-Identifier: GPL-2.0-only
// Original work: Copyright (c) 2020 Zhen.

#include "IdeaVPC.hpp"
#include "ControlRequest.hpp"
#include "../WMI/IdeaWMI.hpp"

void IdeaVPC::setPropertiesGated(OSObject *props) {
    OSDictionary *dict = OSDynamicCast(OSDictionary, props);
    if (!dict)
        return;
    if (safeMode) {
        AlwaysLog("Ignoring property request while safe mode is enabled");
        return;
    }
    if (auto request = OSDynamicCast(OSDictionary, dict->getObject("ControlRequest"))) {
        controlRequest(request);
        return;
    }
    if (auto value = OSDynamicCast(OSBoolean, dict->getObject("DetailedTelemetry"))) {
        detailedTelemetry = value->getValue();
        setProperty("DetailedTelemetry", detailedTelemetry);
        AlwaysLog("diagnostics detailedTelemetry=%d", detailedTelemetry);
        return;
    }
    if (dict->getObject("RefreshSensors")) {
        updateTelemetry();
        return;
    }

    OSCollectionIterator *i = OSCollectionIterator::withCollection(dict);

    if (i) {
        while (OSString *key = OSDynamicCast(OSString, i->getNextObject())) {
            auto features = OSDynamicCast(OSDictionary, getProperty("FeatureStatus"));
            if (features && features->getObject(key->getCStringNoCopy())) {
                auto request = OSDictionary::withCapacity(3);
                if (request) {
                    char requestID[32];
                    snprintf(requestID, sizeof(requestID), "legacy-%llu", sampleSequence);
                    auto id = OSString::withCString(requestID);
                    if (id) {
                        request->setObject("RequestID", id);
                        request->setObject("Property", key);
                        request->setObject("Value", dict->getObject(key));
                        controlRequest(request);
                        id->release();
                    }
                    request->release();
                }
                continue;
            }
            if (key->isEqualTo(alwaysOnUSBPrompt)) {
                OSBoolean *bval = OSDynamicCast(OSBoolean, dict->getObject(alwaysOnUSBPrompt));
                OSNumber *nval = OSDynamicCast(OSNumber, dict->getObject(alwaysOnUSBPrompt));
                if (nval != nullptr)
                    setAlwaysOnUSBState(nval->unsigned32BitValue());
                else if (bval != nullptr)
                    setAlwaysOnUSBState(bval->getValue() ? 1 : 0);
                else
                    toggleAlwaysOnUSB();
            } else if (key->isEqualTo(ECLockPrompt)) {
                auto value = ReYogaProperty::get<OSBoolean>(dict, ECLockPrompt);
                if (!value) {
                    AlwaysLog(valueInvalid, ECLockPrompt);
                    continue;
                }
                if (value->getValue())
                    continue;

                ECLock = false;
                AlwaysLog("direct VPC EC manipulation is unlocked");
            } else if (key->isEqualTo(readECPrompt)) {
                if (ECLock)
                    continue;
                auto value = ReYogaProperty::get<OSNumber>(dict, readECPrompt);
                if (!value) {
                    AlwaysLog(valueInvalid, readECPrompt);
                    continue;
                }

                UInt32 result;
                UInt32 retries = 0;

                if (read_ec_data(value->unsigned32BitValue(), &result, &retries))
                    AlwaysLog("%s 0x%x result: 0x%x %d", readECPrompt, value->unsigned32BitValue(), result, retries);
                else
                    AlwaysLog("%s failed 0x%x %d", readECPrompt, value->unsigned32BitValue(), retries);
            } else if (key->isEqualTo(writeECPrompt)) {
                AlwaysLog("Raw VPC writes are unsupported; use a capability-checked control");
            } else if (key->isEqualTo(batteryPrompt)) {
                auto value = ReYogaProperty::get<OSBoolean>(dict, batteryPrompt);
                if (!value) {
                    AlwaysLog(valueInvalid, batteryPrompt);
                    continue;
                }
                conservationModeLock = value->getValue();
            } else if (key->isEqualTo(updatePrompt)) {
                updateAll();
            } else if (key->isEqualTo(resetPrompt)) {
                updateKeyboardCapability();
                updateBatteryCapability();
            } else {
                setPropertyGated(key->getCStringNoCopy(), dict->getObject(key));
            }
        }
        i->release();
    }

    return;
}

bool IdeaVPC::toggleAlwaysOnUSB() {
    if (!alwaysOnUSBCap)
        return true;

    return setAlwaysOnUSBState(alwaysOnUSBMode ? 0 : 1);
}

bool IdeaVPC::setAlwaysOnUSBState(UInt32 state) {
    if (!alwaysOnUSBCap || state > 2)
        return false;

    UInt32 result = 0;
    IOReturn ret = evaluateIntegerParam(setKeyboardMode, &result,
                                        state == 0 ? HACMD_AOUSB_OFF : HACMD_AOUSB_ON);
    if (ret == kIOReturnSuccess)
        ret = evaluateIntegerParam(setKeyboardMode, &result,
                                   state == 2 ? HACMD_AOUSBBAT_ON : HACMD_AOUSBBAT_OFF);
    updateKeyboard(false);
    if (ret != kIOReturnSuccess) {
        AlwaysLog(toggleError, alwaysOnUSBPrompt, ret);
        return false;
    }
    return alwaysOnUSBState == state;
}

bool IdeaVPC::setYLogo(bool enable) {
    if (!wmig)
        return false;
    bool ok = wmig->setYLogoStatus(enable);
    bool actual = false;
    if (ok && wmig->getYLogoStatus(&actual)) {
        yLogoMode = actual;
        setProperty(yLogoPrompt, actual);
    } else {
        removeProperty(yLogoPrompt);
    }
    return ok;
}

bool IdeaVPC::setPortLighting(bool enable) {
    if (!wmig)
        return false;
    bool ok = wmig->setPortLightingStatus(enable);
    bool actual = false;
    if (ok && wmig->getPortLightingStatus(&actual)) {
        portLightingMode = actual;
        setProperty(portLightingPrompt, actual);
    } else {
        removeProperty(portLightingPrompt);
    }
    return ok;
}

bool IdeaVPC::toggleConservation() {
    if (!conservationMode && rapidChargeMode && !toggleRapidCharge())
        return false;
    UInt32 firmwareResult = 0;
    UInt32 command = conservationMode ? BMCMD0_CONSERVATION_OFF : BMCMD0_CONSERVATION_ON;
    auto schema = OSDynamicCast(OSNumber, getProperty("BatteryStateSchemaVersion"));
    if (schema && schema->unsigned32BitValue() >= 2) {
        if (schema->unsigned32BitValue() < 4 || !ec ||
            ec->evaluateInteger(conservationMode ? "RYCF" : "RYCO", &command) != kIOReturnSuccess)
            return false;
    }
    setProperty("BatteryCommand", command, 32);
    IOReturn ret = evaluateIntegerParam(setBatteryMode, &firmwareResult, command);
    setProperty("BatteryCommandResult", firmwareResult, 32);
    if (ret != kIOReturnSuccess || firmwareResult != 0) {
        AlwaysLog("SBMC firmware status=0x%x", firmwareResult);
        AlwaysLog(toggleError, conservationPrompt, ret);
        return false;
    }

    conservationMode = !conservationMode;
    DebugLog(toggleSuccess, conservationPrompt, (conservationMode ? BMCMD0_CONSERVATION_ON : BMCMD0_CONSERVATION_OFF), (conservationMode ? "on" : "off"));
    setProperty(conservationPrompt, conservationMode);

    updateBattery(false);
    notifyBattery();
    return true;
}

bool IdeaVPC::toggleRapidCharge() {
    if (!rapidChargeCap)
        return false;

    if (!rapidChargeMode && conservationMode && !toggleConservation())
        return false;
    UInt32 firmwareResult = 0;
    UInt32 command = rapidChargeMode ? BMCMD0_RAPIDCHARGE_OFF : BMCMD0_RAPIDCHARGE_ON;
    auto schema = OSDynamicCast(OSNumber, getProperty("BatteryStateSchemaVersion"));
    if (schema && schema->unsigned32BitValue() >= 2) {
        if (schema->unsigned32BitValue() < 4 || !ec ||
            ec->evaluateInteger(rapidChargeMode ? "RYRF" : "RYRO", &command) != kIOReturnSuccess)
            return false;
    }
    setProperty("BatteryCommand", command, 32);
    IOReturn ret = evaluateIntegerParam(setBatteryMode, &firmwareResult, command);
    setProperty("BatteryCommandResult", firmwareResult, 32);
    if (ret != kIOReturnSuccess || firmwareResult != 0) {
        AlwaysLog("SBMC firmware status=0x%x", firmwareResult);
        AlwaysLog(toggleError, rapidChargePrompt, ret);
        return false;
    }

    rapidChargeMode = !rapidChargeMode;
    DebugLog(toggleSuccess, rapidChargePrompt, (rapidChargeMode ? BMCMD0_RAPIDCHARGE_ON : BMCMD0_RAPIDCHARGE_OFF), (rapidChargeMode ? "on" : "off"));
    setProperty(rapidChargePrompt, rapidChargeMode);
    updateBattery(false);
    return true;
}

bool IdeaVPC::setBacklight(UInt32 level) {
    if (!backlightCap)
        return true;

    IOReturn ret = evaluateIntegerParam(setKeyboardMode, nullptr, level ? HACMD_BACKLIGHT_ON : HACMD_BACKLIGHT_OFF);
    if (ret != kIOReturnSuccess) {
        AlwaysLog(toggleError, backlightPrompt, ret);
        return false;
    }

    if (level && backlightLevel)
        // Preserve low / high level on non keyboard triggered events
        backlightLevel -= 1;
    // Don't update internal value since it will trigger another event
    DebugLog(toggleSuccess, backlightPrompt, (backlightLevel ? HACMD_BACKLIGHT_ON : HACMD_BACKLIGHT_OFF), (backlightLevel ? "on" : "off"));
    return true;
}

bool IdeaVPC::setFnLock(bool enable) {
    if (!FnlockCap)
        return true;

    IOReturn ret = evaluateIntegerParam(setKeyboardMode, nullptr, enable ? HACMD_FNLOCK_ON : HACMD_FNLOCK_OFF);
    if (ret != kIOReturnSuccess) {
        AlwaysLog(toggleError, FnKeyPrompt, ret);
        return false;
    }

    FnlockMode = enable;
    DebugLog(toggleSuccess, FnKeyPrompt, (FnlockMode ? HACMD_FNLOCK_ON : HACMD_FNLOCK_OFF), (FnlockMode ? "on" : "off"));
    setProperty(FnKeyPrompt, FnlockMode);

    if (client)
        client->sendNotification(0x11, FnlockMode);
    return true;
}

IOReturn IdeaVPC::setBridgeFan(UInt32 fan, UInt32 rpm) {
    UInt32 verified = 0;
    if (!legionBridge || legionBridgeVersion < 2 || !ec || ec->evaluateInteger("RYVW", &verified) != kIOReturnSuccess || verified != 1)
        return kIOReturnUnsupported;
    if (fan > 1)
        return kIOReturnBadArgument;
    OSObject *args[] = {OSNumber::withNumber(fan, 32), OSNumber::withNumber(rpm, 32)};
    if (!args[0] || !args[1]) {
        OSSafeReleaseNULL(args[0]);
        OSSafeReleaseNULL(args[1]);
        return kIOReturnNoMemory;
    }
    UInt32 result = 0;
    IOReturn ret = ec->evaluateInteger("RYFS", &result, args, 2);
    args[0]->release();
    args[1]->release();
    return ret == kIOReturnSuccess && result != 0 ? kIOReturnIOError : ret;
}

IOReturn IdeaVPC::setControl(const char *key, OSObject *value) {
    auto flags = OSDynamicCast(OSDictionary, getProperty("FeatureStatus"));
    auto feature = flags ? OSDynamicCast(OSDictionary, flags->getObject(key)) : nullptr;
    if (!feature || feature->getObject("Available") != kOSBooleanTrue)
        return kIOReturnUnsupported;
    auto number = OSDynamicCast(OSNumber, value);
    auto boolean = OSDynamicCast(OSBoolean, value);
    if (number == nullptr && boolean == nullptr)
        return kIOReturnBadArgument;
    if (number != nullptr && number->unsigned64BitValue() > 0xffffffffULL)
        return kIOReturnBadArgument;
    UInt32 target = number != nullptr ? number->unsigned32BitValue() : (boolean->getValue() ? 1 : 0);
    if (!strcmp(key, "CPUPowerReset")) {
        if (number == nullptr || target != 0)
            return kIOReturnBadArgument;
        return restorePowerLimits() ? kIOReturnSuccess : kIOReturnIOError;
    }
    if (!strcmp(key, "CPUBoostPower") || !strcmp(key, "CPUSustainedPower")) {
        if (number == nullptr || !wmig)
            return kIOReturnBadArgument;
        UInt32 currentProfile = 0;
        if (!wmig->getGameZoneData(GAME_ZONE_WMI_GET_SMARTFAN_MODE, &currentProfile))
            return kIOReturnIOError;
        if (powerLimitsSaved && currentProfile != powerLimitsProfile)
            return kIOReturnNotReady;
        unsigned index = !strcmp(key, "CPUSustainedPower") ? 1 : 0;
        UInt32 range[4] = {};
        if (!wmig->getPowerLimit(index == 0 ? 3 : 5, range))
            return kIOReturnIOError;
        if (!range[1] || range[2] > range[3] || target < range[2] || target > range[3] || (target - range[2]) % range[1])
            return kIOReturnBadArgument;
        if (!powerLimitsSaved) {
            UInt32 other[4] = {};
            if (!wmig->getPowerLimit(index == 0 ? 5 : 3, other))
                return kIOReturnIOError;
            if (!wmig->getGameZoneData(GAME_ZONE_WMI_GET_SMARTFAN_MODE, &powerLimitsProfile))
                return kIOReturnIOError;
            originalPowerLimits[index] = range[0];
            originalPowerLimits[1 - index] = other[0];
            powerLimitsSaved = true;
        }
        return wmig->setPowerLimit(index == 0 ? 4 : 6, target) ? kIOReturnSuccess : kIOReturnIOError;
    }
    if (!strcmp(key, "Fan1TargetRPM") || !strcmp(key, "Fan2TargetRPM")) {
        if (number == nullptr)
            return kIOReturnBadArgument;
        return setBridgeFan(!strcmp(key, "Fan2TargetRPM") ? 1 : 0, target);
    }
    if (!strcmp(key, "FanControlMode")) {
        UInt32 result = 0;
        if (target != 0)
            return kIOReturnBadArgument; // Manual is entered by a target-RPM request.
        if (ec && ec->validateObject("RYFA") == kIOReturnSuccess) {
            IOReturn ret = ec->evaluateInteger("RYFA", &result);
            return ret == kIOReturnSuccess && result != 0 ? kIOReturnIOError : ret;
        }
        return kIOReturnSuccess;
    }
    if (!strcmp(key, smartFanPrompt)) {
        if (number == nullptr || target < 1 || target > 3)
            return kIOReturnBadArgument;
        UInt32 currentProfile = 0;
        if (powerLimitsSaved && wmig && wmig->getGameZoneData(GAME_ZONE_WMI_GET_SMARTFAN_MODE, &currentProfile) && currentProfile != powerLimitsProfile) {
            if (target != powerLimitsProfile)
                return kIOReturnNotReady;
            if (!wmig->setGameZoneData(GAME_ZONE_WMI_SET_SMARTFAN_MODE, target))
                return kIOReturnIOError;
            setProperty(smartFanPrompt, target, 32);
            return restorePowerLimits() ? kIOReturnSuccess : kIOReturnIOError;
        }
        if (!restorePowerLimits())
            return kIOReturnIOError;
        auto currentFullFan = getProperty(fullFanPrompt);
        const bool keepFullFan = currentFullFan && currentFullFan == kOSBooleanTrue;
        if (!keepFullFan && legionBridge && ec && ec->validateObject("RYFA") == kIOReturnSuccess) {
            UInt32 result = 0;
            ec->evaluateInteger("RYFA", &result);
        }
        if (!wmig || !wmig->setGameZoneData(GAME_ZONE_WMI_SET_SMARTFAN_MODE, target))
            return kIOReturnIOError;
        if (keepFullFan && legionBridge && ec && ec->validateObject("RYFF") == kIOReturnSuccess) {
            auto argument = OSNumber::withNumber(1ULL, 32);
            if (argument) {
                OSObject *arguments[] = {argument};
                UInt32 ecResult = 0;
                ec->evaluateInteger("RYFF", &ecResult, arguments, 1);
                argument->release();
            }
        } else if (keepFullFan && wmig) {
            wmig->setFanFullSpeed(true);
        }
        setProperty(smartFanPrompt, target, 32);
        return kIOReturnSuccess;
    }
    if (!strcmp(key, alwaysOnUSBStatePrompt)) {
        if (number == nullptr || target > 2)
            return kIOReturnBadArgument;
        return setAlwaysOnUSBState(target) ? kIOReturnSuccess : kIOReturnIOError;
    }
    if (!strcmp(key, backlightPrompt)) {
        if (number == nullptr || target > 2)
            return kIOReturnBadArgument;
        return setUserBacklight(target) ? kIOReturnSuccess : kIOReturnIOError;
    }
    if (target > 1)
        return kIOReturnBadArgument;
    if (!strcmp(key, conservationPrompt)) {
        if (boolean == nullptr)
            return kIOReturnBadArgument;
        if (!updateBattery(false))
            return kIOReturnIOError;
        return target == conservationMode || toggleConservation() ? kIOReturnSuccess : kIOReturnIOError;
    }
    if (!strcmp(key, rapidChargePrompt)) {
        if (boolean == nullptr)
            return kIOReturnBadArgument;
        if (!updateBattery(false))
            return kIOReturnIOError;
        return target == rapidChargeMode || toggleRapidCharge() ? kIOReturnSuccess : kIOReturnIOError;
    }
    if (!strcmp(key, fullFanPrompt)) {
        if ((boolean == nullptr && number == nullptr) || target > 1)
            return kIOReturnBadArgument;
        removeProperty("FanFullSpeedECResult");
        if (legionBridge && ec && ec->validateObject("RYFF") == kIOReturnSuccess) {
            auto argument = OSNumber::withNumber(target, 32);
            if (argument == nullptr)
                return kIOReturnNoMemory;
            OSObject *arguments[] = {argument};
            UInt32 ecResult = 0;
            IOReturn status = ec->evaluateInteger("RYFF", &ecResult, arguments, 1);
            argument->release();
            setProperty("FanFullSpeedCommandBackend", "ACPI vendor command / return status");
            if (status != kIOReturnSuccess)
                return status;
            setProperty("FanFullSpeedECResult", ecResult, 32);
            if (ecResult == 0)
                setProperty(fullFanPrompt, target != 0);
            return ecResult == 0 ? kIOReturnSuccess : kIOReturnIOError;
        }
        UInt32 coolingCapability = 0;
        if (wmig && wmig->getGameZoneData(GAME_ZONE_WMI_CAP_FAN_COOLING, &coolingCapability) && coolingCapability == 0)
            return kIOReturnUnsupported;
        setProperty("FanFullSpeedCommandBackend", "WMI / firmware discards EC return status");
        bool res = wmig && wmig->setFanFullSpeed(target != 0);
        if (res) {
            setProperty(fullFanPrompt, target != 0);
            bool state = !target;
            if (wmig->getFanFullSpeed(&state) && state == (target != 0)) {
                setProperty("FanFullSpeedReadbackLatched", true);
            } else {
                setProperty("FanFullSpeedReadbackLatched", false);
            }
        }
        return res ? kIOReturnSuccess : kIOReturnIOError;
    }
    if (!strcmp(key, overDrivePrompt)) {
        if (number == nullptr || target > 1)
            return kIOReturnBadArgument;
        return wmig->setGameZoneData(GAME_ZONE_WMI_SET_OVER_DRIVE, target) ? kIOReturnSuccess : kIOReturnIOError;
    }
    if (!strcmp(key, winKeyPrompt)) {
        if (number == nullptr || target > 1)
            return kIOReturnBadArgument;
        return wmig->setGameZoneData(GAME_ZONE_WMI_SET_WIN_KEY, target) ? kIOReturnSuccess : kIOReturnIOError;
    }
    if (!strcmp(key, touchpadLockPrompt)) {
        if (number == nullptr || target > 1)
            return kIOReturnBadArgument;
        return wmig->setGameZoneData(GAME_ZONE_WMI_SET_TOUCHPAD, target) ? kIOReturnSuccess : kIOReturnIOError;
    }
    if (!strcmp(key, yLogoPrompt)) {
        if (boolean == nullptr || target > 1)
            return kIOReturnBadArgument;
        return setYLogo(target) ? kIOReturnSuccess : kIOReturnIOError;
    }
    if (!strcmp(key, portLightingPrompt)) {
        if (boolean == nullptr || target > 1)
            return kIOReturnBadArgument;
        return setPortLighting(target) ? kIOReturnSuccess : kIOReturnIOError;
    }
    if (!strcmp(key, FnKeyPrompt)) {
        if (boolean == nullptr || target > 1)
            return kIOReturnBadArgument;
        return setFnLock(target) ? kIOReturnSuccess : kIOReturnIOError;
    }
    return kIOReturnUnsupported;
}

void IdeaVPC::controlRequest(OSDictionary *request) {
    ReYogaControl::ControlEnvelope envelope;
    if (!ReYogaControl::parseControlEnvelope(request, envelope))
        return;
    auto key = envelope.property;
    auto id = envelope.requestID;
    auto value = envelope.value;
    updateFeatureStatus();
    IOReturn ret = setControl(key->getCStringNoCopy(), value);
    const IOReturn commandStatus = ret;
    if (ret == kIOReturnSuccess)
        updateAll();
    OSObject *actual = getProperty(key->getCStringNoCopy());
    auto result = ReYogaControl::makeControlResult(envelope, actual, commandStatus, ret);
    if (!result)
        return;
    const bool readbackPending = commandStatus == kIOReturnSuccess && ret == kIOReturnIOError;
    ReYogaProperty::setString(result, "Reason", ret == kIOReturnSuccess ? "Firmware readback matched" : ret == kIOReturnUnsupported ? "Feature unavailable; inspect FeatureStatus"
                                                                                                    : ret == kIOReturnBadArgument   ? "Invalid type or value"
                                                                                                    : readbackPending               ? "Firmware accepted the request but readback differs or is missing; export diagnostics with the requested and actual values"
                                                                                                                                    : "Firmware command failed");
    ReYogaProperty::setString(result, "Code", ret == kIOReturnSuccess ? "confirmed" : ret == kIOReturnUnsupported ? "unsupported"
                                                                                  : ret == kIOReturnBadArgument   ? "invalid_request"
                                                                                  : readbackPending               ? "readback_mismatch"
                                                                                                                  : "firmware_call_failed");
    ReYogaProperty::setString(result, "Stage", ret == kIOReturnSuccess || readbackPending ? "readback" : ret == kIOReturnUnsupported || ret == kIOReturnBadArgument ? "validation"
                                                                                                                                                                    : "firmware");
    if (!strcmp(key->getCStringNoCopy(), fullFanPrompt)) {
        if (auto backend = getProperty("FanFullSpeedCommandBackend"))
            result->setObject("Backend", backend);
        if (auto raw = getProperty("FanFullSpeedRaw"))
            result->setObject("FirmwareStateRaw", raw);
        if (auto capability = getProperty("FanCoolingCapability"))
            result->setObject("CoolingCapability", capability);
        if (readbackPending) {
            ReYogaProperty::setString(result, "Code", "fan_state_unchanged");
            ReYogaProperty::setString(result, "Reason", "The vendor command completed, but the firmware full-speed flag did not change. EC return 0 only means no command-port timeout; it does not confirm fan activation.");
            auto cap = OSDynamicCast(OSNumber, getProperty("FanCoolingCapability"));
            if (cap && cap->unsigned32BitValue() == 0) {
                ReYogaProperty::setString(result, "Code", "firmware_capability_absent");
                ReYogaProperty::setString(result, "Reason", "BIOS reports no fan-cooling capability (Game Zone 0x0C = 0); the EC ignored NCMD 0x59 and FCST stayed 0 after 1.5 s");
            }
        }
        if (auto ecStatus = OSDynamicCast(OSNumber, getProperty("FanFullSpeedECResult"))) {
            result->setObject("ECResult", ecStatus);
            if (ecStatus->unsigned32BitValue() != 0) {
                ReYogaProperty::setString(result, "Code", "ec_command_failed");
                ReYogaProperty::setString(result, "Stage", "ec_handshake");
                ReYogaProperty::setString(result, "Reason", "The vendor EC command returned an error; no full-speed state was confirmed");
            }
        }
    }
    if (!strcmp(key->getCStringNoCopy(), conservationPrompt) || !strcmp(key->getCStringNoCopy(), rapidChargePrompt)) {
        if (auto command = getProperty("BatteryCommand"))
            result->setObject("BatteryCommand", command);
        if (auto status = getProperty("BatteryCommandResult"))
            result->setObject("BatteryCommandResult", status);
        if (auto raw = getProperty("BatteryModeRaw"))
            result->setObject("BatteryModeRaw", raw);
    }
    if (ret == kIOReturnUnsupported) {
        auto flags = OSDynamicCast(OSDictionary, getProperty("FeatureStatus"));
        auto feature = flags ? OSDynamicCast(OSDictionary, flags->getObject(key->getCStringNoCopy())) : nullptr;
        if (feature && feature->getObject("Reason"))
            result->setObject("Reason", feature->getObject("Reason"));
    }
    if (!strcmp(key->getCStringNoCopy(), yLogoPrompt) || !strcmp(key->getCStringNoCopy(), portLightingPrompt)) {
        if (auto owner = OSDynamicCast(OSNumber, getProperty("LightingControlOwner"))) {
            result->setObject("LightingOwner", owner);
            if (commandStatus == kIOReturnSuccess && owner->unsigned32BitValue() != 1) {
                ret = kIOReturnIOError;
                ReYogaProperty::setNumber(result, "Status", ret, 32);
                ReYogaProperty::setString(result, "Code", "lighting_owner_mismatch");
                ReYogaProperty::setString(result, "Stage", "ownership_readback");
                ReYogaProperty::setString(result, "Reason", "Firmware did not retain software lighting ownership");
            }
        }
        if (wmig) {
            if (auto stage = wmig->getProperty("LightingCommandStage"))
                result->setObject("LightingStage", stage);
        }
    }
    setProperty("LastControlResult", result);
    result->release();
    AlwaysLog("control id=%s property=%s status=0x%x", id->getCStringNoCopy(), key->getCStringNoCopy(), ret);
}

bool IdeaVPC::restorePowerLimits() {
    if (!powerLimitsSaved)
        return true;
    if (!wmig)
        return false;
    UInt32 profile = 0;
    if (!wmig->getGameZoneData(GAME_ZONE_WMI_GET_SMARTFAN_MODE, &profile))
        return false;
    if (profile != powerLimitsProfile) {
        setProperty("CPUPowerRestoreReason", "Return to the modified power profile before restoring its saved limits");
        return false;
    }
    bool boost = wmig->setPowerLimit(4, originalPowerLimits[0]);
    bool sustained = wmig->setPowerLimit(6, originalPowerLimits[1]);
    UInt32 actualBoost[4] = {}, actualSustained[4] = {};
    bool confirmed = boost && sustained && wmig->getPowerLimit(3, actualBoost) && wmig->getPowerLimit(5, actualSustained) &&
                     actualBoost[0] == originalPowerLimits[0] && actualSustained[0] == originalPowerLimits[1];
    if (confirmed) {
        powerLimitsSaved = false;
        removeProperty("CPUPowerRestoreReason");
    } else
        AlwaysLog("CPU power-limit restoration failed boost=%d sustained=%d confirmed=%d", boost, sustained, confirmed);
    return confirmed;
}

void IdeaVPC::restoreUserControls() {
    if (safeMode || !commandGate)
        return;
    commandGate->runAction([](OSObject *owner, void *, void *, void *, void *) -> IOReturn {
        auto self = static_cast<IdeaVPC *>(owner);
        self->restorePowerLimits();
        if (self->legionBridge && self->ec && self->ec->validateObject("RYFA") == kIOReturnSuccess) {
            UInt32 result = 0;
            if (self->ec->evaluateInteger("RYFA", &result) != kIOReturnSuccess || result != 0)
                self->setProperty("FanRestoreReason", "Firmware did not confirm automatic fan restoration");
        }
        return kIOReturnSuccess;
    });
}
