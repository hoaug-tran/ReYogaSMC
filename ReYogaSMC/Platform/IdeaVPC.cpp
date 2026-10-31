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
#include "../WMI/IdeaWMI.hpp"
OSDefineMetaClassAndStructors(IdeaVPC, ReYogaVPC);

void IdeaVPC::updateAll() {
    if (safeMode)
        return;
    const bool trace = firmwareTrace && firmwareRefreshTraces < 4;
    if (trace)
        ++firmwareRefreshTraces;
    if (trace)
        AlwaysLog("Firmware begin: battery state");
    updateBattery();
    if (trace)
        AlwaysLog("Firmware end: battery state; begin: keyboard state");
    updateKeyboard();
    if (trace)
        AlwaysLog("Firmware end: keyboard state; begin: VPC event handshake");
    updateVPC();
    if (trace)
        AlwaysLog("Firmware end: VPC event handshake");
    if (wmig) {
        UInt32 val = 0;
        if (wmig->getGameZoneData(GAME_ZONE_WMI_GET_SMARTFAN_MODE, &val))
            setProperty(smartFanPrompt, val, 32);
        if (wmig->getGameZoneData(GAME_ZONE_WMI_GET_OVER_DRIVE, &val))
            setProperty(overDrivePrompt, val, 32);
        if (wmig->getGameZoneData(GAME_ZONE_WMI_GET_WIN_KEY, &val))
            setProperty(winKeyPrompt, val, 32);
        if (wmig->getGameZoneData(GAME_ZONE_WMI_GET_TOUCHPAD, &val))
            setProperty(touchpadLockPrompt, val, 32);
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
    updateTelemetry();
    if (trace)
        AlwaysLog("Firmware begin: feature status");
    updateFeatureStatus();
    if (trace)
        AlwaysLog("Firmware end: feature status; begin: base VPC refresh");
    super::updateAll();
    if (trace)
        AlwaysLog("Firmware end: base VPC refresh");
}

bool IdeaVPC::start(IOService *provider) {
    if (!super::start(provider))
        return false;
    if (safeMode)
        return true;
    if (!telemetryPoller) {
        telemetryPoller = IOTimerEventSource::timerEventSource(this, [](OSObject *owner, IOTimerEventSource *timer) {
            auto self = OSDynamicCast(IdeaVPC, owner);
            if (self && self->telemetryAwake) {
                // The PCI subsystem ID used for identity (dGPU 17aa:3a58) may
                // not be published yet when initVPC runs; retry matching.
                if (!self->nativeProfile && self->profileRetriesLeft) {
                    auto stage = OSDynamicCast(OSString, self->getProperty("ProfileMatchStage"));
                    if (stage && stage->isEqualTo("identity_unavailable")) {
                        if ((self->profileRetriesLeft-- % 4) == 0) {
                            self->initNativeProfile();
                            self->initBridge();
                            if (self->nativeProfile) {
                                self->setProperty("ProfileMatchDeferred", true);
                                self->updateAll();
                            }
                        }
                    } else
                        self->profileRetriesLeft = 0;
                }
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
    return true;
}

bool IdeaVPC::initVPC() {
    if (safeMode) {
        telemetryAwake = false;
        setProperty("SafeMode", kOSBooleanTrue);
        setProperty("SafeModeReason", "-reysafe: ACPI, EC and WMI hardware access disabled");
        AlwaysLog("Safe mode enabled; skipping ACPI/EC initialization");
        return true;
    }

    setProperty("FirmwareTraceEnabled", firmwareTrace);
    setProperty("FirmwareTraceCallLimit", 128, 32);
    setProperty("WMIProbeDisabled", !vendorWMISupport);
    setProperty("ACPIBridgeDisabled", bridgeDisabled);
    AlwaysLog("Boot stage: checking EC readiness");
    if (!initEC())
        return false;
    AlwaysLog("Boot stage: EC ready; initializing base VPC");
    super::initVPC();
    AlwaysLog("Boot stage: base VPC initialized; reading _CFG");
    UInt32 config = 0;
    const bool configAvailable = vpc->evaluateInteger(getVPCConfig, &config) == kIOReturnSuccess;
    setProperty("VPCConfigAvailable", configAvailable);
    if (!configAvailable)
        AlwaysLog("_CFG unavailable; discovering individual ACPI/WMI capabilities");

    DebugLog(updateSuccess, VPCPrompt, config);
    setProperty(VPCPrompt, config, 32);

    OSDictionary *capabilities = OSDictionary::withCapacity(6);
    if (!capabilities)
        return false;

    ReYogaProperty::setBoolean(capabilities, "Bluetooth", (config >> CFG_BT_BIT) & 0x1);
    ReYogaProperty::setBoolean(capabilities, "3G", (config >> CFG_3G_BIT) & 0x1);
    ReYogaProperty::setBoolean(capabilities, "Wireless", (config >> CFG_WIFI_BIT) & 0x1);
    ReYogaProperty::setBoolean(capabilities, "Camera", (config >> CFG_CAMERA_BIT) & 0x1);
    ReYogaProperty::setBoolean(capabilities, "Touchpad", (config >> CFG_TOUCHPAD_BIT) & 0x1);

    UInt8 cap_graphics = config >> CFG_GRAPHICS_3BIT & 0x7;
    switch (cap_graphics) {
    case 1:
        ReYogaProperty::setString(capabilities, "Graphics", "Intel");
        break;

    case 2:
        ReYogaProperty::setString(capabilities, "Graphics", "ATI");
        break;

    case 3:
        ReYogaProperty::setString(capabilities, "Graphics", "Nvidia");
        break;

    case 4:
        ReYogaProperty::setString(capabilities, "Graphics", "Intel and ATI");
        break;

    case 5:
        ReYogaProperty::setString(capabilities, "Graphics", "Intel and Nvidia");
        break;

    default:
        char Unknown[10];
        snprintf(Unknown, 10, "Unknown:%1x", cap_graphics);
        ReYogaProperty::setString(capabilities, "Graphics", Unknown);
        break;
    }
    setProperty("Capability", capabilities);
    capabilities->release();

    AlwaysLog("Boot stage: _CFG read; reading keyboard capabilities");
    updateKeyboardCapability();
    AlwaysLog("Boot stage: keyboard capabilities read; reading battery capabilities");
    updateBatteryCapability();
    AlwaysLog("Boot stage: battery capabilities read; reading adapter state");
    isPowerChanged();
    AlwaysLog("Boot stage: adapter state read");

    int val[16] = {};
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
    initNativeProfile();
    initBridge();
    setProperty("ControlProtocolVersion", 1, 32);
    setProperty("TelemetryIntervalMS", telemetryIntervalMS, 32);
    setProperty("FeaturePollingVersion", 1, 32);

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

    switch (type) {
    case kSMC_YogaEvent: {
        UInt32 mode = *(reinterpret_cast<UInt32 *>(argument));
        DebugLog("message: %s Yoga mode 0x%x", provider->getName(), mode);
        if (client)
            client->sendNotification(0x10, mode); // Since vpc_bit is less than 16
        if (backlightCap && automaticBacklightMode & BIT(1)) {
            updateKeyboard();
            if (mode != 1) {
                if (backlightLevel)
                    backlightLevelSaved = backlightLevel;
                if (backlightLevel)
                    backlightAutomaticOff = setBacklight(0);
            } else {
                if (backlightLevelSaved != backlightLevel && setBacklight(backlightLevelSaved))
                    backlightAutomaticOff = false;
            }
        }
    } break;

    case kSMC_FnlockEvent:
        DebugLog("message: %s Fnlock event", provider->getName());
        updateFnLock();
        setFnLock(!FnlockMode);
        break;

    case kSMC_getConservation:
        if (!argument)
            return kIOReturnBadArgument;
        if (!updateBattery(false))
            return kIOReturnIOError;
        *(reinterpret_cast<bool *>(argument)) = conservationMode;
        DebugLog("message: %s get conservation mode %d", provider->getName(), conservationMode);
        break;

    case kSMC_setConservation:
        if (!argument)
            return kIOReturnBadArgument;
        if (!updateBattery(false))
            return kIOReturnIOError;
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

void IdeaVPC::updateVPC(UInt32 event) {
    if (vpc->validateObject(readVPCStatus) != kIOReturnSuccess ||
        vpc->validateObject(writeVPCStatus) != kIOReturnSuccess)
        return;
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
                rememberBacklight(backlightLevel);
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
                rememberBacklight(backlightLevel);
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
         now_abs < deadline;) {
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
         now_abs < deadline;) {
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

    OSObject *params[2] = {
        OSNumber::withNumber(cmd, 32),
        OSNumber::withNumber(data, 32),
    };

    if (!params[0] || !params[1]) {
        OSSafeReleaseNULL(params[0]);
        OSSafeReleaseNULL(params[1]);
        return false;
    }
    IOReturn ret = vpc->evaluateInteger(writeVPCStatus, &result, params, 2);
    params[0]->release();
    params[1]->release();

    return (ret == kIOReturnSuccess);
}

IOReturn IdeaVPC::setPowerState(unsigned long state, IOService *device) {
    if (safeMode)
        return kIOPMAckImplied;
    if (!commandGate)
        return kIOPMAckImplied;
    return commandGate->runAction([](OSObject *owner, void *ordinal, void *device, void *, void *) -> IOReturn {
        return static_cast<IdeaVPC *>(owner)->setPowerStateGated(*static_cast<unsigned long *>(ordinal), static_cast<IOService *>(device));
    },
                                  &state, device);
}

IOReturn IdeaVPC::setPowerStateGated(unsigned long state, IOService *device) {
    if (stopping)
        return kIOPMAckImplied;
    if (device != this)
        return kIOReturnInvalid;
    if (state == 0) {
        telemetryAwake = false;
        restorePowerLimits();
        if (telemetryPoller)
            telemetryPoller->cancelTimeout();
        if (legionBridge) {
            UInt32 result = 0;
            ec->evaluateInteger("RYFA", &result);
        }
    }
    IOReturn ret = super::setPowerState(state, device);
    if (state != 0) {
        telemetryAwake = true;
        auto currentFullFan = getProperty(fullFanPrompt);
        if (currentFullFan && currentFullFan == kOSBooleanTrue) {
            if (legionBridge && ec && ec->validateObject("RYFF") == kIOReturnSuccess) {
                auto argument = OSNumber::withNumber(1ULL, 32);
                if (argument) {
                    OSObject *arguments[] = {argument};
                    UInt32 ecResult = 0;
                    ec->evaluateInteger("RYFF", &ecResult, arguments, 1);
                    argument->release();
                }
            } else if (wmig) {
                wmig->setFanFullSpeed(true);
            }
        }
        updateFeatureStatus();
        updateTelemetry();
        if (telemetryPoller)
            telemetryPoller->setTimeoutMS(telemetryIntervalMS);
    }
    return ret;
}
