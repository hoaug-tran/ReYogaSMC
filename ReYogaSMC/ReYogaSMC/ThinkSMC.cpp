//  SPDX-License-Identifier: GPL-2.0-only
//
//  ThinkSMC.cpp
//  ReYogaSMC
//
//  Created by Zhen on 8/30/20.
//  Copyright © 2020 Zhen. All rights reserved.
//

#include "ThinkSMC.hpp"
#include "../ReYogaVPC.hpp"

OSDefineMetaClassAndStructors(ThinkSMC, ReYogaSMC);

void ThinkSMC::addVSMCKey() {
    // Add message-based key

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
        UInt8 sample[3] = {};
        const bool valid = sensorProvider && sensorProvider->accessThinkFan(fan, 0x100, sample) == kIOReturnSuccess;
        const UInt32 rpm = valid ? static_cast<UInt32>(sample[0]) | static_cast<UInt32>(sample[1]) << 8 : UINT32_MAX;
        atomic_store_explicit(&currentSensor[fan], rpm, memory_order_release);
    }
}

void ThinkSMC::getWMISensor(IOService *provider) {
    sensorProvider = OSDynamicCast(ReYogaVPC, provider);
}
