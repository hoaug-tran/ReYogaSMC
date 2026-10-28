//
//  ReYogaSMC.cpp
//  ReYogaSMC
//
//  Created by Zhen on 7/29/20.
//  Copyright © 2020 Zhen. All rights reserved.
//

#include "ReYogaSMC.hpp"

OSDefineMetaClassAndStructors(ReYogaSMC, ReYogaBaseService);

bool ADDPR(debugEnabled) = false;
uint32_t ADDPR(debugPrintDelay) = 0;

static const struct sensorPair presetTemperatureDeciKelvin[] = {
    {KeyTB0T(0), "Battery"},
    {KeyTB0T(1), "Battery Sensor 1"},
    {KeyTB0T(2), "Battery Sensor 2"}};

static const struct sensorPair presetTemperature[] = {
    {KeyTCSA, "CPU System Agent Core"},
    {KeyTCXC, "CPU Core PECI"},
    // Laptops only have 1 key for both channel
    {KeyTM0P, "Memory Proximity"},
    // Desktops
    {KeyTM0p(0), "SO-DIMM 1 Proximity"},
    {KeyTM0p(1), "SO-DIMM 2 Proximity"},
    {KeyTM0p(2), "SO-DIMM 3 Proximity"},
    {KeyTM0p(3), "SO-DIMM 4 Proximity"},
    {KeyTPCD, "Platform Controller Hub Die"},
    {KeyTW0P, "Airport Proximity"},
    {KeyTaLC, "Airflow Left"},
    {KeyTaRC, "Airflow Right"},
    {KeyTh0H(1), "Fin Stack Proximity Right"},
    {KeyTh0H(2), "Fin Stack Proximity Left"},
    {KeyTs0P(0), "Palm Rest"},
    {KeyTs0P(1), "Trackpad Actuator"}};

void ReYogaSMC::addVSMCKey() {
    // ACPI-based
    if (!conf || !ec)
        return;

    ECSensorBase = sensorCount;

    OSDictionary *status = OSDictionary::withCapacity(1);
    if (!status)
        return;

    for (auto &pair : presetTemperatureDeciKelvin)
        addECKeySp<atomicSpDeciKelvinKey>(pair.key, pair.name, status);

    for (auto &pair : presetTemperature)
        addECKeySp<atomicSpKey>(pair.key, pair.name, status);

    setProperty("DirectECKey", status);
    status->release();
}

bool ReYogaSMC::start(IOService *provider) {
    atomic_init(&pluginSubmitted, false);
    isPMsupported = true;

    if (!super::start(provider))
        return false;

    DebugLog("Starting");

    validateEC();

    poller = IOTimerEventSource::timerEventSource(this, [](OSObject *object, IOTimerEventSource *sender) {
        auto smc = OSDynamicCast(ReYogaSMC, object);
        if (smc)
            smc->updateEC();
    });

    if (!poller || (workLoop->addEventSource(poller) != kIOReturnSuccess)) {
        AlwaysLog("Failed to add poller");
        OSSafeReleaseNULL(poller);
        super::stop(provider);
        return false;
    }

    for (auto &reading : currentSensor)
        atomic_init(&reading, UINT32_MAX);
    addVSMCKey();
    qsort(const_cast<VirtualSMCKeyValue *>(vsmcPlugin.data.data()), vsmcPlugin.data.size(), sizeof(VirtualSMCKeyValue), VirtualSMCKeyValue::compare);
    setProperty("Key Submitted", vsmcPlugin.data.size(), 32);
    vsmcNotifier = VirtualSMCAPI::registerHandler(vsmcNotificationHandler, this);
    if (!vsmcNotifier) {
        workLoop->removeEventSource(poller);
        OSSafeReleaseNULL(poller);
        super::stop(provider);
        return false;
    }

    awake = true;
    ready = true;
    poller->setTimeoutMS(POLLING_INTERVAL);
    poller->enable();
    registerService();
    return true;
}

void ReYogaSMC::stop(IOService *provider) {
    DebugLog("Stopping");

    if (vsmcNotifier) {
        // IONotifier::remove synchronously drains handlers and releases registration.
        vsmcNotifier->remove();
        vsmcNotifier = nullptr;
    }
    if (commandGate)
        commandGate->runAction([](OSObject *owner, void *, void *, void *, void *) -> IOReturn {
            auto self = OSDynamicCast(ReYogaSMC, owner);
            if (self) {
                self->awake = false;
                self->ready = false;
            }
            return kIOReturnSuccess;
        });

    if (poller) {
        poller->cancelTimeout();
        poller->disable();
        if (workLoop)
            workLoop->removeEventSource(poller);
        OSSafeReleaseNULL(poller);
    }

    terminate();

    super::stop(provider);
}

bool ReYogaSMC::vsmcNotificationHandler(void *sensors, void *refCon, IOService *vsmc, IONotifier *notifier) {
    auto self = OSDynamicCast(ReYogaSMC, reinterpret_cast<OSMetaClassBase *>(sensors));
    if (self && vsmc) {
        DBGLOG("reyogasmc", "got vsmc notification");
        auto &plugin = self->vsmcPlugin;
        auto ret = vsmc->callPlatformFunction(VirtualSMCAPI::SubmitPlugin, true, sensors, &plugin, nullptr, nullptr);
        if (ret == kIOReturnSuccess) {
            // VirtualSMC's SDK requires submitted plugin storage for the kernel lifetime.
            if (!atomic_exchange_explicit(&self->pluginSubmitted, true, memory_order_acq_rel))
                self->retain();
            DBGLOG("reyogasmc", "submitted plugin");
            return true;
        } else if (ret != kIOReturnUnsupported) {
            SYSLOG("reyogasmc", "plugin submission failure %X", ret);
        } else {
            DBGLOG("reyogasmc", "plugin submission to non vsmc");
        }
    } else {
        SYSLOG("reyogasmc", "got null vsmc notification");
    }
    return false;
}

IOService *ReYogaSMC::probe(IOService *provider, SInt32 *score) {
    // The sensor personality must not reactivate EC reads in VPC safe mode.
    if (provider->getProperty("SafeMode") == kOSBooleanTrue)
        return nullptr;
    ec = OSDynamicCast(IOACPIPlatformDevice, provider->getProperty("ECDevice"));
    if (!ec) {
        DebugLog("EC not found");
        return nullptr;
    }
    iname = ec->getName();

    conf = OSDynamicCast(OSDictionary, getProperty("Sensors"));
    if (!conf) {
        DebugLog("conf not found");
        return nullptr;
    }
    getWMISensor(provider);
    return this;
}

void ReYogaSMC::updateEC() {
    if (!awake)
        return;

    updateECVendor();

    UInt32 result = 0;
    for (UInt8 i = ECSensorBase; i < sensorCount; i++) {
        const bool valid = ec && ec->evaluateInteger(sensorMethods[i], &result) == kIOReturnSuccess && result != 0;
        atomic_store_explicit(&currentSensor[i], valid ? result : 0, memory_order_release);
    }
    poller->setTimeoutMS(POLLING_INTERVAL);
}

IOReturn ReYogaSMC::setPowerState(unsigned long powerStateOrdinal, IOService *whatDevice) {
    if (!commandGate)
        return kIOPMAckImplied;
    return commandGate->runAction([](OSObject *owner, void *ordinal, void *device, void *, void *) -> IOReturn {
        return static_cast<ReYogaSMC *>(owner)->setPowerStateGated(*static_cast<unsigned long *>(ordinal), static_cast<IOService *>(device));
    }, &powerStateOrdinal, whatDevice);
}

IOReturn ReYogaSMC::setPowerStateGated(unsigned long powerStateOrdinal, IOService *whatDevice) {
    if (stopping)
        return kIOPMAckImplied;
    if (super::setPowerState(powerStateOrdinal, whatDevice) != kIOPMAckImplied)
        return kIOReturnInvalid;

    if (!poller)
        return kIOPMAckImplied;
    if (powerStateOrdinal == 0) {
        if (awake) {
            poller->disable();
            workLoop->removeEventSource(poller);
            awake = false;
            DebugLog("Going to sleep");
        }
    } else {
        if (!awake && ready) {
            awake = true;
            workLoop->addEventSource(poller);
            poller->setTimeoutMS(POLLING_INTERVAL);
            poller->enable();
            DebugLog("Woke up");
        }
    }
    return kIOPMAckImplied;
}

void ReYogaSMC::setPropertiesGated(OSObject *props) {
    OSDictionary *dict = OSDynamicCast(OSDictionary, props);
    if (!dict)
        return;

    OSCollectionIterator *i = OSCollectionIterator::withCollection(dict);

    if (i) {
        while (OSString *key = OSDynamicCast(OSString, i->getNextObject())) {
            if (key->isEqualTo(readECPrompt)) {
                if (!ec)
                    continue;
                auto value = ReYogaProperty::get<OSNumber>(dict, readECPrompt);
                if (!value) {
                    AlwaysLog(valueInvalid, readECPrompt);
                    continue;
                }
                if (value->unsigned8BitValue() >= sensorCount) {
                    AlwaysLog(valueInvalid, readECPrompt);
                    continue;
                }
                uint32_t raw = atomic_load_explicit(&currentSensor[value->unsigned8BitValue()], memory_order_acquire);
                AlwaysLog(updateSuccess, readECPrompt, raw);
            } else {
                AlwaysLog("Unknown property %s", key->getCStringNoCopy());
            }
        }
        i->release();
    }

    return;
}

IOReturn ReYogaSMC::setProperties(OSObject *props) {
    if (!commandGate)
        return kIOReturnNotReady;
    if (!OSDynamicCast(OSDictionary, props))
        return kIOReturnBadArgument;
    return commandGate->runAction([](OSObject *owner, void *properties, void *, void *, void *) -> IOReturn {
        auto self = static_cast<ReYogaSMC *>(owner);
        if (self->stopping || self->isInactive())
            return kIOReturnNotAttached;
        self->setPropertiesGated(static_cast<OSObject *>(properties));
        return kIOReturnSuccess;
    },
                                  props);
}

EXPORT extern "C" kern_return_t ADDPR(kern_start)(kmod_info_t *, void *) {
    // Report success but actually do not start and let I/O Kit unload us.
    // This works better and increases boot speed in some cases.
    PE_parse_boot_argn("liludelay", &ADDPR(debugPrintDelay), sizeof(ADDPR(debugPrintDelay)));
    ADDPR(debugEnabled) = checkKernelArgument("-vsmcdbg");
    return KERN_SUCCESS;
}

EXPORT extern "C" kern_return_t ADDPR(kern_stop)(kmod_info_t *, void *) {
    // It is not safe to unload VirtualSMC plugins!
    return KERN_FAILURE;
}
