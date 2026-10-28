#include "ControlValidation.hpp"
#include "ThinkEvents.h"
#include "ThinkVPC.hpp"

OSDefineMetaClassAndStructors(ThinkVPC, ReYogaVPC);

void ThinkVPC::updateAll() {
    updateNotificationMask();
    updateBattery();
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

bool ThinkVPC::initVPC() {
    if (!super::initVPC())
        return false;
    setProperty("ThinkPadACPIAnalysisVersion", 1, 32);
    char path[512];
    int length = sizeof(path);
    if (ec->getPath(path, &length, gIOACPIPlane))
        setProperty("ACPIECPath", path);
    length = sizeof(path);
    if (vpc->getPath(path, &length, gIOACPIPlane))
        setProperty("ACPIHKEYPath", path);
    UInt32 version;

    if (vpc->evaluateInteger(getHKEYversion, &version) != kIOReturnSuccess) {
        AlwaysLog(initFailure, getHKEYversion);
        return false;
    }

    KBDProperty = OSDictionary::withCapacity(1);
    if (!KBDProperty)
        return false;
    DebugLog("HKEY interface version %x", version);
    ReYogaProperty::setNumber(KBDProperty, "Version", version, 32);
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
    if (getProperty(HotKeyPrompt) == kOSBooleanTrue)
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
        ReYogaProperty::setNumber(KBDProperty, "hotkey_all_mask", result, 32);
        break;

    case 2:
        if (result) {
            hotkey_adaptive_all_mask = result;
            ReYogaProperty::setNumber(KBDProperty, "hotkey_adaptive_all_mask", result, 32);
        }
        break;

    case 3:
        hotkey_alter_all_mask = result;
        ReYogaProperty::setNumber(KBDProperty, "hotkey_alter_all_mask", result, 32);
        break;

    default:
        AlwaysLog("Unknown MHKA command");
        break;
    }
    return true;
}

IOReturn ThinkVPC::message(UInt32 type, IOService *provider, void *argument) {
    if (getProperty("SafeMode") == kOSBooleanTrue)
        return kIOReturnUnsupported;
    switch (type) {
    // TODO: determine default value for charge level
    case kSMC_getConservation:
    case kSMC_setConservation:
        break;

    case kIOACPIMessageDeviceNotification:
        if (argument && *(reinterpret_cast<UInt32 *>(argument)) == kIOACPIMessageReserved) {
            if (!commandGate || isInactive())
                return kIOReturnNotReady;
            return commandGate->runAction([](OSObject *owner, void *, void *, void *, void *) -> IOReturn {
                auto self = static_cast<ThinkVPC *>(owner);
                if (self->stopping || self->isInactive())
                    return kIOReturnNotAttached;
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
            rememberBacklight(backlightLevel);
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

IOReturn ThinkVPC::setPowerState(unsigned long powerStateOrdinal, IOService *whatDevice) {
    if (getProperty("SafeMode") == kOSBooleanTrue)
        return kIOPMAckImplied;
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
                !setNotificationMask(i, hotkey_all_mask, DHKN_MASK_offset))
                break;
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
