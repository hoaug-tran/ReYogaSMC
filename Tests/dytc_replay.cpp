#include <cassert>
#include <cstdio>
#include <cstring>
#include <map>
#include <string>
#include <vector>
#include "ReYogaSMC/Platform/DYTC.h"
#include "ReYogaSMC/ControlValidation.hpp"
#include "ReYogaSMC/SensorDescriptors.hpp"

using IOReturn = int;
constexpr int kIOReturnSuccess = 0;
constexpr int kIOReturnUnsupported = -1;
#define BIT(n) (1U << (n))
#define AlwaysLog(...) do {} while (0)
#define DebugLog(...) do {} while (0)
const bool kOSBooleanTrue = true, kOSBooleanFalse = false;
const char *DYTCPerfPrompt = "DYTCPerf", *DYTCFuncPrompt = "DYTCFunc", *DYTCPrompt = "DYTC";

struct OSDictionary {
    std::map<std::string, unsigned> numbers;
    std::map<std::string, std::string> strings;
    static OSDictionary *withCapacity(unsigned) { return new OSDictionary; }
    static OSDictionary *withDictionary(OSDictionary *other) { return new OSDictionary(*other); }
    void setObject(const char *, OSDictionary *) {}
    void setObject(const char *key, bool value) { numbers[key] = value; }
    void release() { delete this; }
};
namespace ReYogaProperty {
void setNumber(OSDictionary *d, const char *key, unsigned value, unsigned) { d->numbers[key] = value; }
void setString(OSDictionary *d, const char *key, const char *value) { d->strings[key] = value; }
void setBoolean(OSDictionary *d, const char *key, bool value) { d->numbers[key] = value; }
}

// SET/GET protocol model from supplied ACPI; SMI, EC timing and completion are not emulated.
struct Firmware {
    bool lap = true, mmc = false, psc = false, csc = false, amt = false, fieldsAvailable = true;
    bool rejectPSC = false; // Inject command-specific firmware rejection, not a model capability.
    bool transportFailure = false;
    unsigned mmcMode = 0, pscMode = 0, amtMode = 0, otherActive = BIT(0), resets = 0;
    std::vector<unsigned> commands;
    int evaluateInteger(const char *name, UInt32 *out) {
        if (!fieldsAvailable) return kIOReturnUnsupported;
        if (!strcmp(name, "\\SMMC") || !strcmp(name, "SMMC") || !strcmp(name, "^SMMC")) *out = mmcMode;
        else if (!strcmp(name, "\\SPSC") || !strcmp(name, "SPSC") || !strcmp(name, "^SPSC")) *out = pscMode;
        else return kIOReturnUnsupported;
        return kIOReturnSuccess;
    }
    int command(unsigned raw, UInt32 *out) {
        commands.push_back(raw);
        if (transportFailure) { transportFailure = false; return kIOReturnUnsupported; }
        const unsigned command = raw & 0x1ff;
        if (command == DYTC_CMD_GET) {
            unsigned function = 0, mode = 15;
            // Captured X1C7 responses select CSC even with CQL active.
            if (csc) function = 14;
            else if (lap) function = 1;
            else if (mmc) { function = 11; mode = mmcMode; }
            else if (psc) { function = 13; mode = pscMode; }
            const unsigned active = otherActive | (lap ? BIT(1) : 0) | (mmc ? BIT(11) : 0) | (psc ? BIT(13) : 0) | (csc ? BIT(14) : 0);
            *out = 1 | (function << 8) | (mode << 12) | (active << 16);
        } else if (command == DYTC_CMD_MMC_GET) {
            *out = 1 | (11 << 8) | (mmcMode << 12) | (1 << 16);
        } else if (command == DYTC_CMD_RESET) {
            ++resets; lap = mmc = psc = csc = false; otherActive = BIT(0); *out = 1;
        } else if (command == DYTC_CMD_SET) {
            const unsigned function = (raw >> 12) & 15, mode = (raw >> 16) & 15;
            const bool enabled = (raw & BIT(20)) != 0;
            *out = 1;
            if (function == 13 && rejectPSC) *out = 6;
            else if (function == 11) {
                if ((enabled && (mode == 2 || mode == 3)) || (!enabled && mode == 15)) {
                    mmc = enabled; mmcMode = enabled ? mode : 0;
                } else *out = 10;
            } else if (function == 13) {
                if ((enabled && mode >= 1 && mode <= 8) || (!enabled && mode == 15)) {
                    psc = enabled; pscMode = enabled ? mode : 0;
                } else *out = 10;
            }
            else if (function == 15) { amt = enabled; amtMode = mode; }
            else if (function == 1 && mode == 15) lap = enabled;
            else *out = 2;
        } else *out = 4;
        return kIOReturnSuccess;
    }
};

struct ReYogaVPC {
    Firmware firmware;
    Firmware *vpc = &firmware;
    UInt16 DYTCCap = 0x7913;
    UInt8 DYTCRevision = 5;
    bool DYTCLock = false, disabled = false, mmcGetCap = false;
    OSDictionary version, published, lastMutation, lastReadback;
    OSDictionary *DYTCVersion = &version;
    const char *setThermalControl = "DYTC";
    int evaluateIntegerParam(const char *, UInt32 *out, unsigned raw) { return firmware.command(raw, out); }
    void setProperty(const char *, unsigned, unsigned) {}
    void setProperty(const char *key, bool value) { if (!strcmp(key, "DYTC")) disabled = !value; }
    void setProperty(const char *key, OSDictionary *d) {
        if (!strcmp(key, "DYTC")) { published = *d; disabled = false; }
        if (!strcmp(key, "LastDYTCMutation")) lastMutation = *d;
        if (!strcmp(key, "LastDYTCReadback")) lastReadback = *d;
    }
    // Production thermal helpers are inserted here by test_dytc_replay.py.
    bool DYTCCommand(DYTC_CMD command, DYTC_RESULT *result, UInt8 function = 0, UInt8 mode = 0, bool enabled = false);
    bool evaluateNamedThermalMode(const char *name, UInt32 *out);
    bool parseDYTC(DYTC_RESULT result);
    bool updateDYTC();
    bool setDYTC(int function, int mode);
    bool setThermalProfile(UInt32 profile);
};

// Production method bodies are inserted here by test_dytc_replay.py.

int main(int argc, char **argv) {
    assert(argc == 2);
    static_assert(ReYogaSensor::Fan1 == 0 && ReYogaSensor::Fan2 == 1 &&
                  ReYogaSensor::CPU == 2 && ReYogaSensor::GPU == 3 && ReYogaSensor::Count == 4,
                  "Keep generated profile sensor order");
    assert(!strcmp(ReYogaSensor::descriptors[ReYogaSensor::CPU].bridgeMethod, "RYT0"));
    assert(ReYogaSensor::descriptors[ReYogaSensor::Fan2].isFan);
    assert(!ReYogaSensor::descriptors[ReYogaSensor::GPU].isFan);
    assert(ReYogaControl::validControlEnvelopeLengths(64, 64));
    assert(!ReYogaControl::validControlEnvelopeLengths(65, 64));
    assert(!ReYogaControl::validControlEnvelopeLengths(64, 65));
    DYTC_CMD encoding = dytc_set_cmd;
    encoding.ICFunc = 13; encoding.ICMode = 3; encoding.validF = true;
    assert(encoding.raw == 0x13d001);
    ReYogaVPC device;
    const std::string test = argv[1];
    if (test == "captured-readbacks") {
        struct Capture { unsigned revision, capabilities, raw; const char *expected; };
        const Capture captures[] = {
            {4, 0x2d13, 0x08012b01, "Performance"},
            {5, 0x7913, 0x0003f101, "Balance"},
            {5, 0x7913, 0x0803f101, "Unavailable while lap mode masks the thermal profile"},
            {5, 0x7913, 0x4003fe01, "Unavailable while custom mode masks the thermal profile"},
            {5, 0x7913, 0x4803fe01, "Unavailable while custom mode masks the thermal profile"},
            {5, 0x7913, 0x4001fe01, "Unavailable while custom mode masks the thermal profile"},
            {5, 0x7913, 0x0001f001, "Balance"},
            {5, 0x7913, 0x08012b01, "Performance"},
            {5, 0x2013, 0x20017d01, "Performance"},
            {5, 0x2013, 0x20015d01, "Balance"},
            {5, 0x2013, 0x0001f001, "Balance"},
            {5, 0x2013, 0x0001f101, "Balance"},
        };
        device.firmware.fieldsAvailable = false;
        for (const auto &capture : captures) {
            device.DYTCRevision = capture.revision;
            device.DYTCCap = capture.capabilities;
            DYTC_RESULT result;
            result.raw = capture.raw;
            assert(device.parseDYTC(result));
            assert(device.published.strings.at("PerfMode") == capture.expected);
        }
        assert(device.firmware.commands.empty());
    } else if (test == "mutation-diagnostics") {
        device.DYTCCap = 0x2013;
        device.firmware.lap = false;
        assert(device.setThermalProfile(1));
        assert(device.lastMutation.numbers.at("CommandRaw") == 0x13d001);
        assert(device.lastMutation.numbers.at("FirmwareError") == 1);
        device.firmware.transportFailure = true;
        assert(!device.setThermalProfile(3));
        assert(device.lastMutation.numbers.at("CommandRaw") == 0x17d001);
        assert(device.lastMutation.numbers.at("ResultValid") == 0);
        assert(!device.lastMutation.numbers.count("FirmwareError"));
        device.firmware.rejectPSC = true;
        assert(!device.setThermalProfile(1));
        assert(device.lastMutation.numbers.at("FirmwareError") == 6);
        assert(device.updateDYTC());
        assert(device.lastMutation.numbers.at("FirmwareError") == 6);
        assert(device.lastMutation.numbers.at("CommandRaw") == 0x13d001);
        DYTC_RESULT result;
        assert(device.DYTCCommand(dytc_reset_cmd, &result));
        assert(device.lastMutation.numbers.at("CommandRaw") == DYTC_CMD_RESET);
    } else if (test == "psc-mode-validation") {
        device.DYTCCap = 0x2013;
        device.firmware.lap = false;
        for (int mode = 0; mode <= 15; ++mode) {
            const bool valid = mode >= 1 && mode <= 8;
            assert(device.setDYTC(13, mode) == valid);
            assert(device.lastMutation.numbers.at("FirmwareError") == (valid ? 1U : 10U));
        }
        assert(device.setThermalProfile(3));
        assert(device.published.strings.at("PerfMode") == "Performance");
    } else if (test == "profile-transition-matrix") {
        struct Machine { unsigned revision, capabilities; bool lap; };
        for (const Machine machine : {Machine{5, 0x2013, false}, Machine{5, 0x7913, true},
                                      Machine{4, 0x2d13, false}, Machine{5, 0, false}}) {
            device.firmware = Firmware{};
            device.DYTCRevision = machine.revision;
            device.DYTCCap = machine.capabilities;
            device.firmware.lap = machine.lap;
            for (unsigned from : {1U, 2U, 3U}) {
                for (unsigned to : {1U, 2U, 3U}) {
                    const auto before = device.firmware.commands.size();
                    if (!machine.capabilities) {
                        assert(!device.setThermalProfile(to));
                        assert(device.firmware.commands.size() == before);
                        continue;
                    }
                    assert(device.setThermalProfile(from));
                    assert(device.setThermalProfile(to));
                    assert(device.published.strings.at("PerfMode") ==
                           (to == 1 ? "Quiet" : to == 2 ? "Balance" : machine.lap ?
                            "Performance (Reduced as lapmode active)" : "Performance"));
                    assert(device.firmware.lap == machine.lap && device.firmware.resets == 0);
                }
            }
        }
    } else if (test == "x1-profiles") {
        device.firmware.otherActive |= BIT(4);
        for (unsigned profile : {1U, 3U, 2U}) {
            assert(device.setThermalProfile(profile));
            assert(device.published.strings["PerfMode"] == (profile == 1 ? "Quiet" : profile == 2 ? "Balance" : "Performance (Reduced as lapmode active)"));
            assert(device.firmware.lap && device.firmware.resets == 0 && (device.firmware.otherActive & BIT(4)));
        }
        for (unsigned raw : device.firmware.commands)
            if ((raw & 0x1ff) == 1) assert(((raw >> 12) & 15) == 11);
    } else if (test == "capability-recovery") {
        device.firmware.rejectPSC = true;
        assert(!device.setDYTC(13, 3));
        assert(device.DYTCCap == 0x7913 && !device.disabled);
        assert(device.updateDYTC());
        assert(device.setThermalProfile(1));
    } else if (test == "balanced-no-reset") {
        device.firmware.lap = false; device.firmware.mmc = true; device.firmware.mmcMode = 3;
        assert(device.setDYTC(11, 15));
        assert(device.firmware.resets == 0 && !device.firmware.mmc);
        assert(device.published.strings["PerfMode"] == "Balance");
    } else if (test == "masked-readback") {
        device.firmware.mmc = true; device.firmware.mmcMode = 3;
        assert(device.updateDYTC());
        assert(device.published.strings["PerfMode"] == "Quiet");
        assert(device.lastReadback.numbers.at("ValueValid") == 1);
        assert(device.lastReadback.numbers.at("Value") == 3);
        assert(device.firmware.commands.size() == 1 && device.firmware.commands[0] == 2);
        device.firmware.fieldsAvailable = false;
        assert(device.updateDYTC());
        assert(device.published.strings["PerfMode"] == "Unavailable while lap mode masks the thermal profile");
        assert(device.lastReadback.strings.at("Field") == "SMMC");
        assert(device.lastReadback.numbers.at("ValueValid") == 0);
        assert(device.lastReadback.numbers.count("RootStatus"));
        assert(device.lastReadback.numbers.count("ParentStatus"));
        assert(!device.lastReadback.numbers.count("Value"));
        device.firmware.fieldsAvailable = true;
        device.firmware.mmcMode = 0x1000;
        assert(device.updateDYTC());
        assert(device.published.strings["PerfMode"] == "Unavailable while lap mode masks the thermal profile");
    } else if (test == "t490-profiles") {
        device.DYTCCap = 0x2013; device.firmware.lap = false;
        for (unsigned profile : {1U, 2U, 3U}) {
            assert(device.setThermalProfile(profile));
            assert(device.firmware.pscMode == (profile == 1 ? 3U : profile == 2 ? 5U : 7U));
        }
        device.firmware.lap = true;
        assert(device.setThermalProfile(1));
        assert(device.published.strings["PerfMode"] == "Quiet");
        assert(device.firmware.lap && !device.firmware.resets);
        device.firmware.psc = false;
        assert(device.setThermalProfile(3));
        assert(device.published.strings["PerfMode"] == "Performance (Reduced as lapmode active)");
        assert(device.published.strings["ReadbackSource"] == "ACPI SPSC");
        device.firmware.fieldsAvailable = false;
        assert(device.updateDYTC());
        assert(device.published.strings["PerfMode"] == "Unavailable while lap mode masks the thermal profile");
        device.firmware.psc = false;
        DYTC_RESULT captured{};
        captured.raw = 0x0001f101;
        assert(device.parseDYTC(captured));
        assert(device.published.strings["PerfMode"] == "Balance");
        assert(device.published.strings["ReadbackSource"] == "DYTC function status");
        device.firmware.fieldsAvailable = true;
        device.DYTCRevision = 9;
        for (unsigned profile : {1U, 2U, 3U}) {
            assert(device.setThermalProfile(profile));
            assert(device.firmware.pscMode == (profile == 1 ? 1U : profile == 2 ? 3U : 4U));
        }
    } else if (test == "transport-recovery") {
        device.firmware.transportFailure = true;
        assert(!device.updateDYTC());
        assert(device.DYTCCap == 0x7913 && !device.disabled);
        assert(device.updateDYTC());
    } else if (test == "invalid-input") {
        assert(!device.setThermalProfile(0) && !device.setThermalProfile(4));
        assert(!device.setDYTC(11, 16) && !device.setDYTC(11, -1));
        assert(!device.setDYTC(16, 3) && !device.setDYTC(-1, 3));
        assert(device.firmware.commands.empty());
    } else if (test == "x1-csc-with-lap") {
        device.firmware.csc = true;
        device.firmware.mmc = true;
        device.firmware.mmcMode = 3;
        device.firmware.fieldsAvailable = false;
        UInt32 captured = 0;
        assert(device.firmware.command(2, &captured) == kIOReturnSuccess);
        assert(captured == 0x4803fe01);
        assert(device.setThermalProfile(3));
        assert(device.lastMutation.numbers.at("FirmwareError") == 1);
        assert(device.published.strings.at("PerfMode") == "Unavailable while custom mode masks the thermal profile");
        assert(device.firmware.csc && device.firmware.lap && !device.firmware.resets);
    } else if (test == "csc-balance") {
        device.firmware.lap = false;
        device.firmware.mmc = false;
        device.firmware.csc = true;
        assert(device.updateDYTC());
        assert(device.published.strings["PerfMode"] == "Balance");
        assert(device.published.strings["ReadbackSource"] == "ACPI SMMC");
    } else if (test == "csc-captured-quiet") {
        device.firmware.mmcMode = 3;
        DYTC_RESULT captured;
        captured.raw = 0x4803fe01;
        assert(device.parseDYTC(captured));
        assert(device.published.strings["PerfMode"] == "Quiet");
        assert(device.published.strings["ReadbackSource"] == "ACPI SMMC");
        device.firmware.fieldsAvailable = false;
        assert(device.parseDYTC(captured));
        assert(device.published.strings["PerfMode"] == "Unavailable while custom mode masks the thermal profile");
    } else if (test == "masked-request-not-readback") {
        device.firmware.fieldsAvailable = false;
        for (unsigned requested : {3U, 1U, 3U}) {
            assert(device.setThermalProfile(requested));
            assert(device.published.strings["PerfMode"] == "Unavailable while lap mode masks the thermal profile");
            assert(device.published.strings["ReadbackSource"] != "Driver cached profile");
        }
    } else if (test == "mmc-get-lapmode") {
        device.DYTCRevision = 6;
        device.mmcGetCap = true;
        device.firmware.mmc = true;
        device.firmware.mmcMode = 2;
        device.firmware.fieldsAvailable = false;
        assert(device.updateDYTC());
        assert(device.published.strings["PerfMode"] == "Performance (Reduced as lapmode active)");
        assert(device.published.strings["ReadbackSource"] == "DYTC MMC_GET");
    } else if (test == "amt-psc-toggle") {
        device.DYTCCap = 0xa013;
        device.firmware.lap = false;
        assert(device.setThermalProfile(2));
        assert(device.firmware.amt && device.firmware.amtMode == 1);
        assert(device.setThermalProfile(1));
        assert(!device.firmware.amt && device.firmware.amtMode == 15);
        assert(device.setThermalProfile(3));
        assert(!device.firmware.amt && device.firmware.amtMode == 15);
    } else return 2;
    puts("PASS production DYTC replay");
}
