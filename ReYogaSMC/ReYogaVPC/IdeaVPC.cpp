//  SPDX-License-Identifier: GPL-2.0-only
//
//  IdeaVPC.cpp
//  ReYogaSMC
//
//  Created by Zhen on 2020/7/11.
//  Copyright © 2020 Zhen. All rights reserved.
//

#include "IdeaVPC.hpp"
#include "ReYogaWMI.hpp"
#include "../ReYogaWMI/IdeaWMI.hpp"
OSDefineMetaClassAndStructors(IdeaVPC, ReYogaVPC);

void IdeaVPC::updateAll() {
    if (safeMode) return;
    updateBattery();
    updateKeyboard();
    updateVPC();
    if (wmig) {
        UInt32 val = 0;
        if (wmig->getGamzeZoneData(GAME_ZONE_WMI_GET_SMARTFAN_MODE, &val))
            setProperty(smartFanPrompt, val, 32);
        if (wmig->getGamzeZoneData(GAME_ZONE_WMI_GET_OVER_DRIVE, &val))
            setProperty(overDrivePrompt, val, 32);
        if (wmig->getGamzeZoneData(GAME_ZONE_WMI_GET_WIN_KEY, &val))
            setProperty(winKeyPrompt, val, 32);
        if (wmig->getGamzeZoneData(GAME_ZONE_WMI_GET_TOUCHPAD, &val))
            setProperty(touchpadLockPrompt, val, 32);
        updateTelemetry();
        if (wmig->hasLightingMethod) {
            bool en = false;
            if (wmig->getYLogoStatus(&en)) {
                yLogoMode = en;
                setProperty(yLogoPrompt, yLogoMode);
            }
            if (wmig->getPortLightingStatus(&en)) {
                portLightingMode = en;
                setProperty(portLightingPrompt, portLightingMode);
            }
        }
    }
    updateFeatureStatus();
    super::updateAll();
}

bool IdeaVPC::initVPC() {
    if (safeMode) {
        telemetryAwake = false;
        setProperty("SafeMode", kOSBooleanTrue);
        setProperty("SafeModeReason", "-reysafe: ACPI, EC and WMI hardware access disabled");
        AlwaysLog("Safe mode enabled; skipping ACPI/EC initialization");
        return true;
    }

    if (!initEC())
        return false;

    super::initVPC();

    UInt32 config;
    if (vpc->evaluateInteger(getVPCConfig, &config) != kIOReturnSuccess) {
        AlwaysLog(initFailure, getVPCConfig);
        return false;
    }

    DebugLog(updateSuccess, VPCPrompt, config);
    setProperty(VPCPrompt, config, 32);

    OSDictionary *capabilities = OSDictionary::withCapacity(6);
    OSString *value;

    setPropertyBoolean(capabilities, "Bluetooth", (config >> CFG_BT_BIT) & 0x1);
    setPropertyBoolean(capabilities, "3G", (config >> CFG_3G_BIT) & 0x1);
    setPropertyBoolean(capabilities, "Wireless", (config >> CFG_WIFI_BIT) & 0x1);
    setPropertyBoolean(capabilities, "Camera", (config >> CFG_CAMERA_BIT) & 0x1);
    setPropertyBoolean(capabilities, "Touchpad", (config >> CFG_TOUCHPAD_BIT) & 0x1);

    UInt8 cap_graphics = config >> CFG_GRAPHICS_3BIT & 0x7;
    switch (cap_graphics) {
        case 1:
            setPropertyString(capabilities, "Graphics", "Intel");
            break;

        case 2:
            setPropertyString(capabilities, "Graphics", "ATI");
            break;

        case 3:
            setPropertyString(capabilities, "Graphics", "Nvidia");
            break;

        case 4:
            setPropertyString(capabilities, "Graphics", "Intel and ATI");
            break;

        case 5:
            setPropertyString(capabilities, "Graphics", "Intel and Nvidia");
            break;

        default:
            char Unknown[10];
            snprintf(Unknown, 10, "Unknown:%1x", cap_graphics);
            setPropertyString(capabilities, "Graphics", Unknown);
            break;
    }
    setProperty("Capability", capabilities);
    capabilities->release();

    updateKeyboardCapability();
    updateBatteryCapability();

    isPowerChanged();

    int val[16];
    if (PE_parse_boot_argn("-ideabr", val, sizeof(val))) {
        brightnessPoller = IOTimerEventSource::timerEventSource(this, OSMemberFunctionCast(IOTimerEventSource::Action, this, &IdeaVPC::brightnessAction));
        if (!brightnessPoller ||
            workLoop->addEventSource(brightnessPoller) != kIOReturnSuccess) {
            AlwaysLog("Failed to add brightnessPoller");
            OSSafeReleaseNULL(brightnessPoller);
        } else {
            brightnessPoller->setTimeoutMS(BR_POLLING_INTERVAL);
            brightnessPoller->enable();
            AlwaysLog("BrightnessPoller enabled");
        }
    }
    return true;
}

void IdeaVPC::brightnessAction(OSObject *owner, IOTimerEventSource *timer) {
    updateVPC();
    if (brightnessPoller->setTimeoutMS(BR_POLLING_INTERVAL) != kIOReturnSuccess)
        AlwaysLog("Failed to set poller");
    else
        DebugLog("Poller set");
}

bool IdeaVPC::exitVPC() {
    telemetryAwake = false;
    restorePowerLimits();
    if (telemetryPoller) {
        telemetryPoller->cancelTimeout();
        telemetryPoller->disable();
        workLoop->removeEventSource(telemetryPoller);
        OSSafeReleaseNULL(telemetryPoller);
    }
    if (legionBridge) {
        UInt32 restored = 0;
        ec->evaluateInteger("RYFA", &restored);
    }
    if (brightnessPoller) {
        brightnessPoller->disable();
        workLoop->removeEventSource(brightnessPoller);
    }
    OSSafeReleaseNULL(brightnessPoller);
    return super::exitVPC();
}

IOReturn IdeaVPC::message(UInt32 type, IOService *provider, void *argument) {
    if (safeMode)
        return super::message(type, provider, argument);

    switch (type)
    {
        case kSMC_YogaEvent:
            {
                UInt32 mode = *(reinterpret_cast<UInt32 *>(argument));
                DebugLog("message: %s Yoga mode 0x%x", provider->getName(), mode);
                if (client)
                    client->sendNotification(0x10, mode); // Since vpc_bit is less than 16
                if (backlightCap && automaticBacklightMode & BIT(1)) {
                    updateKeyboard();
                    if (mode != 1) {
                        backlightLevelSaved = backlightLevel;
                        if (backlightLevel)
                            setBacklight(0);
                    } else {
                        if (backlightLevelSaved != backlightLevel)
                            setBacklight(backlightLevelSaved);
                    }
                }
            }
            break;

        case kSMC_FnlockEvent:
            DebugLog("message: %s Fnlock event", provider->getName());
            updateFnLock();
            setFnLock(!FnlockMode);
            break;

        case kSMC_getConservation:
            *(reinterpret_cast<bool *>(argument)) = conservationMode;
//            conservationModeLock = false;
            DebugLog("message: %s get conservation mode %d", provider->getName(), conservationMode);
            break;

        case kSMC_setConservation:
            AlwaysLog("message: %s set conservation mode %d -> %d", provider->getName(), conservationMode, *(reinterpret_cast<bool *>(argument)));
            if (*(reinterpret_cast<bool *>(argument)) != conservationMode &&
                !conservationModeLock)
                toggleConservation();
            break;

        case kIOACPIMessageDeviceNotification:
            if (argument && *(reinterpret_cast<UInt32 *>(argument)) == kIOACPIMessageReserved) {
                updateVPC();
                break;
            }

        default:
            return super::message(type, provider, argument);
    }

    return kIOReturnSuccess;
}

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

//    AlwaysLog("%d objects in properties", dict->getCount());
    OSCollectionIterator* i = OSCollectionIterator::withCollection(dict);

    if (i) {
        while (OSString* key = OSDynamicCast(OSString, i->getNextObject())) {
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
                OSBoolean *value;
                getPropertyBoolean(ECLockPrompt);
                if (value->getValue())
                    continue;
                
                ECLock = false;
                AlwaysLog("direct VPC EC manipulation is unlocked");
            } else if (key->isEqualTo(readECPrompt)) {
                if (ECLock)
                    continue;
                OSNumber *value;
                getPropertyNumber(readECPrompt);

                UInt32 result;
                UInt32 retries = 0;

                if (read_ec_data(value->unsigned32BitValue(), &result, &retries))
                    AlwaysLog("%s 0x%x result: 0x%x %d", readECPrompt, value->unsigned32BitValue(), result, retries);
                else
                    AlwaysLog("%s failed 0x%x %d", readECPrompt, value->unsigned32BitValue(), retries);
            } else if (key->isEqualTo(writeECPrompt)) {
                if (ECLock)
                    continue;
                OSNumber *value;
                getPropertyNumber(writeECPrompt);

                UInt32 command, data;
                UInt32 retries = 0;
                command = value->unsigned32BitValue() >> 8;
                data = value->unsigned32BitValue() & 0xff;

                if (write_ec_data(command, data, &retries))
                    AlwaysLog("%s 0x%x 0x%x success %d", writeECPrompt, command, data, retries);
                else
                    AlwaysLog("%s 0x%x 0x%x failed %d", writeECPrompt, command, data, retries);
            } else if (key->isEqualTo(batteryPrompt)) {
                OSBoolean *value;
                getPropertyBoolean(batteryPrompt);
                conservationModeLock = value->getValue();
            } else if (key->isEqualTo(updatePrompt)) {
                updateAll();
            } else if (key->isEqualTo(resetPrompt)) {
                updateKeyboardCapability();
                updateBatteryCapability();
            } else {
                OSDictionary *entry = OSDictionary::withCapacity(1);
                entry->setObject(key, dict->getObject(key));
                super::setPropertiesGated(entry);
                entry->release();
            }
        }
        i->release();
    }

    return;
}

bool IdeaVPC::initEC() {
    UInt32 state, attempts = 0;

    // _REG will write Arg1 to ECAV (or OKEC on old machines) to connect / disconnect the region
    if (ec->validateObject(getECStatus) == kIOReturnSuccess) {
        do {
            if (ec->evaluateInteger(getECStatus, &state) == kIOReturnSuccess && state != 0) {
                if (attempts != 0)
                    setProperty("EC Access Retries", attempts, 8);
                return true;
            }
            IOSleep(100);
        } while (++attempts < 5);
        AlwaysLog(updateFailure, getECStatus);
    }

    if (ec->validateObject(getECStatusLegacy) == kIOReturnSuccess) {
        do {
            if (ec->evaluateInteger(getECStatusLegacy, &state) == kIOReturnSuccess && state != 0) {
                if (attempts != 0)
                    setProperty("EC Access Retries", attempts, 8);
                return true;
            }
            IOSleep(100);
        } while (++attempts < 5);
        AlwaysLog(updateFailure, getECStatusLegacy);
    }

    // fallback to battery mode since some laptop don't have available keyboard mode
    do {
        if (vpc->evaluateInteger(getBatteryMode, &state) == kIOReturnSuccess) {
            setProperty("EC Access Retries", attempts, 8);
            return true;
        }
        IOSleep(100);
    } while (++attempts < 10);
    AlwaysLog(initFailure, getBatteryMode);
    return false;
}

void IdeaVPC::updateKeyboardCapability() {
    UInt32 kbdState;
    IOReturn ret;

    ret = vpc->evaluateInteger(getKeyboardMode, &kbdState);
    if (ret != kIOReturnSuccess) {
        AlwaysLog(toggleError, keyboardPrompt, ret);
        return;
    }

    backlightCap = BIT(HA_BACKLIGHT_CAP) & kbdState;
    if (!backlightCap)
        setProperty(backlightPrompt, "unsupported");
    else
        setProperty(autoBacklightPrompt, automaticBacklightMode, 8);

    FnlockCap = BIT(HA_FNLOCK_CAP) & kbdState;
    if (!FnlockCap)
        setProperty(FnKeyPrompt, "unsupported");

    if (BIT(HA_PRIMEKEY_BIT) & kbdState)
        setProperty("PrimeKeyType", "HotKey");
    else
        setProperty("PrimeKeyType", "FnKey");

    alwaysOnUSBCap = BIT(HA_AOUSB_CAP) & kbdState;
    if (!alwaysOnUSBCap)
        setProperty(alwaysOnUSBPrompt, "unsupported");
}

void IdeaVPC::updateBatteryCapability() {
    UInt32 batState;
    IOReturn ret;

    ret = vpc->evaluateInteger(getBatteryMode, &batState);
    if (ret != kIOReturnSuccess) {
        AlwaysLog(toggleError, batteryPrompt, ret);
        return;
    }

    rapidChargeCap = BIT(BM_RAPIDCHARGE_CAP) & batState;
    if (!rapidChargeCap)
        setProperty(rapidChargePrompt, "unsupported");

    OSDictionary *bat0 = OSDictionary::withCapacity(5);
    OSDictionary *bat1 = OSDictionary::withCapacity(5);
    if (!bat0 || !bat1) { OSSafeReleaseNULL(bat0); OSSafeReleaseNULL(bat1); return; }
    if (BIT(BM0_BATTERYBAD_BIT) & batState) {
        bat0->setObject("Critical", kOSBooleanTrue);
        setProperty("Battery", "Critical");
        AlwaysLog("Battery 0 critical!");
        conservationModeLock = true;
    }

    if (BIT(BM1_BATTERYBAD_BIT) & batState) {
        bat1->setObject("Critical", kOSBooleanTrue);
        setProperty("Battery", "Critical");
        AlwaysLog("Battery 1 critical!");
        conservationModeLock = true;
    }

    if (updateBatteryID(bat0, bat1) && updateBatteryInfo(bat0, bat1)) {
        if (bat0->getCount())
            setProperty("Battery 0", bat0);
        if (bat1->getCount())
            setProperty("Battery 1", bat1);
    }
    bat0->release();
    bat1->release();
}

UInt16 extractBatteryCycle(OSObject *raw) {
    UInt16 ret = 0xffff;
    OSNumber *number;
    OSData *data;

    if ((number = OSDynamicCast(OSNumber, raw)) != nullptr)
        ret = number->unsigned16BitValue();
    else if ((data = OSDynamicCast(OSData, raw)) != nullptr && data->getLength() >= sizeof(ret))
        memcpy(&ret, data->getBytesNoCopy(), sizeof(ret));

    return ret;
}

UInt64 extractBatteryID(OSObject *raw) {
    UInt64 ret = 0xffff;
    OSNumber *number;
    OSData *data;

    if ((number = OSDynamicCast(OSNumber, raw)) != nullptr)
        ret = number->unsigned64BitValue();
    else if ((data = OSDynamicCast(OSData, raw)) != nullptr && data->getLength() >= sizeof(ret))
        memcpy(&ret, data->getBytesNoCopy(), sizeof(ret));

    return ret;
}

bool IdeaVPC::updateBatteryID(OSDictionary *bat0, OSDictionary *bat1) {
    OSObject *result = nullptr;
    if (vpc->evaluateObject(getBatteryID, &result) != kIOReturnSuccess) {
        AlwaysLog(updateFailure, "Battery ID");
        return false;
    }
#ifdef DEBUG
    setProperty("raw battery ID", result);
#endif
    OSArray *data;
    data = OSDynamicCast(OSArray, result);
    if (!data) {
        AlwaysLog("Battery ID not OSArray");
        result->release();
        return false;
    }

    char batString[20];

    UInt16 cycle;
    cycle = extractBatteryCycle(data->getObject(0));
    if (cycle != 0xffff) {
        snprintf(batString, 5, "%d", cycle);
        setPropertyString(bat0, "Cycle count", batString);
        DebugLog("Battery 0 cycle count %d", cycle);
    } else {
        AlwaysLog("Battery 0 cycle not exist");
    }

    cycle = extractBatteryCycle(data->getObject(1));
    if (cycle != 0xffff) {
        snprintf(batString, 5, "%d", cycle);
        setPropertyString(bat1, "Cycle count", batString);
        DebugLog("Battery 1 cycle count %d", cycle);
    } else {
        DebugLog("Battery 1 cycle not exist");
    }

    UInt64 id;
    UInt16 *idPtr;
    id = extractBatteryID(data->getObject(2));
    if ((id & 0xffff) != 0xffff) {
        idPtr = reinterpret_cast<UInt16 *>(&id);
        snprintf(batString, 20, "%04x %04x %04x %04x", idPtr[0], idPtr[1], idPtr[2], idPtr[3]);
        setPropertyString(bat0, "ID", batString);
        DebugLog("Battery 0 ID %s", batString);
    } else {
        AlwaysLog("Battery 0 ID not exist");
    }

    id = extractBatteryID(data->getObject(3));
    if ((id & 0xffff) != 0xffff) {
        idPtr = reinterpret_cast<UInt16 *>(&id);
        snprintf(batString, 20, "%04x %04x %04x %04x", idPtr[0], idPtr[1], idPtr[2], idPtr[3]);
        setPropertyString(bat1, "ID", batString);
        DebugLog("Battery 1 ID %s", batString);
    } else {
        DebugLog("Battery 1 ID not exist");
    }

    data->release();
    return true;
}

OSData *IdeaVPC::extractBatteryInfo(UInt32 index) {
    OSData *data = nullptr;
    OSObject *result = nullptr;

    OSObject* params[1] = {
        OSNumber::withNumber(index, 32),
    };

    if (!params[0]) return nullptr;
    IOReturn ret = vpc->evaluateObject(getBatteryInfo, &result, params, 1);
    params[0]->release();

    if (ret == kIOReturnSuccess) {
        if ((data = OSDynamicCast(OSData, result)) != nullptr && data->getLength() >= 10 * sizeof(UInt16)) {
            UInt64 header = 0;
            memcpy(&header, data->getBytesNoCopy(), sizeof(header));
            if (header != 0) {
                data->retain();
            } else {
                data = nullptr;
                DebugLog("Battery Info %d is empty", index);
            }
        } else {
            data = nullptr;
            DebugLog("Battery Info %d invalid type or length", index);
        }
    } else {
        DebugLog(updateFailure, "Battery Info");
    }
    OSSafeReleaseNULL(result);
    return data;
}
bool IdeaVPC::updateBatteryInfo(OSDictionary *bat0, OSDictionary *bat1) {
    OSData *data;
    if (!(data = extractBatteryInfo(0)) && !(data = extractBatteryInfo(1)))
        return false;

#ifdef DEBUG
    setProperty("raw battery Info", data);
#endif
    const UInt16 * bdata = reinterpret_cast<const UInt16 *>(data->getBytesNoCopy());
    // B1TM
    if (bdata[7] != 0) {
        SInt16 celsius = bdata[7] - 2731;
        if (celsius < 0 || celsius > 600)
            AlwaysLog("Battery 0 temperature critical! %d", celsius);
        char temperature0[9];
        snprintf(temperature0, 9, "%d.%d℃", celsius / 10, celsius % 10);
        setPropertyString(bat0, "Temperature", temperature0);
        DebugLog("Battery 0 temperature %s", temperature0);
//        UInt16 fahrenheit = celsius * 9 / 5 + 320;
//        snprintf(temperature0, 9, "%d.%d℉", fahrenheit / 10, fahrenheit % 10);
//        setPropertyString(bat0, "Fahrenheit", temperature0);
    }
    // B1DT
    if (bdata[8] != 0) {
        char date0[11];
        snprintf(date0, 11, "%4d/%02d/%02d", (bdata[8] >> 9) + 1980, (bdata[8] >> 5) & 0x0f, bdata[8] & 0x1f);
        setPropertyString(bat0, "Manufacture date", date0);
        DebugLog("Battery 0 manufacture date %s", date0);
    }
    // B2DT
    if (bdata[9] != 0) {
        char date1[11];
        snprintf(date1, 11, "%4d/%02d/%02d", (bdata[9] >> 9) + 1980, (bdata[9] >> 5) & 0x0f, bdata[9] & 0x1f);
        setPropertyString(bat1, "Manufacture date", date1);
        DebugLog("Battery 1 manufacture date %s", date1);
    }
    data->release();
    return true;
}

bool IdeaVPC::updateBattery(bool update) {
    UInt32 state;

    if (vpc->evaluateInteger(getBatteryMode, &state) != kIOReturnSuccess) {
        AlwaysLog(updateFailure, batteryPrompt);
        return false;
    }

    if (update) {
        DebugLog(updateSuccess, batteryPrompt, state);
    }

    setProperty("BatteryModeRaw", state, 32);
    rapidChargeCap = (state & BIT(BM_RAPIDCHARGE_CAP)) != 0;

    UInt32 conservationMask = BIT(BM0_CONSERVATION_BIT), rapidMask = BIT(BM_RAPIDCHARGE_BIT);
    UInt32 mappedConservation = 0, mappedRapid = 0;
    const bool mapped = ec && ec->validateObject("RYCM") == kIOReturnSuccess && ec->validateObject("RYRM") == kIOReturnSuccess &&
        ec->evaluateInteger("RYCM", &mappedConservation) == kIOReturnSuccess &&
        ec->evaluateInteger("RYRM", &mappedRapid) == kIOReturnSuccess && mappedConservation && mappedRapid &&
        !(mappedConservation & (mappedConservation-1)) && !(mappedRapid & (mappedRapid-1)) && !(mappedConservation & mappedRapid);
    if (mapped) { conservationMask = mappedConservation; rapidMask = mappedRapid; }
    UInt32 commands[4] = {};
    const char *commandMethods[] = {"RYCO", "RYCF", "RYRO", "RYRF"};
    UInt32 mappingVersion = 0;
    bool mappedCommands = mapped && ec->validateObject("RYBV") == kIOReturnSuccess &&
        ec->evaluateInteger("RYBV", &mappingVersion) == kIOReturnSuccess && mappingVersion == 4;
    for (unsigned i = 0; i < 4 && mappedCommands; ++i) {
        mappedCommands = ec->validateObject(commandMethods[i]) == kIOReturnSuccess &&
            ec->evaluateInteger(commandMethods[i], &commands[i]) == kIOReturnSuccess &&
            commands[i] > 0 && commands[i] <= 0xFF;
        for (unsigned j = 0; j < i; ++j) if (commands[i] == commands[j]) mappedCommands = false;
    }
    UInt32 conservationCapMask = 0, rapidCapMask = 0;
    mappedCommands = mappedCommands && ec->validateObject("RYQC") == kIOReturnSuccess &&
        ec->validateObject("RYQR") == kIOReturnSuccess &&
        ec->evaluateInteger("RYQC", &conservationCapMask) == kIOReturnSuccess &&
        ec->evaluateInteger("RYQR", &rapidCapMask) == kIOReturnSuccess;
    if (mappedCommands) rapidChargeCap = !rapidCapMask || (state & rapidCapMask) != 0;
    const bool conservationCap = !mappedCommands || !conservationCapMask || (state & conservationCapMask) != 0;
    setProperty("ConservationCapability", conservationCap);
    setProperty("RapidChargeCapability", rapidChargeCap);
    setProperty("BatteryStateSchemaVersion", mappedCommands ? 4 : (mapped ? 2 : 1), 32);
    setProperty("ConservationStateMask", conservationMask, 32);
    setProperty("RapidChargeStateMask", rapidMask, 32);
    conservationMode = (conservationMask & state) != 0;
    setProperty(conservationPrompt, conservationMode);
    if (rapidChargeCap) {
        rapidChargeMode = (rapidMask & state) != 0;
        setProperty(rapidChargePrompt, rapidChargeMode);
    }

    return true;
}

bool IdeaVPC::updateKeyboard(bool update) {
    if (!FnlockCap && !backlightCap && !alwaysOnUSBCap)
        return true;

    UInt32 state;

    if (vpc->evaluateInteger(getKeyboardMode, &state) != kIOReturnSuccess) {
        AlwaysLog(updateFailure, keyboardPrompt);
        return false;
    }

    if (backlightCap) {
        // Preserve low / high level on non keyboard triggered events
        if (!update && backlightLevel)
            backlightLevel -= 1;
        // Inference from brightness cycle: 0 -> 1 -> 2 -> 0
        backlightLevel = (BIT(HA_BACKLIGHT_BIT) & state) ? (backlightLevel ? 2 : 1) : 0;
    }

    if (update) {
        DebugLog(updateSuccess, keyboardPrompt, state);
    }

    if (backlightCap)
        setProperty(backlightPrompt, backlightLevel, 32);
    if (FnlockCap) {
        FnlockMode = BIT(HA_FNLOCK_BIT) & state;
        setProperty(FnKeyPrompt, FnlockMode);
    }
    if (alwaysOnUSBCap) {
        alwaysOnUSBMode = (BIT(HA_AOUSB_BIT) & state) != 0;
        if (!alwaysOnUSBMode)
            alwaysOnUSBState = 0;
        else if (BIT(23) & state)
            alwaysOnUSBState = 2;
        else
            alwaysOnUSBState = 1;
        setProperty(alwaysOnUSBPrompt, alwaysOnUSBMode);
        setProperty(alwaysOnUSBStatePrompt, alwaysOnUSBState, 32);
    }

    return true;
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
    } else { removeProperty(yLogoPrompt); }
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
    } else { removeProperty(portLightingPrompt); }
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
            ec->evaluateInteger(conservationMode ? "RYCF" : "RYCO", &command) != kIOReturnSuccess) return false;
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
            ec->evaluateInteger(rapidChargeMode ? "RYRF" : "RYRO", &command) != kIOReturnSuccess) return false;
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

void IdeaVPC::updateVPC(UInt32 event) {
    UInt32 vpc1, vpc2, result;
    UInt32 retries = 0;

    if (!read_ec_data(VPCCMD_R_VPC1, &vpc1, &retries)) {
        AlwaysLog("Failed to read VPC1 after %d attempts", retries);
        return;
    }

    if (!read_ec_data(VPCCMD_R_VPC2, &vpc2, &retries)) {
        AlwaysLog("Failed to read VPC2 after %d attempts", retries);
    } else {
        vpc1 = (vpc2 << 8) | vpc1;
    }

    if (!vpc1) {
        if (!brightnessPoller)
            DebugLog("empty EC event: %d", retries);
        return;
    }

    if (!brightnessPoller)
        DebugLog("read VPC EC result: 0x%x %d", vpc1, retries);

    UInt64 time = 0;
    for (int vpc_bit = 0; vpc_bit < 16; vpc_bit++) {
        if (BIT(vpc_bit) & vpc1) {
            UInt32 data = 0;
            switch (vpc_bit) {
                case 0:
                    if (!read_ec_data(VPCCMD_R_SPECIAL_BUTTONS, &result, &retries)) {
                        AlwaysLog("Failed to read VPCCMD_R_SPECIAL_BUTTONS %d", retries);
                    } else {
                        switch (result) {
                            case 0x01:
                            case 0x40: // KEY_PROG4
                                DebugLog("Fn+Q cooling 0x%x", result);
                                break;

                            case 0x02: // KEY_PROG3
                                DebugLog("OneKey Theater");
                                break;

                            default:
                                AlwaysLog("Special button 0x%x", result);
                                break;
                        }
                        data = result;
                    }
                    time = 1;
                    break;

                case 1: // ENERGY_EVENT_GENERAL / ENERGY_EVENT_KEYBDLED_OLD
                    if (isPowerChanged()) {
                        DebugLog("AC %s", adapterConnected ? "connected" : "disconnected");
                        continue;
                    }
                    DebugLog("Fn+Space keyboard backlight old");
                    updateKeyboard(true);
                    data = backlightLevel;
                    if (isActive(&backlightStimulation))
                        data |= 0x10;
                    time = 1;
                    break;

                case 2:
                    if (!read_ec_data(VPCCMD_R_BL_POWER, &result, &retries))
                        AlwaysLog("Failed to read VPCCMD_R_BL_POWER %d", retries);
                    else
                        DebugLog("Open lid? 0x%x %s", result, result ? "on" : "off");
                    data = result;
                    // functional, TODO: turn off screen on demand
                    break;

                case 3: // long_pressed ? KEY_PROG2 : KEY_PROG1
                    if (!read_ec_data(VPCCMD_R_NOVO, &result, &retries)) {
                        AlwaysLog("Failed to read VPCCMD_R_NOVO %d", retries);
                    } else {
                        DebugLog("NOVO button 0x%x", result);
                        data = result;
                    }
                    time = 1;
                    break;

                case 4:
                    if (!brightnessPoller) 
                        continue;
                    if (!read_ec_data(VPCCMD_R_BL, &result, &retries)) {
                        AlwaysLog("Failed to read VPCCMD_R_BL %d", retries);
                    } else {
                        if (result == 0 || result < brightnessSaved) {
                            DebugLog("Brightness down? 0x%x -> 0x%x", brightnessSaved, result);
                            dispatchKeyEvent(ADB_BRIGHTNESS_DOWN, true, false);
                            dispatchKeyEvent(ADB_BRIGHTNESS_DOWN, false, false);
                        } else {
                            DebugLog("Brightness up? 0x%x -> 0x%x", brightnessSaved, result);
                            dispatchKeyEvent(ADB_BRIGHTNESS_UP, true, false);
                            dispatchKeyEvent(ADB_BRIGHTNESS_UP, false, false);
                        }
                        brightnessSaved = result;
                        data = result;
                    }
                    time = 1;
                    break;

                case 5:
                    if (!read_ec_data(VPCCMD_R_TOUCHPAD, &result, &retries))
                        AlwaysLog("Failed to read VPCCMD_R_TOUCHPAD %d", retries);
                    else
                        DebugLog("Fn+F6 touchpad 0x%x %s", result, result ? "on" : "off");
                    if (TouchPadEnabledHW == (result != 0)) {
                        DebugLog("Skip duplicate touchpad report");
                        continue;
                    }
                    TouchPadEnabledHW = (result != 0);
                    data = result;
                    time = 1;
                    break;

                case 6: // KEY_SWITCHVIDEOMODE
                    DebugLog("Fn+F10 mirror");
                    time = 1;
                    break;

                case 7:
                    DebugLog("Fn+F8 camera");
                    time = 1;
                    break;

                case 8: // ENERGY_EVENT_MIC
                    DebugLog("Fn+F4 mic");
                    time = 1;
                    break;

                case 9: // RFKILL
                    DebugLog("Fn rfkill");
                    time = 1;
                    break;

                case 10:
                    DebugLog("Touchpad on");
                    time = 1;
                    break;

                case 11: // KEY_F16
                    DebugLog("Fn F16");
                    time = 1;
                    break;

                case 12: // ENERGY_EVENT_KEYBDLED
                    DebugLog("Fn+Space keyboard backlight?");
                    updateKeyboard(true);
                    data = backlightLevel;
                    if (isActive(&backlightStimulation))
                        data |= 0x10;
                    time = 1;
                    break;

                case 13:
                    DebugLog("Fn+F7 airplane mode");
                    time = 1;
                    break;

                default:
                    AlwaysLog("Unknown VPC event %d", vpc_bit);
                    break;
            }

            if (client != nullptr)
                client->sendNotification(vpc_bit, data);
        }
    }

    if (time != 0) {
        clock_get_uptime(&time);
        dispatchMessage(kPS2M_notifyKeyTime, &time);
    }
}

// Write VCMD -> VCMD is cleared -> Read VDAT
bool IdeaVPC::read_ec_data(UInt32 cmd, UInt32 *result, UInt32 *retries) {
    if (!method_vpcw(1, cmd))
        return false;

    AbsoluteTime abstime, deadline, now_abs;
    nanoseconds_to_absolutetime(IDEAPAD_EC_TIMEOUT * 1000000ULL, &abstime);
    clock_get_uptime(&now_abs);

    for (clock_absolutetime_interval_to_deadline(abstime, &deadline);
         now_abs < deadline; ) {
        if (!method_vpcr(1, result))
            return false;
        if (*result == 0)
            return method_vpcr(0, result);
        *retries = *retries + 1;
        IODelay(250);
        clock_get_uptime(&now_abs);
    }

    AlwaysLog(timeoutPrompt, readECPrompt, cmd);
    return false;
}

// Write VDAT -> Write VCMD -> VDAT is cleared
bool IdeaVPC::write_ec_data(UInt32 cmd, UInt32 value, UInt32 *retries) {
    UInt32 result;

    if (!method_vpcw(0, value))
        return false;

    if (!method_vpcw(1, cmd))
        return false;

    AbsoluteTime abstime, deadline, now_abs;
    nanoseconds_to_absolutetime(IDEAPAD_EC_TIMEOUT * 1000000ULL, &abstime);
    clock_get_uptime(&now_abs);

    for (clock_absolutetime_interval_to_deadline(abstime, &deadline);
         now_abs < deadline; ) {
        if (!method_vpcr(1, &result))
            return false;
        if (result == 0)
            return true;
        *retries = *retries + 1;
        IODelay(250);
        clock_get_uptime(&now_abs);
    }

    AlwaysLog(timeoutPrompt, writeECPrompt, cmd);
    return false;
}

bool IdeaVPC::method_vpcr(UInt32 cmd, UInt32 *result) {
    return (evaluateIntegerParam(readVPCStatus, result, cmd) == kIOReturnSuccess);
}

bool IdeaVPC::method_vpcw(UInt32 cmd, UInt32 data) {
    UInt32 result; // should only return 0

    OSObject* params[2] = {
        OSNumber::withNumber(cmd, 32),
        OSNumber::withNumber(data, 32),
    };

    IOReturn ret = vpc->evaluateInteger(writeVPCStatus, &result, params, 2);
    params[0]->release();
    params[1]->release();

    return (ret == kIOReturnSuccess);
}

bool IdeaVPC::examineWMI(IOService *provider) {
    OSString *feature;
    if ((feature = OSDynamicCast(OSString, provider->getProperty("Feature"))) &&
        feature->isEqualTo("Game Zone")) {
        wmig = OSDynamicCast(IdeaWMIGameZone, provider);
        setProperty("Game Zone", provider);
        if (wmig) {
            UInt32 bridgeID = 0;
            legionBridge = ec->evaluateInteger("RYID", &bridgeID) == kIOReturnSuccess && (bridgeID == 0x52590101 || bridgeID == 0x52590102);
            legionBridgeVersion = legionBridge ? bridgeID & 0xff : 0;
            setProperty("ACPIBridgeVersion", legionBridgeVersion, 32);
            if (legionBridge) {
                OSObject *identity = nullptr;
                if (ec->evaluateObject("RYPN", &identity) == kIOReturnSuccess && OSDynamicCast(OSString, identity))
                    setProperty("HardwareProfile", identity);
                OSSafeReleaseNULL(identity);
                if (ec->evaluateObject("RYNM", &identity) == kIOReturnSuccess && OSDynamicCast(OSString, identity))
                    setProperty("HardwareProfileName", identity);
                OSSafeReleaseNULL(identity);
            }
            setProperty("ControlProtocolVersion", 1, 32);
            setProperty("TelemetryIntervalMS", telemetryIntervalMS, 32);
            setProperty("LenovoFanMethod", wmig->hasFanMethod);
            setProperty("LenovoLightingMethod", wmig->hasLightingMethod);
            OSObject *fans = provider->getProperty("Fan number");
            if (fans) setProperty("Fan number", fans);
            updateAll();
            if (!telemetryPoller) {
                telemetryPoller = IOTimerEventSource::timerEventSource(this, [](OSObject *owner, IOTimerEventSource *timer) {
                    auto self = OSDynamicCast(IdeaVPC, owner);
                    if (self && self->telemetryAwake) {
                        self->updateTelemetry();
                        timer->setTimeoutMS(self->telemetryIntervalMS);
                    }
                });
                if (telemetryPoller && workLoop->addEventSource(telemetryPoller) == kIOReturnSuccess) {
                    telemetryPoller->enable();
                    telemetryPoller->setTimeoutMS(telemetryIntervalMS);
                } else
                    OSSafeReleaseNULL(telemetryPoller);
            }
        }
    }
    return true;
}

IOService* IdeaVPC::initWMI(WMI *instance) {
    return ReYogaWMI::withIdeaWMI(instance);
};

bool IdeaVPC::isPowerChanged() {
    bool ret = false;
    UInt32 powerState = adapterConnected;

    if (ec->validateObject("RPWR") == kIOReturnSuccess &&
        ec->evaluateInteger("RPWR", &powerState) == kIOReturnSuccess)
        ret = (powerState != adapterConnected);

    adapterConnected = powerState;
    return ret;
}

// Control protocol v1: each request receives a correlated result; transport success
// is never interpreted as firmware success. Existing property names remain an ABI.
void IdeaVPC::updateFeatureStatus() {
    auto features = OSDictionary::withCapacity(16);
    if (!features) return;
    auto add = [&](const char *key, bool available, const char *reason, const char *backend) {
        auto entry = OSDictionary::withCapacity(4);
        if (!entry) return;
        entry->setObject("Available", available ? kOSBooleanTrue : kOSBooleanFalse);
        setPropertyString(entry, "Reason", reason);
        setPropertyString(entry, "Backend", backend);
        features->setObject(key, entry);
        entry->release();
    };
    const bool battery = vpc->validateObject(getBatteryMode) == kIOReturnSuccess &&
                         vpc->validateObject(setBatteryMode) == kIOReturnSuccess;
    auto schema = OSDynamicCast(OSNumber, getProperty("BatteryStateSchemaVersion"));
    const bool mappingReady = schema == nullptr || schema->unsigned32BitValue() != 2;
    const bool conservationCap = getProperty("ConservationCapability") != kOSBooleanFalse;
    add(conservationPrompt, battery && mappingReady && conservationCap,
        !mappingReady ? "Battery setter mapping requires the updated SSDT" : !conservationCap ? "Firmware conservation capability is clear" : battery ? "" : "ACPI GBMD/SBMC missing", "ACPI");
    add(rapidChargePrompt, battery && mappingReady && rapidChargeCap,
        !mappingReady ? "Battery setter mapping requires the updated SSDT" : rapidChargeCap ? "" : "Battery charge-mode capability is clear in GBMD", "ACPI");
    add(alwaysOnUSBStatePrompt, alwaysOnUSBCap, alwaysOnUSBCap ? "" : "HALS Always-On USB capability is clear", "ACPI");
    add(FnKeyPrompt, FnlockCap, FnlockCap ? "" : "HALS Fn Lock capability is clear", "ACPI");
    add(backlightPrompt, backlightCap, backlightCap ? "" : "ACPI backlight unavailable; RGB may use USB HID", "ACPI");
    UInt32 cap = 0, actual = 0;
    auto wmi = [&](const char *key, UInt32 capability, UInt32 getter) {
        cap = actual = 0;
        const bool capabilityRead = wmig && wmig->getGamzeZoneData(capability, &cap);
        const bool ok = capabilityRead && cap && wmig->getGamzeZoneData(getter, &actual);
        const char *reason = !wmig ? "WMI Game Zone provider unavailable" :
            !capabilityRead ? "WMI capability query failed; inspect the kernel WMI status" :
            !cap ? "Firmware reports this capability unavailable" :
            !ok ? "WMI state getter failed; inspect the kernel WMI status" : "";
        add(key, ok, reason, "WMI Game Zone");
        if (ok) setProperty(key, actual, 32);
        else removeProperty(key);
    };
    wmi(smartFanPrompt, GAME_ZONE_WMI_CAP_SMARTFAN, GAME_ZONE_WMI_GET_SMARTFAN_MODE);
    wmi(overDrivePrompt, GAME_ZONE_WMI_CAP_OVER_DRIVE, GAME_ZONE_WMI_GET_OVER_DRIVE);
    wmi(winKeyPrompt, GAME_ZONE_WMI_CAP_WIN_KEY, GAME_ZONE_WMI_GET_WIN_KEY);
    wmi(touchpadLockPrompt, GAME_ZONE_WMI_CAP_TOUCHPAD, GAME_ZONE_WMI_GET_TOUCHPAD);
    bool state = false;
    UInt32 coolingCapability = 0;
    if (wmig && wmig->getGamzeZoneData(GAME_ZONE_WMI_CAP_FAN_COOLING, &coolingCapability))
        setProperty("FanCoolingCapability", coolingCapability, 32);
    else removeProperty("FanCoolingCapability");
    bool ok = wmig && wmig->getFanFullSpeed(&state);
    add(fullFanPrompt, ok, ok ? "" : "Fan full-speed getter failed or interface missing", "WMI Fan");
    if (ok) setProperty(fullFanPrompt, state);
    else removeProperty(fullFanPrompt);
    UInt32 lightingOwner = 0;
    if (legionBridge && ec && ec->validateObject("RYLO") == kIOReturnSuccess &&
        ec->evaluateInteger("RYLO", &lightingOwner) == kIOReturnSuccess)
        setProperty("LightingControlOwner", lightingOwner, 32);
    else removeProperty("LightingControlOwner");
    auto lightReason = [&](const char *key) -> const char * {
        auto text = wmig ? OSDynamicCast(OSString, wmig->getProperty(key)) : nullptr;
        return text ? text->getCStringNoCopy() : "WMI lighting provider unavailable";
    };
    ok = wmig && wmig->getYLogoStatus(&state);
    add(yLogoPrompt, ok, ok ? "" : lightReason("LogoLightingReason"), "WMI Lighting");
    if (ok) setProperty(yLogoPrompt, state);
    else removeProperty(yLogoPrompt);
    ok = wmig && wmig->getPortLightingStatus(&state);
    add(portLightingPrompt, ok, ok ? "" : lightReason("PortLightingReason"), "WMI Lighting");
    if (ok) setProperty(portLightingPrompt, state);
    else removeProperty(portLightingPrompt);
    UInt32 verifiedWrites = 0;
    const bool fanWrites = legionBridgeVersion >= 2 &&
        ec->evaluateInteger("RYVW", &verifiedWrites) == kIOReturnSuccess && verifiedWrites == 1;
    setProperty("FanWritesValidated", fanWrites);
    add("FanControlMode", legionBridgeVersion >= 2, legionBridgeVersion >= 2 ? "" : "Install the reviewed ACPI bridge v2 for fan control; v1 lacks EC curve recomputation", "ACPI profile");
    add("Fan1TargetRPM", fanWrites, fanWrites ? "" : "Fan writes disabled: this bridge has no hardware-validated write profile", "ACPI profile");
    add("Fan2TargetRPM", fanWrites, fanWrites ? "" : "Fan writes disabled: this bridge has no hardware-validated write profile", "ACPI profile");
    const char *rawKeys[] = {"YLogoRawState", "YLogoRawBrightness", "PortLightingRawState", "PortLightingRawBrightness", "FanFullSpeedRaw", "LogoLightingCapability", "PortLightingCapability", "LightingCommandStage"};
    for (const char *raw : rawKeys) {
        auto value = wmig ? wmig->getProperty(raw) : nullptr;
        if (value) setProperty(raw, value);
        else removeProperty(raw);
    }
    auto ranges = OSDictionary::withCapacity(2);
    const char *powerKeys[] = {"CPUBoostPower", "CPUSustainedPower"};
    for (unsigned i = 0; i < 2; ++i) {
        UInt32 range[4] = {};
        bool supported = wmig && wmig->getPowerLimit(i == 0 ? 3 : 5, range);
        add(powerKeys[i], supported, supported ? "" : "CPU WMI power-limit range unavailable", "WMI CPU");
        if (supported && ranges) {
            auto item = OSDictionary::withCapacity(3);
            if (item) {
                setPropertyNumber(item, "Step", range[1], 32);
                setPropertyNumber(item, "Min", range[2], 32);
                setPropertyNumber(item, "Max", range[3], 32);
                ranges->setObject(powerKeys[i], item);
                item->release();
            }
            setProperty(powerKeys[i], range[0], 32);
        } else removeProperty(powerKeys[i]);
    }
    UInt32 resetRange[4] = {};
    const bool resetAvailable = wmig && wmig->getPowerLimit(3, resetRange) && wmig->getPowerLimit(5, resetRange);
    add("CPUPowerReset", resetAvailable, resetAvailable ? "" : "CPU profile reset interface unavailable", "WMI CPU");
    setProperty("CPUPowerModified", powerLimitsSaved);
    setProperty("CPUPowerReset", static_cast<UInt64>(0), 32);
    add("GPUPowerLimit", false, "Requires an active supported graphics driver; firmware NPF notifications alone do not apply the limit", "Graphics driver required");
    add("GPUOverclock", false, "No verified macOS graphics overclock backend is available for this firmware", "Graphics driver required");
    add("HybridGraphics", false, "Graphics topology changes require compatible graphics drivers and a reboot; not exposed as a live toggle", "Boot configuration");
    add("CPUOverclock", false, "No verified overclock interface for this CPU/firmware", "Unavailable");
    if (ranges) { setProperty("PowerLimitRanges", ranges); ranges->release(); }
    setProperty("FeatureStatus", features);
    features->release();
}

void IdeaVPC::updateTelemetry() {
    if (!wmig || !telemetryAwake) return;
    auto status = OSDictionary::withCapacity(4);
    const char *keys[] = {"Fan1RPM", "Fan2RPM", cpuTempPrompt, gpuTempPrompt};
    const char *methods[] = {"RYF0", "RYF1", "RYT0", "RYT1"};
    for (unsigned i = 0; i < 4; ++i) {
        UInt32 value = 0;
        bool ok = false;
        if (legionBridge) ok = ec->evaluateInteger(methods[i], &value) == kIOReturnSuccess;
        else if (i < 2) ok = wmig->hasFanMethod ? wmig->getFanSpeed(i, &value) :
            wmig->getGamzeZoneData(i == 0 ? GAME_ZONE_WMI_GET_FAN_ONE : GAME_ZONE_WMI_GET_FAN_TWO, &value);
        else ok = i == 2 ? wmig->getCPUTemperature(&value) : wmig->getGPUTemperature(&value);
        if (i >= 2 && (value == 0 || value >= 125)) ok = false;
        if (i < 2 && (value == 0xFFFFFFFF || value == 0xFFFF)) ok = false;
        if (ok) setProperty(keys[i], value, 32);
        else removeProperty(keys[i]);
        if (status) setPropertyString(status, keys[i], ok ? "ok" :
            (i >= 2 && value == 0 ? "firmware returned zero; sensor may be powered off" : "ACPI/WMI read failed or value invalid"));
    }
    if (status) { setProperty("SensorStatus", status); status->release(); }
    setProperty("TelemetrySource", legionBridge ? "ACPI profile / precise EC RPM" : "WMI / firmware RPM resolution");
    if (legionBridge) {
        UInt32 value = 0;
        if (ec->evaluateInteger("RYFM", &value) == kIOReturnSuccess) setProperty("FanControlMode", value, 32);
        if (ec->evaluateInteger("RYG0", &value) == kIOReturnSuccess) setProperty("Fan1TargetRPM", value, 32);
        if (ec->evaluateInteger("RYG1", &value) == kIOReturnSuccess) setProperty("Fan2TargetRPM", value, 32);
        if (ec->evaluateInteger("RYM0", &value) == kIOReturnSuccess) setProperty("Fan1MaxRPM", value, 32);
        if (ec->evaluateInteger("RYM1", &value) == kIOReturnSuccess) setProperty("Fan2MaxRPM", value, 32);
    }
    UInt32 profile = 0;
    if (wmig->getGamzeZoneData(GAME_ZONE_WMI_GET_SMARTFAN_MODE, &profile) && profile >= 1 && profile <= 3) {
        if (powerLimitsSaved && profile != powerLimitsProfile) powerLimitsSaved = false;
        setProperty(smartFanPrompt, profile, 32);
    }
    setProperty("CPUPowerModified", powerLimitsSaved);
    if (sampleSequence % 4 == 0) {
        bool oldCapability = rapidChargeCap;
        updateBattery(false);
        updateKeyboard(false);
        if (oldCapability != rapidChargeCap) updateFeatureStatus();
    }
    UInt64 uptime = 0, ns = 0;
    clock_get_uptime(&uptime);
    absolutetime_to_nanoseconds(uptime, &ns);
    setProperty("SensorSampleTimeMS", ns / 1000000, 64);
    setProperty("SensorSampleSequence", ++sampleSequence, 64);
    if (detailedTelemetry || sampleSequence == 1 || sampleSequence % 20 == 0)
        DebugLog("sample=%llu source=%s timeMS=%llu", sampleSequence,
                 legionBridge ? "ACPI-profile" : "WMI", ns / 1000000);
}

IOReturn IdeaVPC::setBridgeFan(UInt32 fan, UInt32 rpm) {
    UInt32 verified = 0;
    if (!ec || ec->evaluateInteger("RYVW", &verified) != kIOReturnSuccess || verified != 1)
        return kIOReturnUnsupported;
    if (fan > 1) return kIOReturnBadArgument;
    OSObject *args[] = {OSNumber::withNumber(fan, 32), OSNumber::withNumber(rpm, 32)};
    if (!args[0] || !args[1]) { OSSafeReleaseNULL(args[0]); OSSafeReleaseNULL(args[1]); return kIOReturnNoMemory; }
    UInt32 result = 0;
    IOReturn ret = ec->evaluateInteger("RYFS", &result, args, 2);
    args[0]->release(); args[1]->release();
    return ret == kIOReturnSuccess && result != 0 ? kIOReturnIOError : ret;
}

IOReturn IdeaVPC::setControl(const char *key, OSObject *value) {
    auto flags = OSDynamicCast(OSDictionary, getProperty("FeatureStatus"));
    auto feature = flags ? OSDynamicCast(OSDictionary, flags->getObject(key)) : nullptr;
    if (!feature || feature->getObject("Available") != kOSBooleanTrue) return kIOReturnUnsupported;
    auto number = OSDynamicCast(OSNumber, value);
    auto boolean = OSDynamicCast(OSBoolean, value);
    if (number == nullptr && boolean == nullptr) return kIOReturnBadArgument;
    if (number != nullptr && number->unsigned64BitValue() > 0xffffffffULL) return kIOReturnBadArgument;
    UInt32 target = number != nullptr ? number->unsigned32BitValue() : (boolean->getValue() ? 1 : 0);
    if (!strcmp(key, "CPUPowerReset")) {
        if (number == nullptr || target != 0) return kIOReturnBadArgument;
        return restorePowerLimits() ? kIOReturnSuccess : kIOReturnIOError;
    }
    if (!strcmp(key, "CPUBoostPower") || !strcmp(key, "CPUSustainedPower")) {
        if (number == nullptr || !wmig) return kIOReturnBadArgument;
        unsigned index = !strcmp(key, "CPUSustainedPower") ? 1 : 0;
        UInt32 range[4] = {};
        if (!wmig->getPowerLimit(index == 0 ? 3 : 5, range)) return kIOReturnIOError;
        if (!range[1] || range[2] > range[3] || target < range[2] || target > range[3] || (target - range[2]) % range[1]) return kIOReturnBadArgument;
        if (!powerLimitsSaved) {
            UInt32 other[4] = {};
            if (!wmig->getPowerLimit(index == 0 ? 5 : 3, other)) return kIOReturnIOError;
            if (!wmig->getGamzeZoneData(GAME_ZONE_WMI_GET_SMARTFAN_MODE, &powerLimitsProfile)) return kIOReturnIOError;
            originalPowerLimits[index] = range[0]; originalPowerLimits[1 - index] = other[0];
            powerLimitsSaved = true;
        }
        return wmig->setPowerLimit(index == 0 ? 4 : 6, target) ? kIOReturnSuccess : kIOReturnIOError;
    }
    if (!strcmp(key, "Fan1TargetRPM") || !strcmp(key, "Fan2TargetRPM")) {
        if (number == nullptr) return kIOReturnBadArgument;
        return setBridgeFan(!strcmp(key, "Fan2TargetRPM") ? 1 : 0, target);
    }
    if (!strcmp(key, "FanControlMode")) {
        UInt32 result = 0;
        if (target != 0) return kIOReturnBadArgument; // Manual is entered by a target-RPM request.
        IOReturn ret = ec->evaluateInteger("RYFA", &result);
        return ret == kIOReturnSuccess && result != 0 ? kIOReturnIOError : ret;
    }
    if (!strcmp(key, smartFanPrompt)) {
        if (number == nullptr || target < 1 || target > 3) return kIOReturnBadArgument;
        restorePowerLimits();
        if (legionBridge) { UInt32 result; ec->evaluateInteger("RYFA", &result); }
        return wmig->setGameZoneData(GAME_ZONE_WMI_SET_SMARTFAN_MODE, target) ? kIOReturnSuccess : kIOReturnIOError;
    }
    if (!strcmp(key, alwaysOnUSBStatePrompt)) {
        if (number == nullptr || target > 2) return kIOReturnBadArgument;
        return setAlwaysOnUSBState(target) ? kIOReturnSuccess : kIOReturnIOError;
    }
    if (!strcmp(key, backlightPrompt)) {
        if (number == nullptr || target > 2) return kIOReturnBadArgument;
        return setBacklight(target) ? kIOReturnSuccess : kIOReturnIOError;
    }
    if (target > 1) return kIOReturnBadArgument;
    if (!strcmp(key, conservationPrompt)) {
        if (boolean == nullptr) return kIOReturnBadArgument;
        if (!updateBattery(false)) return kIOReturnIOError;
        return target == conservationMode || toggleConservation() ? kIOReturnSuccess : kIOReturnIOError;
    }
    if (!strcmp(key, rapidChargePrompt)) {
        if (boolean == nullptr) return kIOReturnBadArgument;
        if (!updateBattery(false)) return kIOReturnIOError;
        return target == rapidChargeMode || toggleRapidCharge() ? kIOReturnSuccess : kIOReturnIOError;
    }
    if (!strcmp(key, fullFanPrompt)) {
        if (boolean == nullptr || target > 1) return kIOReturnBadArgument;
        removeProperty("FanFullSpeedECResult");
        if (legionBridge && ec && ec->validateObject("RYFF") == kIOReturnSuccess) {
            auto argument = OSNumber::withNumber(target, 32);
            if (argument == nullptr) return kIOReturnNoMemory;
            OSObject *arguments[] = {argument};
            UInt32 ecResult = 0;
            IOReturn status = ec->evaluateInteger("RYFF", &ecResult, arguments, 1);
            argument->release();
            setProperty("FanFullSpeedCommandBackend", "ACPI vendor command / return status");
            if (status != kIOReturnSuccess) return status;
            setProperty("FanFullSpeedECResult", ecResult, 32);
            return ecResult == 0 ? kIOReturnSuccess : kIOReturnIOError;
        }
        setProperty("FanFullSpeedCommandBackend", "WMI / firmware discards EC return status");
        return wmig->setFanFullSpeed(target) ? kIOReturnSuccess : kIOReturnIOError;
    }
    if (!strcmp(key, overDrivePrompt)) {
        if (number == nullptr || target > 1) return kIOReturnBadArgument;
        return wmig->setGameZoneData(GAME_ZONE_WMI_SET_OVER_DRIVE, target) ? kIOReturnSuccess : kIOReturnIOError;
    }
    if (!strcmp(key, winKeyPrompt)) {
        if (number == nullptr || target > 1) return kIOReturnBadArgument;
        return wmig->setGameZoneData(GAME_ZONE_WMI_SET_WIN_KEY, target) ? kIOReturnSuccess : kIOReturnIOError;
    }
    if (!strcmp(key, touchpadLockPrompt)) {
        if (number == nullptr || target > 1) return kIOReturnBadArgument;
        return wmig->setGameZoneData(GAME_ZONE_WMI_SET_TOUCHPAD, target) ? kIOReturnSuccess : kIOReturnIOError;
    }
    if (!strcmp(key, yLogoPrompt)) {
        if (boolean == nullptr || target > 1) return kIOReturnBadArgument;
        return setYLogo(target) ? kIOReturnSuccess : kIOReturnIOError;
    }
    if (!strcmp(key, portLightingPrompt)) {
        if (boolean == nullptr || target > 1) return kIOReturnBadArgument;
        return setPortLighting(target) ? kIOReturnSuccess : kIOReturnIOError;
    }
    if (!strcmp(key, FnKeyPrompt)) {
        if (boolean == nullptr || target > 1) return kIOReturnBadArgument;
        return setFnLock(target) ? kIOReturnSuccess : kIOReturnIOError;
    }
    return kIOReturnUnsupported;
}

void IdeaVPC::controlRequest(OSDictionary *request) {
    auto key = OSDynamicCast(OSString, request->getObject("Property"));
    auto id = OSDynamicCast(OSString, request->getObject("RequestID"));
    OSObject *value = request->getObject("Value");
    if (!key || !id || !value || key->getLength() > 64 || id->getLength() > 64) return;
    updateFeatureStatus();
    IOReturn ret = setControl(key->getCStringNoCopy(), value);
    const IOReturn commandStatus = ret;
    if (ret == kIOReturnSuccess) updateAll();
    OSObject *actual = getProperty(key->getCStringNoCopy());
    if (ret == kIOReturnSuccess && (!actual || !actual->isEqualTo(value))) ret = kIOReturnIOError;
    const bool readbackPending = commandStatus == kIOReturnSuccess && ret == kIOReturnIOError;
    auto result = OSDictionary::withCapacity(12);
    if (!result) return;
    result->setObject("RequestID", id);
    result->setObject("Property", key);
    result->setObject("Requested", value);
    if (actual) result->setObject("Actual", actual);
    setPropertyNumber(result, "Status", ret, 32);
    setPropertyNumber(result, "CommandStatus", commandStatus, 32);
    result->setObject("ReadbackPending", readbackPending ? kOSBooleanTrue : kOSBooleanFalse);
    setPropertyString(result, "Reason", ret == kIOReturnSuccess ? "Firmware readback matched" :
        ret == kIOReturnUnsupported ? "Feature unavailable; inspect FeatureStatus" :
        ret == kIOReturnBadArgument ? "Invalid type or value" : readbackPending ? "Firmware accepted the request but readback differs or is missing; export diagnostics with the requested and actual values" : "Firmware command failed");
    setPropertyString(result, "Code", ret == kIOReturnSuccess ? "confirmed" :
        ret == kIOReturnUnsupported ? "unsupported" : ret == kIOReturnBadArgument ? "invalid_request" :
        readbackPending ? "readback_mismatch" : "firmware_call_failed");
    setPropertyString(result, "Stage", ret == kIOReturnSuccess || readbackPending ? "readback" :
        ret == kIOReturnUnsupported || ret == kIOReturnBadArgument ? "validation" : "firmware");
    if (!strcmp(key->getCStringNoCopy(), fullFanPrompt)) {
        if (auto backend = getProperty("FanFullSpeedCommandBackend")) result->setObject("Backend", backend);
        if (auto raw = getProperty("FanFullSpeedRaw")) result->setObject("FirmwareStateRaw", raw);
        if (auto capability = getProperty("FanCoolingCapability")) result->setObject("CoolingCapability", capability);
        if (readbackPending) {
            setPropertyString(result, "Code", "fan_state_unchanged");
            setPropertyString(result, "Reason", "The vendor command completed, but the firmware full-speed flag did not change. EC return 0 only means no command-port timeout; it does not confirm fan activation.");
        }
        if (auto ecStatus = OSDynamicCast(OSNumber, getProperty("FanFullSpeedECResult"))) {
            result->setObject("ECResult", ecStatus);
            if (ecStatus->unsigned32BitValue() != 0) {
                setPropertyString(result, "Code", "ec_command_failed");
                setPropertyString(result, "Stage", "ec_handshake");
                setPropertyString(result, "Reason", "The vendor EC command returned an error; no full-speed state was confirmed");
            }
        }
    }
    if (!strcmp(key->getCStringNoCopy(), conservationPrompt) || !strcmp(key->getCStringNoCopy(), rapidChargePrompt)) {
        if (auto command = getProperty("BatteryCommand")) result->setObject("BatteryCommand", command);
        if (auto status = getProperty("BatteryCommandResult")) result->setObject("BatteryCommandResult", status);
        if (auto raw = getProperty("BatteryModeRaw")) result->setObject("BatteryModeRaw", raw);
    }
    if (ret == kIOReturnUnsupported) {
        auto flags = OSDynamicCast(OSDictionary, getProperty("FeatureStatus"));
        auto feature = flags ? OSDynamicCast(OSDictionary, flags->getObject(key->getCStringNoCopy())) : nullptr;
        if (feature && feature->getObject("Reason")) result->setObject("Reason", feature->getObject("Reason"));
    }
    if (!strcmp(key->getCStringNoCopy(), yLogoPrompt) || !strcmp(key->getCStringNoCopy(), portLightingPrompt)) {
        if (auto owner = OSDynamicCast(OSNumber, getProperty("LightingControlOwner"))) {
            result->setObject("LightingOwner", owner);
            if (commandStatus == kIOReturnSuccess && owner->unsigned32BitValue() != 1) {
                ret = kIOReturnIOError;
                setPropertyNumber(result, "Status", ret, 32);
                setPropertyString(result, "Code", "lighting_owner_mismatch");
                setPropertyString(result, "Stage", "ownership_readback");
                setPropertyString(result, "Reason", "Firmware did not retain software lighting ownership");
            }
        }
        if (wmig) {
            if (auto stage = wmig->getProperty("LightingCommandStage")) result->setObject("LightingStage", stage);
        }
    }
    setProperty("LastControlResult", result);
    result->release();
    AlwaysLog("control id=%s property=%s status=0x%x", id->getCStringNoCopy(), key->getCStringNoCopy(), ret);
}

IOReturn IdeaVPC::setPowerState(unsigned long state, IOService *device) {
    if (!commandGate) return kIOPMAckImplied;
    return commandGate->runAction([](OSObject *owner, void *ordinal, void *device, void *, void *) -> IOReturn {
        return static_cast<IdeaVPC *>(owner)->setPowerStateGated(*static_cast<unsigned long *>(ordinal), static_cast<IOService *>(device));
    }, &state, device);
}

IOReturn IdeaVPC::setPowerStateGated(unsigned long state, IOService *device) {
    if (state == 0) {
        telemetryAwake = false;
        restorePowerLimits();
        if (telemetryPoller) telemetryPoller->cancelTimeout();
        if (legionBridge) { UInt32 result = 0; ec->evaluateInteger("RYFA", &result); }
    }
    IOReturn ret = super::setPowerState(state, device);
    if (state != 0) {
        telemetryAwake = true;
        if (telemetryPoller) telemetryPoller->setTimeoutMS(telemetryIntervalMS);
    }
    return ret;
}

bool IdeaVPC::restorePowerLimits() {
    if (!powerLimitsSaved) return true;
    if (!wmig) return false;
    UInt32 profile = 0;
    if (!wmig->getGamzeZoneData(GAME_ZONE_WMI_GET_SMARTFAN_MODE, &profile)) return false;
    if (profile != powerLimitsProfile) { powerLimitsSaved = false; return true; }
    bool boost = wmig->setPowerLimit(4, originalPowerLimits[0]);
    bool sustained = wmig->setPowerLimit(6, originalPowerLimits[1]);
    UInt32 actualBoost[4] = {}, actualSustained[4] = {};
    bool confirmed = boost && sustained && wmig->getPowerLimit(3, actualBoost) && wmig->getPowerLimit(5, actualSustained) &&
                     actualBoost[0] == originalPowerLimits[0] && actualSustained[0] == originalPowerLimits[1];
    if (confirmed) powerLimitsSaved = false;
    else AlwaysLog("CPU power-limit restoration failed boost=%d sustained=%d confirmed=%d", boost, sustained, confirmed);
    return confirmed;
}
