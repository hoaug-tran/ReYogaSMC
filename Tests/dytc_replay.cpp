#include <cassert>
#include <cstdio>
#include <cstring>
#include <map>
#include <string>
#include <vector>
#include "ReYogaSMC/ReYogaVPC/DYTC.h"

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
void setPropertyNumber(OSDictionary *d, const char *key, unsigned value, unsigned) { d->numbers[key] = value; }
void setPropertyString(OSDictionary *d, const char *key, const char *value) { d->strings[key] = value; }
void setPropertyBoolean(OSDictionary *d, const char *key, bool value) { d->numbers[key] = value; }

// Replay the SET/GET rules and values from the supplied Lenovo ACPI tables.
struct Firmware {
    bool lap = true, mmc = false, psc = false, csc = false, dptf = false, fieldsAvailable = true;
    bool transportFailure = false;
    unsigned mmcMode = 0, pscMode = 0, otherActive = BIT(0), resets = 0;
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
            const unsigned function = lap ? 1 : mmc ? 11 : psc ? 13 : csc ? 14 : 0;
            const unsigned mode = lap ? 15 : mmc ? mmcMode : psc ? pscMode : 15;
            const unsigned active = otherActive | (lap ? BIT(1) : 0) | (mmc ? BIT(11) : 0) | (psc ? BIT(13) : 0) | (csc ? BIT(14) : 0);
            *out = 1 | (function << 8) | (mode << 12) | (active << 16);
        } else if (command == DYTC_CMD_RESET) {
            ++resets; lap = mmc = psc = csc = false; otherActive = BIT(0); *out = 1;
        } else if (command == DYTC_CMD_SET) {
            const unsigned function = (raw >> 12) & 15, mode = (raw >> 16) & 15;
            const bool enabled = (raw & BIT(20)) != 0;
            *out = 1;
            if (function == 13 && !dptf) *out = 6;
            else if (function == 11) {
                if ((enabled && (mode == 2 || mode == 3)) || (!enabled && mode == 15)) {
                    mmc = enabled; mmcMode = enabled ? mode : 0;
                } else *out = 10;
            } else if (function == 13) { psc = enabled; pscMode = mode; }
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
    bool DYTCLock = false, disabled = false;
    OSDictionary version, published;
    OSDictionary *DYTCVersion = &version;
    const char *setThermalControl = "DYTC";
    int evaluateIntegerParam(const char *, UInt32 *out, unsigned raw) { return firmware.command(raw, out); }
    void setProperty(const char *, unsigned, unsigned) {}
    void setProperty(const char *key, bool value) { if (!strcmp(key, "DYTC")) disabled = !value; }
    void setProperty(const char *key, OSDictionary *d) { if (!strcmp(key, "DYTC")) { published = *d; disabled = false; } }
    // Production thermal helpers are inserted here by test_dytc_replay.py.
    bool DYTCCommand(DYTC_CMD command, DYTC_RESULT *result, UInt8 function = 0, UInt8 mode = 0, bool enabled = false);
    bool parseDYTC(DYTC_RESULT result);
    bool updateDYTC();
    bool setDYTC(int function, int mode);
    bool setThermalProfile(UInt32 profile);
};

// Production method bodies are inserted here by test_dytc_replay.py.

int main(int argc, char **argv) {
    assert(argc == 2);
    DYTC_CMD encoding = dytc_set_cmd;
    encoding.ICFunc = 13; encoding.ICMode = 3; encoding.validF = true;
    assert(encoding.raw == 0x13d001);
    ReYogaVPC device;
    const std::string test = argv[1];
    if (test == "x1-profiles") {
        device.firmware.otherActive |= BIT(4);
        for (unsigned profile : {1U, 3U, 2U}) {
            assert(device.setThermalProfile(profile));
            assert(device.published.strings["PerfMode"] == (profile == 1 ? "Quiet" : profile == 2 ? "Balance" : "Performance (Reduced as lapmode active)"));
            assert(device.firmware.lap && device.firmware.resets == 0 && (device.firmware.otherActive & BIT(4)));
        }
        for (unsigned raw : device.firmware.commands)
            if ((raw & 0x1ff) == 1) assert(((raw >> 12) & 15) == 11);
    } else if (test == "capability-recovery") {
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
        assert(device.firmware.commands.size() == 1 && device.firmware.commands[0] == 2);
        device.firmware.fieldsAvailable = false;
        assert(device.updateDYTC());
        assert(device.published.strings["PerfMode"] == "Unavailable while lap mode masks the thermal profile");
        device.firmware.fieldsAvailable = true;
        device.firmware.mmcMode = 0x1000;
        assert(device.updateDYTC());
        assert(device.published.strings["PerfMode"] == "Unavailable while lap mode masks the thermal profile");
    } else if (test == "t490-profiles") {
        device.DYTCCap = 0x2013; device.firmware.dptf = true; device.firmware.lap = false;
        for (unsigned profile : {1U, 2U, 3U}) {
            assert(device.setThermalProfile(profile));
            assert(device.firmware.pscMode == (profile == 1 ? 3U : profile == 2 ? 5U : 7U));
        }
        device.firmware.lap = true;
        assert(device.setThermalProfile(1));
        assert(device.published.strings["PerfMode"] == "Quiet");
        assert(device.firmware.lap && !device.firmware.resets);
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
    } else if (test == "csc-balance") {
        device.firmware.lap = false;
        device.firmware.mmc = false;
        device.firmware.csc = true;
        assert(device.updateDYTC());
        assert(device.published.strings["PerfMode"] == "Balance");
        assert(device.published.strings["FuncMode"] == "Custom");
    } else return 2;
    puts("PASS production DYTC replay");
}
