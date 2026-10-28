//  SPDX-License-Identifier: GPL-2.0-only
//
//  ReYogaVPC.cpp
//  ReYogaSMC
//
//  Created by Zhen on 2020/7/10.
//  Copyright © 2020 Zhen. All rights reserved.
//

#include "ReYogaVPC.hpp"
#include "ControlValidation.hpp"
#include <libkern/crypto/sha2.h>
#include <pexpert/pexpert.h>

OSDefineMetaClassAndStructors(ReYogaVPC, ReYogaBaseService);

IOService *ReYogaVPC::probe(IOService *provider, SInt32 *score) {
    if (!super::probe(provider, score))
        return nullptr;

    if (!probeVPC(provider))
        return nullptr;

    DebugLog("Probing");

    if (!(vpc = OSDynamicCast(IOACPIPlatformDevice, provider)))
        return nullptr;

    if ((ec = OSDynamicCast(IOACPIPlatformDevice, vpc->getParentEntry(gIOACPIPlane)))) {
        DebugLog("Parent ACPI device: %s", ec->getName());
    }

    if (!findPNP(PnpDeviceIdEC, &ec)) {
        AlwaysLog("Failed to find EC");
        return nullptr;
    }

    setProperty("ECDevice", ec);
    isPMsupported = true;

    int isolationArgument = 0;
    if (PE_parse_boot_argn("-reysafe", &isolationArgument, sizeof(isolationArgument))) {
        setProperty("SafeMode", true);
        setProperty("SafeModeReason", "-reysafe: ACPI, EC and WMI hardware access disabled");
        vendorWMISupport = false;
    }
    if (vendorWMISupport)
        probeWMI();

    return this;
}

void ReYogaVPC::probeWMI() {
    auto iterator = IORegistryIterator::iterateOver(gIOACPIPlane, kIORegistryIterateRecursively);
    if (!iterator) {
        AlwaysLog("findWMI failed");
        return;
    }

    auto pnp = OSString::withCString(PnpDeviceIdWMI);
    IOACPIPlatformDevice *dev;
    WMICollection = OSOrderedSet::withCapacity(1);
    WMIProvCollection = OSOrderedSet::withCapacity(1);
    if (!pnp || !WMICollection || !WMIProvCollection) {
        OSSafeReleaseNULL(pnp);
        OSSafeReleaseNULL(WMICollection);
        OSSafeReleaseNULL(WMIProvCollection);
        iterator->release();
        return;
    }

    while (auto entry = iterator->getNextObject()) {
        if (entry->compareName(pnp) && (dev = OSDynamicCast(IOACPIPlatformDevice, entry))) {
            if (dev == vpc) {
                DebugLog("Skip VPC interface");
                continue;
            }

            WMI *candidate = new WMI(dev);
            AlwaysLog("Boot stage: reading WMI descriptors from %s", dev->getName());
            if (!candidate || !candidate->initialize()) {
                delete candidate;
                continue;
            }
            AlwaysLog("Boot stage: WMI descriptors read from %s", dev->getName());
            if (candidate->hasMethod(TBT_WMI_GUID)) {
                DebugLog("Skip Thunderbolt interface");
                delete candidate;
                continue;
            }

            if (auto wmi = initWMI(candidate)) {
                DebugLog("WMI available at %s", dev->getName());
                if (!WMICollection->setObject(wmi)) {
                    AlwaysLog("Failed to retain WMI service");
                } else if (!WMIProvCollection->setObject(dev)) {
                    WMICollection->removeObject(wmi);
                    AlwaysLog("Failed to retain WMI provider");
                }
                wmi->release();
            } else {
                DebugLog("WMI init failed at %s", dev->getName());
                delete candidate;
            }
        }
    }

    if (WMICollection->getCount() == 0) {
        OSSafeReleaseNULL(WMICollection);
        OSSafeReleaseNULL(WMIProvCollection);
    } else {
        setProperty("ReYogaWMISupported", true);
    }

    iterator->release();
    pnp->release();
}

bool ReYogaVPC::start(IOService *provider) {
    if (!super::start(provider))
        return false;
    DebugLog("Starting");

    const bool safeMode = getProperty("SafeMode") == kOSBooleanTrue;
    AlwaysLog("Boot stage: initializing VPC");
    if (!safeMode && !initVPC()) {
        commandGate->runAction([](OSObject *owner, void *, void *, void *, void *) -> IOReturn {
            auto self = static_cast<ReYogaVPC *>(owner);
            self->stopping = true;
            self->exitVPC();
            return kIOReturnSuccess;
        });
        super::stop(provider);
        return false;
    }
    if (safeMode)
        setProperty("ControlProtocolVersion", 1, 32);
    AlwaysLog("Boot stage: VPC initialized");

    if (!safeMode) {
        AlwaysLog("Boot stage: validating EC sensor access");
        validateEC();
        AlwaysLog("Boot stage: EC sensor access validated");
    }
    setProperty("ACPIExportVersion", 1, 32);
    if (!safeMode && !getProperty("FirmwareDSDTSHA256")) {
        const auto table = vpc->getACPITableData("DSDT", 0);
        if (table && table->getLength() >= 36 && table->getLength() <= 1024 * 1024) {
            SHA256_CTX context;
            UInt8 digest[SHA256_DIGEST_LENGTH];
            SHA256_Init(&context);
            SHA256_Update(&context, table->getBytesNoCopy(), table->getLength());
            SHA256_Final(digest, &context);
            char hex[SHA256_DIGEST_STRING_LENGTH] = {};
            for (unsigned i = 0; i < sizeof(digest); ++i)
                snprintf(hex + i * 2, sizeof(hex) - i * 2, "%02x", digest[i]);
            setProperty("FirmwareDSDTSHA256", hex);
        }
    }

    if (!safeMode) {
        AlwaysLog("Boot stage: initial firmware state refresh");
        updateAll();
        AlwaysLog("Boot stage: initial firmware state refreshed");
    }

    if (!safeMode && WMICollection) {
        for (int i = WMICollection->getCount() - 1; i >= 0; i--) {
            IOService *wmi = OSDynamicCast(IOService, WMICollection->getObject(i));
            IOService *prov = OSDynamicCast(IOService, WMIProvCollection->getObject(i));
            if (!wmi || !prov) {
                AlwaysLog("Invalid WMI service/provider pair");
                continue;
            }
            AlwaysLog("Boot stage: attaching WMI provider %s", prov->getName());
            if (!wmi->attach(prov)) {
                AlwaysLog("Failed to attach WMI instance on %s", prov->getName());
                WMICollection->removeObject(wmi);
                WMIProvCollection->removeObject(prov);
            } else if (!wmi->start(prov)) {
                wmi->detach(prov);
                AlwaysLog("Failed to start WMI instance on %s", prov->getName());
                WMICollection->removeObject(wmi);
                WMIProvCollection->removeObject(prov);
            } else {
                examineWMI(wmi);
                AlwaysLog("Boot stage: WMI provider %s ready", prov->getName());
            }
        }
    }
    setProperty(kDeliverNotifications, kOSBooleanTrue);
    registerService();
    AlwaysLog("Boot stage: VPC service published (safe=%d)", safeMode);
    return true;
}

bool ReYogaVPC::initVPC() {
    if (vpc->validateObject(getClamshellMode) == kIOReturnSuccess &&
        vpc->validateObject(setClamshellMode) == kIOReturnSuccess)
        clamshellCap = true;

    if (vpc->validateObject(setThermalControl) == kIOReturnSuccess)
        initDYTC();

    initPlatformControls();

    backlightPoller = IOTimerEventSource::timerEventSource(this, OSMemberFunctionCast(IOTimerEventSource::Action, this, &ReYogaVPC::backlightRest));
    if (!backlightPoller ||
        workLoop->addEventSource(backlightPoller) != kIOReturnSuccess) {
        AlwaysLog("Failed to add brightnessPoller");
        OSSafeReleaseNULL(backlightPoller);
    } else {
        backlightPoller->enable();
        setProperty(backlightTimeoutPrompt, backlightTimeout, 32);
        DebugLog("BrightnessPoller enabled");
    }

    return true;
}

bool ReYogaVPC::exitVPC() {
    exitPlatformControls();
    if (backlightPoller) {
        backlightPoller->cancelTimeout();
        backlightPoller->disable();
        workLoop->removeEventSource(backlightPoller);
    }
    OSSafeReleaseNULL(backlightPoller);

    if (clamshellMode) {
        AlwaysLog("Disabling clamshell mode");
        toggleClamshell();
    }

    OSSafeReleaseNULL(DYTCVersion);

    return true;
}

void ReYogaVPC::stop(IOService *provider) {
    DebugLog("Stopping");
    if (commandGate)
        commandGate->runAction([](OSObject *owner, void *, void *, void *, void *) -> IOReturn {
            auto self = static_cast<ReYogaVPC *>(owner);
            if (self->stopping)
                return kIOReturnSuccess;
            self->stopping = true;
            if (self->getProperty("SafeMode") != kOSBooleanTrue) {
                self->restoreThinkFans();
                self->exitVPC();
            }
            return kIOReturnSuccess;
        });
    if (WMICollection) {
        for (int i = WMICollection->getCount() - 1; i >= 0; i--) {
            IOService *wmi = OSDynamicCast(IOService, WMICollection->getObject(i));
            IOService *prov = OSDynamicCast(IOService, WMIProvCollection->getObject(i));
            if (wmi && prov) {
                wmi->stop(prov);
                wmi->detach(prov);
            }
        }
        OSSafeReleaseNULL(WMICollection);
        OSSafeReleaseNULL(WMIProvCollection);
    }

    super::stop(provider);
}

void ReYogaVPC::free() {
    OSSafeReleaseNULL(WMICollection);
    OSSafeReleaseNULL(WMIProvCollection);
    OSSafeReleaseNULL(DYTCVersion);
    super::free();
}

void ReYogaVPC::updateAll() {
    updateBacklight();
    updateClamshell();
    if (!updateDYTC())
        AlwaysLog("Update DYTC failed");
}

bool ReYogaVPC::notifyBattery() {
    if (ec->validateObject("NBAT") == kIOReturnSuccess &&
        ec->evaluateObject("NBAT") != kIOReturnSuccess) {
        DebugLog(toggleFailure, "NBAT");
        return false;
    }
    return true;
}

IOReturn ReYogaVPC::setPowerState(unsigned long powerStateOrdinal, IOService *whatDevice) {
    if (!commandGate)
        return kIOPMAckImplied;
    return commandGate->runAction([](OSObject *owner, void *ordinal, void *device, void *, void *) -> IOReturn {
        return static_cast<ReYogaVPC *>(owner)->setBacklightPowerState(*static_cast<unsigned long *>(ordinal), static_cast<IOService *>(device));
    }, &powerStateOrdinal, whatDevice);
}

IOReturn ReYogaVPC::setBacklightPowerState(unsigned long powerStateOrdinal, IOService *whatDevice) {
    if (stopping)
        return kIOPMAckImplied;
    if (getProperty("SafeMode") == kOSBooleanTrue)
        return kIOPMAckImplied;
    if (super::setPowerState(powerStateOrdinal, whatDevice) != kIOPMAckImplied)
        return kIOReturnInvalid;

    if (!backlightCap)
        return kIOPMAckImplied;

    if (automaticBacklightMode & BIT(0) || backlightTimeout != 0) {
        updateBacklight();
        if (powerStateOrdinal == 0) {
            if (backlightTimeout != 0 && backlightPoller)
                backlightPoller->cancelTimeout();
            else
                backlightLevelSaved = backlightLevel;
            if (backlightLevel)
                backlightAutomaticOff = setBacklight(0);
        } else {
            if (!backlightLevel && backlightLevelSaved && setBacklight(backlightLevelSaved))
                backlightAutomaticOff = false;
            if (backlightTimeout != 0 && backlightPoller)
                backlightPoller->setTimeout(backlightTimeout, kSecondScale);
        }
    }

    return kIOPMAckImplied;
}

void ReYogaVPC::rememberBacklight(UInt32 level) {
    if (backlightAutomaticOff && !level)
        return;
    backlightAutomaticOff = false;
    backlightLevelSaved = level;
    if (backlightPoller) {
        backlightPoller->cancelTimeout();
        if (backlightTimeout && level)
            backlightPoller->setTimeout(backlightTimeout, kSecondScale);
    }
}

bool ReYogaVPC::setUserBacklight(UInt32 level) {
    if (level > 2 || !backlightCap || !setBacklight(level))
        return false;
    backlightAutomaticOff = false;
    rememberBacklight(level);
    return true;
}

void ReYogaVPC::backlightRest(OSObject *owner, IOTimerEventSource *timer) {
    if (stopping || !backlightTimeout || !backlightLevel)
        return;
    DebugLog("backlight %x saved %x", backlightLevel, backlightLevelSaved);
    backlightLevelSaved = backlightLevel;
    clock_get_uptime(&backlightStimulation);
    backlightAutomaticOff = setBacklight(0);
}

IOReturn ReYogaVPC::message(UInt32 type, IOService *provider, void *argument) {
    if (getProperty("SafeMode") == kOSBooleanTrue)
        return kIOReturnUnsupported;
    switch (type) {
    case kSMC_setDisableTouchpad:
    case kSMC_getDisableTouchpad:
    case kPS2M_notifyKeyTime:
    case kPS2M_resetTouchpad:
    case kSMC_setKeyboardStatus:
    case kSMC_getKeyboardStatus:
    case kSMC_notifyKeystroke:
        break;

    case kPS2M_notifyKeyPressed:
        if (commandGate)
            commandGate->runAction([](OSObject *owner, void *, void *, void *, void *) -> IOReturn {
                static_cast<ReYogaVPC *>(owner)->stimulateBacklight();
                return kIOReturnSuccess;
            });
        break;

    case kIOACPIMessageDeviceNotification:
        if (!argument)
            AlwaysLog("message: Unknown ACPI notification");
        else
            AlwaysLog("message: Unknown ACPI notification 0x%04x", *(reinterpret_cast<UInt32 *>(argument)));
        break;

    default:
        if (argument)
            AlwaysLog("message: type=%x, provider=%s, argument=0x%04x", type, provider->getName(), *(reinterpret_cast<UInt32 *>(argument)));
        else
            AlwaysLog("message: type=%x, provider=%s", type, provider->getName());
    }

    return kIOReturnSuccess;
}

void ReYogaVPC::stimulateBacklight() {
    if (stopping || !backlightPoller || !backlightTimeout || !backlightLevelSaved)
        return;
    backlightPoller->cancelTimeout();
    if (!backlightLevel) {
        clock_get_uptime(&backlightStimulation);
        if (setBacklight(backlightLevelSaved))
            backlightAutomaticOff = false;
    }
    backlightPoller->setTimeout(backlightTimeout, kSecondScale);
}

IOReturn ReYogaVPC::evaluateIntegerParam(const char *objectName, UInt32 *resultInt32, UInt32 paramInt32) {
    IOReturn ret;
    if (!vpc || !objectName)
        return kIOReturnBadArgument;
    OSObject *params[] = {OSNumber::withNumber(paramInt32, 32)};
    if (!params[0])
        return kIOReturnNoMemory;
    if (resultInt32 != nullptr) {
        ret = vpc->evaluateInteger(objectName, resultInt32, params, 1);
    } else {
        ret = vpc->evaluateObject(objectName, nullptr, params, 1);
    }
    params[0]->release();
    return ret;
}

// Preserve public entry points used by the user client and ThinkSMC.
IOReturn ReYogaVPC::accessThinkFan(UInt32 fan, UInt32 request, UInt8 output[3]) {
    return accessPlatformFan(fan, request, output);
}

IOReturn ReYogaVPC::accessThinkFanCurve(UInt32 fan, UInt32 request, UInt8 output[3]) {
    return accessPlatformFanCurve(fan, request, output);
}

IOReturn ReYogaVPC::readThinkFanRPM(UInt32 fan, UInt32 &rpm, UInt8 *control) {
    return readPlatformFanRPM(fan, rpm, control);
}

void ReYogaVPC::restoreThinkFans() {
    restorePlatformFans();
}

// Unsupported by default; ThinkVPC owns EC selectors and recovery state.
IOReturn ReYogaVPC::accessPlatformFan(UInt32, UInt32, UInt8[3]) {
    return kIOReturnUnsupported;
}

IOReturn ReYogaVPC::accessPlatformFanCurve(UInt32, UInt32, UInt8[3]) {
    return kIOReturnUnsupported;
}

IOReturn ReYogaVPC::readPlatformFanRPM(UInt32, UInt32 &, UInt8 *control) {
    if (control)
        *control = 0xff;
    return kIOReturnUnsupported;
}
