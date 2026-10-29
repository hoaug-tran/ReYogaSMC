// SPDX-License-Identifier: GPL-2.0-only
// Original work: Copyright (c) 2020 Zhen.

#include "ReYogaVPC.hpp"

bool ReYogaVPC::DYTCCommand(DYTC_CMD command, DYTC_RESULT *result, UInt8 ICFunc, UInt8 ICMode, bool ValidF) {
    if (DYTCLock) {
        setProperty("DYTCBusyRejected", command.raw, 32);
        return false;
    }

    DYTCLock = true;
    if (command.raw == DYTC_CMD_SET) {
        command.ICFunc = ICFunc;
        command.ICMode = ICMode;
        command.validF = ValidF;
    }

    result->raw = 0;
    const IOReturn transport = evaluateIntegerParam(setThermalControl, &(result->raw), command.raw);
    auto diagnostic = OSDictionary::withCapacity(8);
    if (diagnostic) {
        ReYogaProperty::setNumber(diagnostic, "CommandRaw", command.raw, 32);
        ReYogaProperty::setNumber(diagnostic, "TransportStatus", transport, 32);
        ReYogaProperty::setNumber(diagnostic, "ResultRaw", result->raw, 32);
        diagnostic->setObject("ResultValid", transport == kIOReturnSuccess ? kOSBooleanTrue : kOSBooleanFalse);
        if (transport == kIOReturnSuccess)
            ReYogaProperty::setNumber(diagnostic, "FirmwareError", result->errorcode, 8);
        ReYogaProperty::setNumber(diagnostic, "Revision", DYTCRevision, 8);
        ReYogaProperty::setNumber(diagnostic, "Capabilities", DYTCCap, 16);
        setProperty("LastDYTCCommand", diagnostic);
        const UInt32 opcode = command.raw & 0xfff;
        if ((opcode == DYTC_CMD_SET && command.ICFunc != DYTC_FUNCTION_CQL) || opcode == DYTC_CMD_RESET)
            setProperty("LastDYTCMutation", diagnostic);
        diagnostic->release();
    }
    if (transport != kIOReturnSuccess) {
        AlwaysLog(toggleFailure, DYTCPrompt);
        DYTCLock = false;
        return false;
    }

    switch (result->errorcode) {
    case DYTC_SUCCESS:
        DebugLog("%s command 0x%x result 0x%08x", DYTCPrompt, command.raw, result->raw);
        break;

    case DYTC_UNSUPPORTED:
    case DYTC_DPTF_UNAVAILABLE:
        AlwaysLog("%s command 0x%x result 0x%08x (unavailable for this command)", DYTCPrompt, command.raw, result->raw);
        break;

    case DYTC_FUNC_INVALID:
    case DYTC_CMD_INVALID:
    case DYTC_MODE_INVALID:
        AlwaysLog("%s command 0x%x result 0x%08x (invalid argument)", DYTCPrompt, command.raw, result->raw);
        break;

    case DYTC_EXCEPTION:
    default:
        AlwaysLog("%s command 0x%x result 0x%08x error %d", DYTCPrompt, command.raw, result->raw, result->errorcode);
        break;
    }

    DYTCLock = false;
    return (result->errorcode == DYTC_SUCCESS);
}

void ReYogaVPC::initDYTC() {
    DYTC_RESULT result;
    if (!DYTCCommand(dytc_query_cmd, &result)) {
        setProperty("DYTC", "error");
        AlwaysLog(updateFailure, DYTCPrompt);
        return;
    }

    if (!result.query.enable) {
        AlwaysLog("%s not enabled", DYTCPrompt);
        return;
    }

    DYTCRevision = result.query.rev;

    DYTCCap = BIT(DYTC_FUNCTION_STD) | BIT(DYTC_FUNCTION_CQL);
    if (DYTCRevision < 5)
        DYTCCap |= BIT(DYTC_FUNCTION_MMC);

    DYTCVersion = OSDictionary::withCapacity(3);
    if (!DYTCVersion) {
        DYTCCap = 0;
        return;
    }
    ReYogaProperty::setNumber(DYTCVersion, "Revision", result.query.rev, 4);
    ReYogaProperty::setNumber(DYTCVersion, "SubRevision", (result.query.subrev_hi << 8) + result.query.subrev_lo, 12);

    if (DYTCRevision >= 5 && DYTCCommand(dytc_func_cap_cmd, &result)) {
        DYTCCap = result.func_cap.bitmap;
#ifdef DEBUG
        ReYogaProperty::setNumber(DYTCVersion, "FCAP", result.func_cap.bitmap, 16);
#endif
    }

    mmcGetCap = false;
    if (DYTCRevision >= 6 && (DYTCCap & BIT(DYTC_FUNCTION_MMC))) {
        if (DYTCCommand(dytc_mmc_get_cmd, &result))
            mmcGetCap = true;
    }

    setProperty("DYTC", DYTCVersion);
}

bool ReYogaVPC::parseDYTC(DYTC_RESULT result) {
    if (!DYTCVersion)
        return false;
    OSDictionary *DYTCStatus = OSDictionary::withDictionary(DYTCVersion);
    if (!DYTCStatus)
        return false;

    bool lapmode = false;

    OSDictionary *functionStatus = OSDictionary::withCapacity(16);
    if (!functionStatus) {
        DYTCStatus->release();
        return false;
    }
    for (int func_bit = 0; func_bit < 16; func_bit++) {
        if (BIT(func_bit) & DYTCCap) {
            bool func_status = (BIT(func_bit) & result.get.func_sta);
            switch (func_bit) {
            case DYTC_FUNCTION_STD:
                ReYogaProperty::setBoolean(functionStatus, "STD", func_status);
                break;

            case DYTC_FUNCTION_CQL:
                if (func_status)
                    DebugLog("DYTC_FUNCTION_CQL on");
                ReYogaProperty::setBoolean(functionStatus, "CQL", func_status);
                ReYogaProperty::setBoolean(DYTCStatus, "lapmode", func_status);
                lapmode = func_status;
                break;

            case DYTC_FUNCTION_MYH:
                if (func_status)
                    DebugLog("DYTC_FUNCTION_MYH on");
                ReYogaProperty::setBoolean(functionStatus, "MYH", func_status);
                break;

            case DYTC_FUNCTION_STP:
                if (func_status)
                    DebugLog("DYTC_FUNCTION_STP on");
                ReYogaProperty::setBoolean(functionStatus, "STP", func_status);
                break;

            case DYTC_FUNCTION_MMC:
                if (func_status)
                    DebugLog("DYTC_FUNCTION_MMC on");
                ReYogaProperty::setBoolean(functionStatus, "MMC", func_status);
                break;

            case DYTC_FUNCTION_MSC:
                if (func_status)
                    DebugLog("DYTC_FUNCTION_MSC on");
                ReYogaProperty::setBoolean(functionStatus, "MSC", func_status);
                break;

            case DYTC_FUNCTION_PSC:
                if (func_status)
                    DebugLog("DYTC_FUNCTION_PSC on");
                ReYogaProperty::setBoolean(functionStatus, "PSC", func_status);
                break;

            case DYTC_FUNCTION_CSC:
                if (func_status)
                    DebugLog("DYTC_FUNCTION_CSC on");
                ReYogaProperty::setBoolean(functionStatus, "CSC", func_status);
                break;

            case DYTC_FUNCTION_AMT:
                if (func_status)
                    DebugLog("DYTC_FUNCTION_AMT on");
                ReYogaProperty::setBoolean(functionStatus, "AMT", func_status);
                break;

            default:
                if (func_status)
                    AlwaysLog("Unknown DYTC Function 0x%X on", func_bit);
                break;
            }
        }
    }
#ifdef DEBUG
    ReYogaProperty::setNumber(functionStatus, "raw", result.get.func_sta, 16);
#endif
    DYTCStatus->setObject("Function Status", functionStatus);
    functionStatus->release();

    unsigned readbackFunction = result.get.funcmode;
    ReYogaProperty::setString(DYTCStatus, "ReadbackSource", "DYTC GET");
    if (readbackFunction == DYTC_FUNCTION_CQL || readbackFunction == DYTC_FUNCTION_CSC) {
        const bool mmcActive = (result.get.func_sta & DYTCCap & BIT(DYTC_FUNCTION_MMC)) != 0;
        const bool pscActive = (result.get.func_sta & DYTCCap & BIT(DYTC_FUNCTION_PSC)) != 0;
        const bool mmcReadable = mmcActive || (readbackFunction == DYTC_FUNCTION_CSC && supportsMMCThermal());
        const bool pscReadable = pscActive || (!supportsMMCThermal() && (DYTCCap & BIT(DYTC_FUNCTION_PSC)) != 0);
        UInt32 mode = 0;
        if (mmcActive && mmcGetCap) {
            DYTC_RESULT mmcResult;
            if (DYTCCommand(dytc_mmc_get_cmd, &mmcResult)) {
                UInt32 mmcMode = mmcResult.get.perfmode;
                if (mmcMode == 0 || mmcMode == DYTC_MODE_PERFORM || mmcMode == DYTC_MODE_QUIET || mmcMode == DYTC_MODE_BALANCE) {
                    readbackFunction = DYTC_FUNCTION_MMC;
                    result.get.perfmode = mmcMode;
                    ReYogaProperty::setString(DYTCStatus, "ReadbackSource", "DYTC MMC_GET");
                }
            }
        }
        if (readbackFunction == DYTC_FUNCTION_CQL || readbackFunction == DYTC_FUNCTION_CSC) {
            if (mmcReadable && evaluateNamedThermalMode("SMMC", &mode) &&
                (mode == 0 || mode == DYTC_MODE_PERFORM || mode == DYTC_MODE_QUIET || mode == DYTC_MODE_BALANCE)) {
                readbackFunction = DYTC_FUNCTION_MMC;
                result.get.perfmode = mode;
                ReYogaProperty::setString(DYTCStatus, "ReadbackSource", "ACPI SMMC");
            } else if (!mmcActive && pscReadable && evaluateNamedThermalMode("SPSC", &mode) &&
                       (DYTCRevision < 9 ? mode >= 1 && mode <= 8 : mode == 1 || mode == 3 || mode == 4)) {
                readbackFunction = DYTC_FUNCTION_PSC;
                result.get.perfmode = mode;
                ReYogaProperty::setString(DYTCStatus, "ReadbackSource", "ACPI SPSC");
            } else if (readbackFunction == DYTC_FUNCTION_CQL && !mmcActive && !pscActive) {
                readbackFunction = DYTC_FUNCTION_STD;
                ReYogaProperty::setString(DYTCStatus, "ReadbackSource", "DYTC function status");
            }
        }
    }

    switch (readbackFunction) {
    case DYTC_FUNCTION_STD:
        ReYogaProperty::setString(DYTCStatus, "FuncMode", "Standard");
        ReYogaProperty::setString(DYTCStatus, "PerfMode", "Balance");
        break;

    case DYTC_FUNCTION_CQL:
        ReYogaProperty::setString(DYTCStatus, "FuncMode", "Lap");
        ReYogaProperty::setString(DYTCStatus, "PerfMode", "Unavailable while lap mode masks the thermal profile");
        break;

    case DYTC_FUNCTION_MMC:
        ReYogaProperty::setString(DYTCStatus, "FuncMode", "Desk");
        switch (result.get.perfmode) {
        case DYTC_MODE_PERFORM:
            ReYogaProperty::setString(DYTCStatus, "PerfMode", lapmode ? "Performance (Reduced as lapmode active)" : "Performance");
            break;

        case DYTC_MODE_QUIET:
            ReYogaProperty::setString(DYTCStatus, "PerfMode", "Quiet");
            break;

        case 0:
        case DYTC_MODE_BALANCE:
            ReYogaProperty::setString(DYTCStatus, "PerfMode", "Balance");
            break;

        default:
            AlwaysLog(valueUnknown, DYTCPerfPrompt, result.get.perfmode);
            char Unknown[16];
            snprintf(Unknown, 16, "UnknownPerf:0x%x", result.get.perfmode);
            ReYogaProperty::setString(DYTCStatus, "PerfMode", Unknown);
            break;
        }
        break;

    case DYTC_FUNCTION_PSC:
        ReYogaProperty::setString(DYTCStatus, "FuncMode", "Controlled");
        ReYogaProperty::setNumber(DYTCStatus, "PerfLevel", result.get.perfmode, 16);
        if ((DYTCRevision >= 9 && result.get.perfmode == pscThermalMode(1)) ||
            (DYTCRevision < 9 && result.get.perfmode >= 1 && result.get.perfmode <= 4)) {
            ReYogaProperty::setString(DYTCStatus, "PerfMode", "Quiet");
        } else if ((DYTCRevision >= 9 && result.get.perfmode == pscThermalMode(2)) ||
                   (DYTCRevision < 9 && result.get.perfmode >= 5 && result.get.perfmode <= 6)) {
            ReYogaProperty::setString(DYTCStatus, "PerfMode", "Balance");
        } else if ((DYTCRevision >= 9 && result.get.perfmode == pscThermalMode(3)) ||
                   (DYTCRevision < 9 && result.get.perfmode >= 7 && result.get.perfmode <= 8)) {
            ReYogaProperty::setString(DYTCStatus, "PerfMode", lapmode ? "Performance (Reduced as lapmode active)" : "Performance");
        } else {
            AlwaysLog(valueUnknown, DYTCPerfPrompt, result.get.perfmode);
            char Unknown[16];
            snprintf(Unknown, 16, "UnknownPerf:0x%x", result.get.perfmode);
            ReYogaProperty::setString(DYTCStatus, "PerfMode", Unknown);
        }
        break;

    case DYTC_FUNCTION_CSC:
        ReYogaProperty::setString(DYTCStatus, "FuncMode", "Custom");
        ReYogaProperty::setString(DYTCStatus, "PerfMode", "Unavailable while custom mode masks the thermal profile");
        break;

    default:
        AlwaysLog(valueUnknown, DYTCFuncPrompt, result.get.funcmode);
        AlwaysLog(valueUnknown, DYTCPerfPrompt, result.get.perfmode);
        char Unknown[16];
        snprintf(Unknown, 16, "UnknownFunc:0x%x", result.get.funcmode);
        ReYogaProperty::setString(DYTCStatus, "FuncMode", Unknown);
        snprintf(Unknown, 16, "UnknownPerf:0x%x", result.get.perfmode);
        ReYogaProperty::setString(DYTCStatus, "PerfMode", Unknown);
        break;
    }

    if (lapmode)
        ReYogaProperty::setString(DYTCStatus, "FuncMode", "Lap");

    setProperty("DYTC", DYTCStatus);
    DYTCStatus->release();
    return true;
}

bool ReYogaVPC::updateDYTC() {
    if (!DYTCCap)
        return true;

    DYTC_RESULT result;
    if (!DYTCCommand(dytc_get_cmd, &result))
        return false;

    // X1C7 X1C7 X1C7 X1C7 X1C7 X1C7 X1C7 X1C7
    if (result.get.funcmode == DYTC_FUNCTION_CQL && supportsMMCThermal() && !mmcGetCap) {
        UInt32 dummyMode = 0;
        if (!evaluateNamedThermalMode("SMMC", &dummyMode)) {
            DYTC_RESULT unmaskedResult;
            DYTC_RESULT cqlDummy;
            if (DYTCCommand(dytc_set_cmd, &cqlDummy, DYTC_FUNCTION_CQL, DYTC_MODE_BALANCE, false)) {
                if (DYTCCommand(dytc_get_cmd, &unmaskedResult)) {
                    if (unmaskedResult.get.funcmode == DYTC_FUNCTION_MMC) {
                        result.get.funcmode = DYTC_FUNCTION_MMC;
                        result.get.perfmode = unmaskedResult.get.perfmode;
                    } else if (unmaskedResult.get.funcmode == DYTC_FUNCTION_STD) {
                        result.get.funcmode = DYTC_FUNCTION_MMC;
                        result.get.perfmode = DYTC_MODE_BALANCE;
                    }
                }
                DYTCCommand(dytc_set_cmd, &cqlDummy, DYTC_FUNCTION_CQL, DYTC_MODE_BALANCE, true);
            }
        }
    }

    return parseDYTC(result);
}

bool ReYogaVPC::setThermalProfile(UInt32 profile) {
    if (profile < 1 || profile > 3 || !supportsThermalProfiles())
        return false;
    const bool useMMC = supportsMMCThermal();
    const int func = useMMC ? DYTC_FUNCTION_MMC : DYTC_FUNCTION_PSC;
    const int mode = useMMC ? (profile == 1 ? DYTC_MODE_QUIET : profile == 2 ? DYTC_MODE_BALANCE
                                                                             : DYTC_MODE_PERFORM)
                            : pscThermalMode(profile);
    const bool ok = setDYTC(func, mode);
    if (ok) {
        if (!useMMC && (DYTCCap & BIT(DYTC_FUNCTION_AMT))) {
            const bool enableAmt = (profile == 2);
            DYTC_RESULT result;
            const int amtMode = enableAmt ? DYTC_MODE_AMT_ENABLE : DYTC_MODE_AMT_DISABLE;
            DYTCCommand(dytc_set_cmd, &result, DYTC_FUNCTION_AMT, amtMode, enableAmt);
        }
    }
    return ok;
}

bool ReYogaVPC::setDYTC(int funcmode, int perfmode) {
    if (!DYTCCap || funcmode < 0 || funcmode >= 16 || !(DYTCCap & BIT(funcmode)) || perfmode < 0 || perfmode > 0xf)
        return false;

    DYTC_RESULT result;

    const bool enabled = !(funcmode == DYTC_FUNCTION_MMC && perfmode == DYTC_MODE_BALANCE);
    if (!DYTCCommand(dytc_set_cmd, &result, funcmode, perfmode, enabled))
        return false;

    return updateDYTC();
}

bool ReYogaVPC::evaluateNamedThermalMode(const char *name, UInt32 *out) {
    if (!vpc || !name || !out)
        return false;
    auto diagnostic = OSDictionary::withCapacity(6);
    auto read = [&](const char *path, const char *statusKey) {
        const IOReturn status = vpc->evaluateInteger(path, out);
        if (diagnostic)
            ReYogaProperty::setNumber(diagnostic, statusKey, status, 32);
        return status == kIOReturnSuccess;
    };
    char path[16];
    bool success = read(name, "RelativeStatus");
    if (!success) {
        snprintf(path, sizeof(path), "\\%s", name);
        success = read(path, "RootStatus");
    }
    if (!success) {
        snprintf(path, sizeof(path), "^%s", name);
        success = read(path, "ParentStatus");
    }
    if (diagnostic) {
        ReYogaProperty::setString(diagnostic, "Field", name);
        ReYogaProperty::setBoolean(diagnostic, "ValueValid", success);
        if (success)
            ReYogaProperty::setNumber(diagnostic, "Value", *out, 32);
        setProperty("LastDYTCReadback", diagnostic);
        diagnostic->release();
    }
    return success;
}
