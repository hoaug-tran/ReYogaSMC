// SPDX-License-Identifier: GPL-2.0-only
// Original work: Copyright (c) 2020 Zhen.
#ifndef ReYogaVPC_hpp
#define ReYogaVPC_hpp

#include "DYTC.h"
#include "ControlValidation.hpp"
#include "ReYogaBaseService.hpp"
#include "ReYogaSMCUserClientPrivate.hpp"

class ReYogaVPC : public ReYogaBaseService {
    typedef ReYogaBaseService super;
    OSDeclareDefaultStructors(ReYogaVPC);

private:
    static constexpr const char *getClamshellMode = "GCSM";
    static constexpr const char *setClamshellMode = "SCSM";
    static constexpr const char *setThermalControl = "DYTC";
    bool clamshellCap{false};
    bool updateClamshell(bool publish = true);
    bool toggleClamshell();
    bool dumpECOffset(UInt32 request);
    // A reentrancy guard, not a lock; hardware requests use commandGate.
    bool DYTCLock{false};
    bool DYTCCommand(DYTC_CMD command, DYTC_RESULT *result, UInt8 function = 0, UInt8 mode = 0, bool enabled = false);
    void initDYTC();
    bool parseDYTC(DYTC_RESULT result);
    OSDictionary *DYTCVersion{nullptr}; // Owned; released by exitVPC().
    void probeWMI();
    void backlightRest(OSObject *owner, IOTimerEventSource *timer);

protected:
    bool supportsThermalProfiles() const { return (DYTCCap & (BIT(DYTC_FUNCTION_MMC) | BIT(DYTC_FUNCTION_PSC))) != 0; }
    int pscThermalMode(UInt32 profile) const {
        return DYTCRevision >= 9 ? (profile == 1 ? 1 : profile == 2 ? 3
                                                                    : 4)
                                 : (profile == 1 ? 3 : profile == 2 ? 5
                                                                    : 7);
    }
    bool supportsMMCThermal() const { return (DYTCCap & BIT(DYTC_FUNCTION_MMC)) != 0; }
    bool evaluateNamedThermalMode(const char *name, UInt32 *out);

    // FCAP bits 16..31, indexed by the four-bit function ID.
    UInt16 DYTCCap{0};
    UInt8 DYTCRevision{0};
    bool mmcGetCap{false};
    UInt32 activeThermalProfile{2};
    IOACPIPlatformDevice *vpc{nullptr};       // Borrowed provider.
    OSOrderedSet *WMICollection{nullptr};     // Own retained service elements.
    OSOrderedSet *WMIProvCollection{nullptr}; // Own retained provider elements.
    bool clamshellMode{false};
    bool vendorWMISupport{false};

    virtual IOService *initWMI(WMI *) { return nullptr; }
    virtual bool examineWMI(IOService *) { return true; }
    virtual bool probeVPC(IOService *) { return true; }
    virtual void updateVPC(UInt32 event = 0) {}
    virtual bool initVPC();
    virtual bool exitVPC();
    virtual void updateAll();
    virtual void setPropertiesGated(OSObject *properties);
    void setPropertyGated(const char *key, OSObject *rawValue);
    virtual IOReturn accessPlatformFan(UInt32 fan, UInt32 request, UInt8 output[3]);
    virtual IOReturn accessPlatformFanCurve(UInt32 fan, UInt32 request, UInt8 output[3]);
    virtual IOReturn readPlatformFanRPM(UInt32 fan, UInt32 &rpm, UInt8 *control);
    virtual void restorePlatformFans() {}
    virtual void initPlatformControls() {}
    virtual void exitPlatformControls() {}
    virtual void exportACPITables();

    // Policy bits: sleep backlight, convertible backlight, _SST, mute, mic mute.
    UInt32 automaticBacklightMode{0x17};
    bool backlightCap{false};
    UInt32 backlightLevel{0};
    UInt32 backlightLevelSaved{0};
    bool backlightAutomaticOff{false};
    UInt32 backlightTimeout{0};
    static constexpr UInt32 maximumBacklightTimeoutSeconds = 3600;
    UInt64 backlightStimulation{0};
    IOTimerEventSource *backlightPoller{nullptr}; // Owned event source.
    virtual bool updateBacklight(bool logChanges = false) { return false; }
    virtual bool setBacklight(UInt32 level) { return false; }
    bool setUserBacklight(UInt32 level);
    void rememberBacklight(UInt32 level);
    void stimulateBacklight();
    IOReturn setBacklightPowerState(unsigned long state, IOService *device);
    bool FnlockMode{false};
    virtual bool updateFnLock(bool logChanges = false) { return false; }
    virtual bool setFnLock(bool enabled) { return false; }
    bool notifyBattery();
    bool updateDYTC();
    bool setDYTC(int function, int mode);
    bool setThermalProfile(UInt32 profile);
    IOReturn evaluateIntegerParam(const char *method, UInt32 *result, UInt32 argument);

public:
    IOService *probe(IOService *provider, SInt32 *score) APPLE_KEXT_OVERRIDE;
    bool start(IOService *provider) APPLE_KEXT_OVERRIDE;
    void stop(IOService *provider) APPLE_KEXT_OVERRIDE;
    void free() APPLE_KEXT_OVERRIDE;
    IOReturn setProperties(OSObject *properties) APPLE_KEXT_OVERRIDE;
    IOReturn message(UInt32 type, IOService *provider, void *argument) APPLE_KEXT_OVERRIDE;
    IOReturn setPowerState(unsigned long state, IOService *device) APPLE_KEXT_OVERRIDE;

    ReYogaSMCUserClient *client{nullptr}; // Borrowed; cleared under commandGate.
    // Keep the user-client and ThinkSMC entry points; other families fail closed.
    IOReturn accessThinkFanCurve(UInt32 fan, UInt32 request, UInt8 output[3]);
    IOReturn accessThinkFan(UInt32 fan, UInt32 request, UInt8 output[3]);
    IOReturn readThinkFanRPM(UInt32 fan, UInt32 &rpm, UInt8 *control = nullptr);
    void restoreThinkFans();
    virtual void restoreUserControls() { restoreThinkFans(); }
};

#endif
