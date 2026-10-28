// SPDX-License-Identifier: GPL-2.0-only
// Original work: Copyright (c) 2020 Zhen.

#include "IdeaVPC.hpp"
#include "SensorDescriptors.hpp"
#include "../WMI/IdeaWMI.hpp"

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
        ReYogaProperty::setString(bat0, "Cycle count", batString);
        DebugLog("Battery 0 cycle count %d", cycle);
    } else {
        AlwaysLog("Battery 0 cycle not exist");
    }

    cycle = extractBatteryCycle(data->getObject(1));
    if (cycle != 0xffff) {
        snprintf(batString, 5, "%d", cycle);
        ReYogaProperty::setString(bat1, "Cycle count", batString);
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
        ReYogaProperty::setString(bat0, "ID", batString);
        DebugLog("Battery 0 ID %s", batString);
    } else {
        AlwaysLog("Battery 0 ID not exist");
    }

    id = extractBatteryID(data->getObject(3));
    if ((id & 0xffff) != 0xffff) {
        idPtr = reinterpret_cast<UInt16 *>(&id);
        snprintf(batString, 20, "%04x %04x %04x %04x", idPtr[0], idPtr[1], idPtr[2], idPtr[3]);
        ReYogaProperty::setString(bat1, "ID", batString);
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

    OSObject *params[1] = {
        OSNumber::withNumber(index, 32),
    };

    if (!params[0])
        return nullptr;
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
    const UInt16 *bdata = reinterpret_cast<const UInt16 *>(data->getBytesNoCopy());
    // B1TM
    if (bdata[7] != 0) {
        SInt16 celsius = bdata[7] - 2731;
        if (celsius < 0 || celsius > 600)
            AlwaysLog("Battery 0 temperature critical! %d", celsius);
        char temperature0[9];
        snprintf(temperature0, 9, "%d.%d℃", celsius / 10, celsius % 10);
        ReYogaProperty::setString(bat0, "Temperature", temperature0);
        DebugLog("Battery 0 temperature %s", temperature0);
    }
    // B1DT
    if (bdata[8] != 0) {
        char date0[11];
        snprintf(date0, 11, "%4d/%02d/%02d", (bdata[8] >> 9) + 1980, (bdata[8] >> 5) & 0x0f, bdata[8] & 0x1f);
        ReYogaProperty::setString(bat0, "Manufacture date", date0);
        DebugLog("Battery 0 manufacture date %s", date0);
    }
    // B2DT
    if (bdata[9] != 0) {
        char date1[11];
        snprintf(date1, 11, "%4d/%02d/%02d", (bdata[9] >> 9) + 1980, (bdata[9] >> 5) & 0x0f, bdata[9] & 0x1f);
        ReYogaProperty::setString(bat1, "Manufacture date", date1);
        DebugLog("Battery 1 manufacture date %s", date1);
    }
    data->release();
    return true;
}

bool IdeaVPC::updateBattery(bool logChanges) {
    UInt32 state;

    if (vpc->evaluateInteger(getBatteryMode, &state) != kIOReturnSuccess) {
        AlwaysLog(updateFailure, batteryPrompt);
        rapidChargeCap = false;
        removeProperty("BatteryModeRaw");
        removeProperty(conservationPrompt);
        removeProperty(rapidChargePrompt);
        return false;
    }

    if (logChanges) {
        DebugLog(updateSuccess, batteryPrompt, state);
    }

    setProperty("BatteryModeRaw", state, 32);
    rapidChargeCap = (state & BIT(BM_RAPIDCHARGE_CAP)) != 0;

    UInt32 conservationMask = BIT(BM0_CONSERVATION_BIT), rapidMask = BIT(BM_RAPIDCHARGE_BIT);
    UInt32 mappedConservation = 0, mappedRapid = 0;
    const bool mapped = legionBridge && ec && ec->validateObject("RYCM") == kIOReturnSuccess && ec->validateObject("RYRM") == kIOReturnSuccess &&
                        ec->evaluateInteger("RYCM", &mappedConservation) == kIOReturnSuccess &&
                        ec->evaluateInteger("RYRM", &mappedRapid) == kIOReturnSuccess && mappedConservation && mappedRapid &&
                        !(mappedConservation & (mappedConservation - 1)) && !(mappedRapid & (mappedRapid - 1)) && !(mappedConservation & mappedRapid);
    if (mapped) {
        conservationMask = mappedConservation;
        rapidMask = mappedRapid;
    }
    UInt32 commands[4] = {};
    const char *commandMethods[] = {"RYCO", "RYCF", "RYRO", "RYRF"};
    UInt32 mappingVersion = 0;
    bool mappedCommands = mapped && ec->validateObject("RYBV") == kIOReturnSuccess &&
                          ec->evaluateInteger("RYBV", &mappingVersion) == kIOReturnSuccess && mappingVersion == 4;
    for (unsigned i = 0; i < 4 && mappedCommands; ++i) {
        mappedCommands = ec->validateObject(commandMethods[i]) == kIOReturnSuccess &&
                         ec->evaluateInteger(commandMethods[i], &commands[i]) == kIOReturnSuccess &&
                         commands[i] > 0 && commands[i] <= 0xFF;
        for (unsigned j = 0; j < i; ++j)
            if (commands[i] == commands[j])
                mappedCommands = false;
    }
    UInt32 conservationCapMask = 0, rapidCapMask = 0;
    mappedCommands = mappedCommands && ec->validateObject("RYQC") == kIOReturnSuccess &&
                     ec->validateObject("RYQR") == kIOReturnSuccess &&
                     ec->evaluateInteger("RYQC", &conservationCapMask) == kIOReturnSuccess &&
                     ec->evaluateInteger("RYQR", &rapidCapMask) == kIOReturnSuccess;
    if (mappedCommands)
        rapidChargeCap = !rapidCapMask || (state & rapidCapMask) != 0;
    const bool conservationCap = !mappedCommands || !conservationCapMask || (state & conservationCapMask) != 0;
    setProperty("ConservationCapability", conservationCap);
    setProperty("RapidChargeCapability", rapidChargeCap);
    setProperty("BatteryStateSchemaVersion", mappedCommands ? 4 : (mapped ? 2 : 1), 32);
    setProperty("ConservationStateMask", conservationMask, 32);
    setProperty("RapidChargeStateMask", rapidMask, 32);
    conservationMode = (conservationMask & state) != 0;
    setProperty(conservationPrompt, conservationMode);
    rapidChargeMode = rapidChargeCap && (rapidMask & state) != 0;
    if (rapidChargeCap)
        setProperty(rapidChargePrompt, rapidChargeMode);
    else
        removeProperty(rapidChargePrompt);

    return true;
}

bool IdeaVPC::updateKeyboard(bool fromKeyboardEvent) {
    if (!FnlockCap && !backlightCap && !alwaysOnUSBCap)
        return true;

    UInt32 state;

    if (vpc->evaluateInteger(getKeyboardMode, &state) != kIOReturnSuccess) {
        AlwaysLog(updateFailure, keyboardPrompt);
        removeProperty(backlightPrompt);
        removeProperty(FnKeyPrompt);
        removeProperty(alwaysOnUSBStatePrompt);
        return false;
    }

    if (backlightCap) {
        // Preserve low / high level on non keyboard triggered events
        if (!fromKeyboardEvent && backlightLevel)
            backlightLevel -= 1;
        // Inference from brightness cycle: 0 -> 1 -> 2 -> 0
        backlightLevel = (BIT(HA_BACKLIGHT_BIT) & state) ? (backlightLevel ? 2 : 1) : 0;
    }

    if (fromKeyboardEvent) {
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

bool IdeaVPC::isPowerChanged() {
    bool ret = false;
    UInt32 powerState = adapterConnected;

    if (ec->validateObject("RPWR") == kIOReturnSuccess &&
        ec->evaluateInteger("RPWR", &powerState) == kIOReturnSuccess)
        ret = (powerState != adapterConnected);

    adapterConnected = powerState;
    return ret;
}

void IdeaVPC::updateFeatureStatus() {
    auto features = OSDictionary::withCapacity(16);
    if (!features)
        return;
    auto add = [&](const char *key, bool available, const char *reason, const char *backend) {
        auto entry = OSDictionary::withCapacity(4);
        if (!entry)
            return;
        entry->setObject("Available", available ? kOSBooleanTrue : kOSBooleanFalse);
        ReYogaProperty::setString(entry, "Reason", reason);
        ReYogaProperty::setString(entry, "Backend", backend);
        features->setObject(key, entry);
        entry->release();
    };
    const bool battery = getProperty("BatteryModeRaw") && vpc->validateObject(getBatteryMode) == kIOReturnSuccess &&
                         vpc->validateObject(setBatteryMode) == kIOReturnSuccess;
    auto schema = OSDynamicCast(OSNumber, getProperty("BatteryStateSchemaVersion"));
    const bool mappingReady = schema == nullptr || schema->unsigned32BitValue() != 2;
    const bool conservationCap = getProperty("ConservationCapability") != kOSBooleanFalse;
    const bool keyboardSetter = vpc->validateObject(setKeyboardMode) == kIOReturnSuccess;
    add(conservationPrompt, battery && mappingReady && conservationCap,
        !mappingReady ? "Battery setter mapping requires the updated SSDT" : !conservationCap ? "Firmware conservation capability is clear"
                                                                         : battery            ? ""
                                                                                              : "ACPI GBMD/SBMC missing",
        "ACPI");
    add(rapidChargePrompt, battery && mappingReady && rapidChargeCap,
        !mappingReady ? "Battery setter mapping requires the updated SSDT" : rapidChargeCap ? ""
                                                                                            : "Battery charge-mode capability is clear in GBMD",
        "ACPI");
    add(alwaysOnUSBStatePrompt, alwaysOnUSBCap && keyboardSetter && getProperty(alwaysOnUSBStatePrompt), alwaysOnUSBCap ? "" : "HALS Always-On USB capability is clear", "ACPI");
    add(FnKeyPrompt, FnlockCap && keyboardSetter && getProperty(FnKeyPrompt), FnlockCap ? "" : "HALS Fn Lock capability is clear", "ACPI");
    add(backlightPrompt, backlightCap && keyboardSetter && getProperty(backlightPrompt), backlightCap ? "" : "ACPI backlight unavailable; RGB may use USB HID", "ACPI");
    UInt32 cap = 0, actual = 0;
    auto wmi = [&](const char *key, UInt32 capability, UInt32 getter) {
        cap = actual = 0;
        const bool capabilityRead = wmig && wmig->getGameZoneData(capability, &cap);
        const bool ok = capabilityRead && cap && wmig->getGameZoneData(getter, &actual);
        const char *reason = !wmig ? "WMI Game Zone provider unavailable" : !capabilityRead ? "WMI capability query failed; inspect the kernel WMI status"
                                                                        : !cap              ? "Firmware reports this capability unavailable"
                                                                        : !ok               ? "WMI state getter failed; inspect the kernel WMI status"
                                                                                            : "";
        add(key, ok, reason, "WMI Game Zone");
        if (ok)
            setProperty(key, actual, 32);
        else
            removeProperty(key);
    };
    wmi(smartFanPrompt, GAME_ZONE_WMI_CAP_SMARTFAN, GAME_ZONE_WMI_GET_SMARTFAN_MODE);
    wmi(overDrivePrompt, GAME_ZONE_WMI_CAP_OVER_DRIVE, GAME_ZONE_WMI_GET_OVER_DRIVE);
    wmi(winKeyPrompt, GAME_ZONE_WMI_CAP_WIN_KEY, GAME_ZONE_WMI_GET_WIN_KEY);
    wmi(touchpadLockPrompt, GAME_ZONE_WMI_CAP_TOUCHPAD, GAME_ZONE_WMI_GET_TOUCHPAD);
    bool state = false;
    UInt32 coolingCapability = 0;
    const bool coolingCapabilityRead = wmig && wmig->getGameZoneData(GAME_ZONE_WMI_CAP_FAN_COOLING, &coolingCapability);
    if (coolingCapabilityRead)
        setProperty("FanCoolingCapability", coolingCapability, 32);
    else
        removeProperty("FanCoolingCapability");
    bool ok = wmig && wmig->getFanFullSpeed(&state);
    const bool coolingSupported = coolingCapabilityRead && coolingCapability != 0;
    add(fullFanPrompt, ok && coolingSupported,
        !coolingSupported ? "Firmware does not advertise fan cooling control" : ok ? ""
                                                                                   : "Fan full-speed getter failed or interface missing",
        "WMI Fan");
    if (ok)
        setProperty(fullFanPrompt, state);
    else
        removeProperty(fullFanPrompt);
    UInt32 lightingOwner = 0;
    if (legionBridge && ec && ec->validateObject("RYLO") == kIOReturnSuccess &&
        ec->evaluateInteger("RYLO", &lightingOwner) == kIOReturnSuccess)
        setProperty("LightingControlOwner", lightingOwner, 32);
    else
        removeProperty("LightingControlOwner");
    auto lightReason = [&](const char *key) -> const char * {
        auto text = wmig ? OSDynamicCast(OSString, wmig->getProperty(key)) : nullptr;
        return text ? text->getCStringNoCopy() : "WMI lighting provider unavailable";
    };
    ok = wmig && wmig->getYLogoStatus(&state);
    add(yLogoPrompt, ok, ok ? "" : lightReason("LogoLightingReason"), "WMI Lighting");
    if (ok)
        setProperty(yLogoPrompt, state);
    else
        removeProperty(yLogoPrompt);
    ok = wmig && wmig->getPortLightingStatus(&state);
    add(portLightingPrompt, ok, ok ? "" : lightReason("PortLightingReason"), "WMI Lighting");
    if (ok)
        setProperty(portLightingPrompt, state);
    else
        removeProperty(portLightingPrompt);
    UInt32 verifiedWrites = 0;
    const bool fanWrites = legionBridgeVersion >= 2 &&
                           ec->evaluateInteger("RYVW", &verifiedWrites) == kIOReturnSuccess && verifiedWrites == 1;
    setProperty("FanWritesValidated", fanWrites);
    add("FanControlMode", legionBridgeVersion >= 2, legionBridgeVersion >= 2 ? "" : "The active driver has no validated manual fan control for this firmware", "ACPI profile");
    add("Fan1TargetRPM", fanWrites, fanWrites ? "" : "Manual fan minimums have not been validated for this firmware", "ACPI profile");
    add("Fan2TargetRPM", fanWrites, fanWrites ? "" : "Manual fan minimums have not been validated for this firmware", "ACPI profile");
    const char *stepKeys[] = {"Fan1TargetRPMStep", "Fan2TargetRPMStep"};
    for (unsigned fan = 0; fan < 2; ++fan) {
        if (legionBridge && nativeProfile)
            setProperty(stepKeys[fan], nativeProfile->scales[fan], 32);
        else
            removeProperty(stepKeys[fan]);
    }
    const char *rawKeys[] = {"YLogoRawState", "YLogoRawBrightness", "PortLightingRawState", "PortLightingRawBrightness", "FanFullSpeedRaw", "LogoLightingCapability", "PortLightingCapability", "LightingCommandStage"};
    for (const char *raw : rawKeys) {
        auto value = wmig ? wmig->getProperty(raw) : nullptr;
        if (value)
            setProperty(raw, value);
        else
            removeProperty(raw);
    }
    auto ranges = OSDictionary::withCapacity(2);
    bool powerSupported[2] = {false, false};
    const bool powerAccess = wmig && wmig->cpuPowerAccessEnabled;
    setProperty("CPUPowerAccessEnabled", powerAccess);
    const char *powerKeys[] = {"CPUBoostPower", "CPUSustainedPower"};
    auto activePowerProfile = OSDynamicCast(OSNumber, getProperty(smartFanPrompt));
    const bool powerProfileMatches = !powerLimitsSaved ||
                                     (activePowerProfile != nullptr && activePowerProfile->unsigned32BitValue() == powerLimitsProfile);
    for (unsigned i = 0; i < 2; ++i) {
        UInt32 range[4] = {};
        bool supported = powerAccess && wmig->getPowerLimit(i == 0 ? 3 : 5, range);
        powerSupported[i] = supported;
        add(powerKeys[i], supported && powerProfileMatches, !powerProfileMatches ? "Return to the modified power profile and reset its limits before making further edits" : supported  ? ""
                                                                                                                                                                         : !powerAccess ? "CPU power access is opt-in (-reycpupower): firmware getters may write SystemMemory"
                                                                                                                                                                                        : "CPU WMI power-limit range unavailable",
            "WMI CPU");
        if (supported && ranges) {
            auto item = OSDictionary::withCapacity(3);
            if (item) {
                ReYogaProperty::setNumber(item, "Step", range[1], 32);
                ReYogaProperty::setNumber(item, "Min", range[2], 32);
                ReYogaProperty::setNumber(item, "Max", range[3], 32);
                ranges->setObject(powerKeys[i], item);
                item->release();
            }
            setProperty(powerKeys[i], range[0], 32);
        } else
            removeProperty(powerKeys[i]);
    }

    const bool resetAvailable = powerSupported[0] && powerSupported[1] && powerProfileMatches;
    add("CPUPowerReset", resetAvailable, !powerProfileMatches ? "Return to the modified power profile before resetting its limits" : resetAvailable ? ""
                                                                                                                                 : !powerAccess     ? "CPU power access is opt-in (-reycpupower)"
                                                                                                                                                    : "CPU profile reset interface unavailable",
        "WMI CPU");
    setProperty("CPUPowerModified", powerLimitsSaved);
    if (powerLimitsSaved)
        setProperty("CPUPowerPendingProfile", powerLimitsProfile, 32);
    else
        removeProperty("CPUPowerPendingProfile");
    setProperty("CPUPowerReset", static_cast<UInt64>(0), 32);
    add("GPUPowerLimit", false, "Requires an active supported graphics driver; firmware NPF notifications alone do not apply the limit", "Graphics driver required");
    add("GPUOverclock", false, "No verified macOS graphics overclock backend is available for this firmware", "Graphics driver required");
    add("HybridGraphics", false, "Graphics topology changes require compatible graphics drivers and a reboot; not exposed as a live toggle", "Boot configuration");
    add("CPUOverclock", false, "No verified overclock interface for this CPU/firmware", "Unavailable");
    if (ranges) {
        setProperty("PowerLimitRanges", ranges);
        ranges->release();
    }
    setProperty("FeatureStatus", features);
    features->release();
}

void IdeaVPC::updateTelemetry() {
    if (!telemetryAwake)
        return;
    const bool trace = firmwareTrace && sampleSequence < 4;
    if (trace)
        AlwaysLog("Firmware begin: telemetry source=%s", legionBridge ? "ACPI bridge" : nativeProfile ? "Native ACPI"
                                                                                                      : "WMI");
    auto status = OSDictionary::withCapacity(4);
    auto sources = OSDictionary::withCapacity(4);
    static_assert(sizeof(nativeProfile->fields) / sizeof(nativeProfile->fields[0]) == ReYogaSensor::Count,
                  "Sensor descriptors must match the generated profile schema");
    for (unsigned i = ReYogaSensor::Fan1; i < ReYogaSensor::Count; ++i) {
        const auto &sensor = ReYogaSensor::descriptors[i];
        UInt32 value = 0;
        bool ok = false;
        if (sensor.isFan && wmig && wmig->fanCount > 0 && i >= wmig->fanCount) {
            removeProperty(sensor.property);
            if (status)
                ReYogaProperty::setString(status, sensor.property, "not reported by the firmware fan count");
            if (sources)
                ReYogaProperty::setString(sources, sensor.property, "Unavailable");
            continue;
        }
        if (legionBridge)
            ok = ec->evaluateInteger(sensor.bridgeMethod, &value) == kIOReturnSuccess;
        else if (nativeProfile) {
            ok = ec->evaluateInteger(nativeProfile->fields[i], &value) == kIOReturnSuccess;
            if (ok)
                ok = ReYogaFirmware::validSample(i, value, nativeProfile->scales[i], value);
        }
        const char *source = legionBridge ? "ACPI bridge" : nativeProfile ? "Native ACPI"
                                                                          : "WMI";
        auto valid = [&sensor](UInt32 sample) { return sensor.isFan ? sample < 0xFFFF : sample > 0 && sample < 125; };
        ok = ok && valid(value);
        if (!ok && wmig) {
            source = "WMI";
            if (sensor.isFan)
                ok = wmig->hasFanMethod ? wmig->getFanSpeed(i, &value) : wmig->getGameZoneData(i == ReYogaSensor::Fan1 ? GAME_ZONE_WMI_GET_FAN_ONE : GAME_ZONE_WMI_GET_FAN_TWO, &value);
            else
                ok = i == ReYogaSensor::CPU ? wmig->getCPUTemperature(&value) : wmig->getGPUTemperature(&value);
            ok = ok && valid(value);
        }
        if (sources)
            ReYogaProperty::setString(sources, sensor.property, ok ? source : "Unavailable");
        if (ok)
            setProperty(sensor.property, value, 32);
        else
            removeProperty(sensor.property);
        if (status)
            ReYogaProperty::setString(status, sensor.property, ok ? "ok" : (!sensor.isFan && value == 0 ? "firmware returned zero; sensor may be powered off" : "ACPI/WMI read failed or value invalid"));
    }
    if (status) {
        setProperty("SensorStatus", status);
        status->release();
    }
    if (sources) {
        setProperty("SensorSources", sources);
        sources->release();
    }
    setProperty("TelemetrySource", legionBridge ? "ACPI bridge / precise EC RPM" : nativeProfile ? "Native ACPI / reviewed field units"
                                                                                                 : "WMI / firmware RPM resolution");
    if (legionBridge) {
        UInt32 value = 0;
        if (ec->evaluateInteger("RYFM", &value) == kIOReturnSuccess)
            setProperty("FanControlMode", value, 32);
        else
            removeProperty("FanControlMode");
        if (ec->evaluateInteger("RYG0", &value) == kIOReturnSuccess && value < 0xFFFF)
            setProperty("Fan1TargetRPM", value, 32);
        else
            removeProperty("Fan1TargetRPM");
        if (ec->evaluateInteger("RYG1", &value) == kIOReturnSuccess && value < 0xFFFF)
            setProperty("Fan2TargetRPM", value, 32);
        else
            removeProperty("Fan2TargetRPM");
        if (ec->evaluateInteger("RYM0", &value) == kIOReturnSuccess && value < 0xFFFF)
            setProperty("Fan1MaxRPM", value, 32);
        else
            removeProperty("Fan1MaxRPM");
        if (ec->evaluateInteger("RYM1", &value) == kIOReturnSuccess && value < 0xFFFF)
            setProperty("Fan2MaxRPM", value, 32);
        else
            removeProperty("Fan2MaxRPM");
    }
    UInt32 profile = 0;
    if (wmig && wmig->getGameZoneData(GAME_ZONE_WMI_GET_SMARTFAN_MODE, &profile) && profile >= 1 && profile <= 3) {
        auto previous = OSDynamicCast(OSNumber, getProperty(smartFanPrompt));
        const bool changed = previous == nullptr || previous->unsigned32BitValue() != profile;
        setProperty(smartFanPrompt, profile, 32);
        if (changed && sampleSequence % 4 != 0)
            updateFeatureStatus();
    }
    setProperty("CPUPowerModified", powerLimitsSaved);
    if (powerLimitsSaved)
        setProperty("CPUPowerPendingProfile", powerLimitsProfile, 32);
    else
        removeProperty("CPUPowerPendingProfile");
    if (sampleSequence % 4 == 0) {
        updateBattery(false);
        updateKeyboard(false);
        updateFeatureStatus();
    }
    UInt64 uptime = 0, ns = 0;
    clock_get_uptime(&uptime);
    absolutetime_to_nanoseconds(uptime, &ns);
    setProperty("SensorSampleTimeMS", ns / 1000000, 64);
    setProperty("SensorSampleSequence", ++sampleSequence, 64);
    if (sampleSequence == 1 || sampleSequence % (detailedTelemetry ? 4 : 20) == 0)
        DebugLog("sample=%llu source=%s timeMS=%llu", sampleSequence,
                 legionBridge ? "ACPI-profile" : "WMI", ns / 1000000);
    if (trace)
        AlwaysLog("Firmware end: telemetry");
}
