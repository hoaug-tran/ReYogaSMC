//
//  ReYogaSMC.hpp
//  ReYogaSMC
//
//  Created by Zhen on 7/29/20.
//  Copyright © 2020 Zhen. All rights reserved.
//

#ifndef ReYogaSMC_hpp
#define ReYogaSMC_hpp

#include <VirtualSMCSDK/kern_vsmcapi.hpp>
#include "KeyImplementations.hpp"
#include "ReYogaBaseService.hpp"

#define MAX_SENSOR 0x10
#define POLLING_INTERVAL 2000

class ReYogaSMC : public ReYogaBaseService {
    typedef ReYogaBaseService super;
OSDeclareDefaultStructors(ReYogaSMC)

    protected : bool awake { false };
    bool ready{false};

    IOTimerEventSource *poller{nullptr};

    /**
     *  VirtualSMC service registration notifier
     */
    IONotifier *vsmcNotifier{nullptr};
    _Atomic(bool) pluginSubmitted;

    /**
     *  Registered plugin instance
     */
    VirtualSMCAPI::Plugin vsmcPlugin{
        xStringify(PRODUCT_NAME),
        parseModuleVersion(xStringify(MODULE_VERSION)),
        VirtualSMCAPI::Version,
    };

    /**
     *  Sensors configuration
     */
    OSDictionary *conf{nullptr};

    /**
     *  Add available SMC keys
     */
    virtual void addVSMCKey();

    /**
     *  ACPI method for sensors
     */
    const char *sensorMethods[MAX_SENSOR];

    /**
     *  Enabled sensor count
     */
    UInt8 sensorCount{0};

    /**
     *  EC sensor base
     */
    UInt8 ECSensorBase{0};

    /**
     *  Current sensor reading obtained from ACPI
     */
    _Atomic(uint32_t) currentSensor[MAX_SENSOR];

    template <typename SensorValue>
    void addECKeySp(SMC_KEY key, const char *name, OSDictionary *status) {
        if (sensorCount >= MAX_SENSOR)
            return;
        auto method = OSDynamicCast(OSString, conf->getObject(name));
        if (!method || method->getLength() != 4)
            return;
        if (ec->validateObject(method->getCStringNoCopy()) != kIOReturnSuccess) {
            status->setObject(name, kOSBooleanFalse);
            return;
        }
        atomic_init(&currentSensor[sensorCount], 0);
        VirtualSMCAPI::addKey(key, vsmcPlugin.data,
                              VirtualSMCAPI::valueWithSp(0, SmcKeyTypeSp78, new SensorValue(&currentSensor[sensorCount])));
        sensorMethods[sensorCount++] = method->getCStringNoCopy();
        status->setObject(name, kOSBooleanTrue);
    }

    /**
     *  Poll EC field for sensor data
     */
    void updateEC();
    virtual inline void updateECVendor() {};

    virtual void setPropertiesGated(OSObject *props);
    IOReturn setPowerStateGated(unsigned long state, IOService *device);

    inline virtual void getWMISensor(IOService *provider) {};

public:
    virtual IOService *probe(IOService *provider, SInt32 *score) APPLE_KEXT_OVERRIDE;
    virtual bool start(IOService *provider) APPLE_KEXT_OVERRIDE;
    virtual void stop(IOService *provider) APPLE_KEXT_OVERRIDE;

    virtual IOReturn setPowerState(unsigned long powerStateOrdinal, IOService *whatDevice) APPLE_KEXT_OVERRIDE;
    virtual IOReturn setProperties(OSObject *props) APPLE_KEXT_OVERRIDE;

    /**
     *  Submit the keys to received VirtualSMC service.
     *
     *  @param sensors   SMCBatteryManager service
     *  @param refCon    reference
     *  @param vsmc      VirtualSMC service
     *  @param notifier  created notifier
     */
    static bool vsmcNotificationHandler(void *sensors, void *refCon, IOService *vsmc, IONotifier *notifier);
};

#endif /* ReYogaSMC_hpp */
