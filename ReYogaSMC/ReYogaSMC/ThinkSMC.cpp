#include "ThinkSMC.hpp"
#include "../ReYogaVPC.hpp"

OSDefineMetaClassAndStructors(ThinkSMC, ReYogaSMC);

void ThinkSMC::addVSMCKey() {
    VirtualSMCAPI::addKey(KeyFNum, vsmcPlugin.data, VirtualSMCAPI::valueWithUint8(dualFan ? 2 : 1, nullptr, SMC_KEY_ATTRIBUTE_CONST | SMC_KEY_ATTRIBUTE_READ));
    VirtualSMCAPI::addKey(KeyF0Ac(0), vsmcPlugin.data, VirtualSMCAPI::valueWithFp(0, SmcKeyTypeFpe2, new atomicFpKey(&currentSensor[0])));
    ++sensorCount;
    if (dualFan) {
        VirtualSMCAPI::addKey(KeyF0Ac(1), vsmcPlugin.data, VirtualSMCAPI::valueWithFp(0, SmcKeyTypeFpe2, new atomicFpKey(&currentSensor[1])));
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
        if (sensorProvider && valid)
            sensorProvider->setProperty(fan == 0 ? "Fan1RPM" : "Fan2RPM", rpm, 32);
    }
}

void ThinkSMC::getWMISensor(IOService *provider) {
    sensorProvider = OSDynamicCast(ReYogaVPC, provider);
}

