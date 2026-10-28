#include "ThinkSMC.hpp"
#include "SensorDescriptors.hpp"
#include "../ReYogaVPC.hpp"

OSDefineMetaClassAndStructors(ThinkSMC, ReYogaSMC);

void ThinkSMC::addVSMCKey() {
    VirtualSMCAPI::addKey(KeyFNum, vsmcPlugin.data, VirtualSMCAPI::valueWithUint8(dualFan ? 2 : 1, nullptr, SMC_KEY_ATTRIBUTE_CONST | SMC_KEY_ATTRIBUTE_READ));
    VirtualSMCAPI::addKey(KeyF0Ac(0), vsmcPlugin.data, VirtualSMCAPI::valueWithFp(0, SmcKeyTypeFpe2, new atomicFpKey(&currentSensor[ReYogaSensor::Fan1])));
    ++sensorCount;
    if (dualFan) {
        VirtualSMCAPI::addKey(KeyF0Ac(1), vsmcPlugin.data, VirtualSMCAPI::valueWithFp(0, SmcKeyTypeFpe2, new atomicFpKey(&currentSensor[ReYogaSensor::Fan2])));
        ++sensorCount;
    }
    setProperty("Dual fan", dualFan);
    super::addVSMCKey();
}

void ThinkSMC::updateECVendor() {
    for (unsigned fan = 0; fan < (dualFan ? 2U : 1U); ++fan) {
        UInt32 rpm = UINT32_MAX;
        const bool valid = sensorProvider && sensorProvider->readThinkFanRPM(fan, rpm) == kIOReturnSuccess;
        atomic_store_explicit(&currentSensor[fan], valid ? rpm : UINT32_MAX, memory_order_release);
        if (sensorProvider) {
            const char *property = fan == 0 ? "Fan1RPM" : "Fan2RPM";
            if (valid)
                sensorProvider->setProperty(property, rpm, 32);
            else
                sensorProvider->removeProperty(property);
        }
    }
}

void ThinkSMC::getWMISensor(IOService *provider) {
    sensorProvider = OSDynamicCast(ReYogaVPC, provider);
    dualFan = sensorProvider && sensorProvider->getProperty("Dual fan") == kOSBooleanTrue;
}
