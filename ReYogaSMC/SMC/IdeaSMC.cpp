//  SPDX-License-Identifier: GPL-2.0-only
//
//  IdeaSMC.cpp
//  ReYogaSMC
//
//  Created by Zhen on 8/25/20.
//  Copyright © 2020 Zhen. All rights reserved.
//

#include "IdeaSMC.hpp"
#include "SensorDescriptors.hpp"
OSDefineMetaClassAndStructors(IdeaSMC, ReYogaSMC);

void IdeaSMC::addVSMCKey() {
    if (sensorProvider) {
        auto state = OSDynamicCast(OSBoolean, sensorProvider->getProperty("ConservationMode"));
        auto features = OSDynamicCast(OSDictionary, sensorProvider->getProperty("FeatureStatus"));
        auto feature = features ? OSDynamicCast(OSDictionary, features->getObject("ConservationMode")) : nullptr;
        if (state && feature && feature->getObject("Available") == kOSBooleanTrue)
            VirtualSMCAPI::addKey(KeyBDVT, vsmcPlugin.data, VirtualSMCAPI::valueWithFlag(state->getValue(), new BDVT(this), SMC_KEY_ATTRIBUTE_READ | SMC_KEY_ATTRIBUTE_WRITE));
    }

    char bootArgument[16];
    if (!wmig || PE_parse_boot_argn("-reynosmc", bootArgument, sizeof(bootArgument)) ||
        PE_parse_boot_argn("-reynosensors", bootArgument, sizeof(bootArgument))) {
        super::addVSMCKey();
        return;
    }

    UInt32 value;
    if (wmig->hasFanMethod) {
        UInt8 exportedFans = 0;
        for (UInt32 fan = 0; fan < wmig->fanCount && sensorCount < MAX_SENSOR - 2; ++fan) {
            VirtualSMCAPI::addKey(KeyF0Ac(fan), vsmcPlugin.data, VirtualSMCAPI::valueWithFp(0, SmcKeyTypeFpe2, new atomicFpKey(&currentSensor[sensorCount])));
            sensorIndex[sensorCount++] = FanMethodBase + fan;
            ++exportedFans;
        }
        if (exportedFans)
            VirtualSMCAPI::addKey(KeyFNum, vsmcPlugin.data, VirtualSMCAPI::valueWithUint8(exportedFans, nullptr, SMC_KEY_ATTRIBUTE_CONST | SMC_KEY_ATTRIBUTE_READ));

        VirtualSMCAPI::addKey(KeyTCXC, vsmcPlugin.data, VirtualSMCAPI::valueWithSp(0, SmcKeyTypeSp78, new atomicSpKey(&currentSensor[sensorCount])));
        sensorIndex[sensorCount++] = CPUTemperatureMethod;

        VirtualSMCAPI::addKey(KeyTCGC, vsmcPlugin.data, VirtualSMCAPI::valueWithSp(0, SmcKeyTypeSp78, new atomicSpKey(&currentSensor[sensorCount])));
        sensorIndex[sensorCount++] = GPUTemperatureMethod;
    } else {
        if (wmig->getGameZoneData(GAME_ZONE_WMI_GET_FAN_NUM, &value) && value) {
            VirtualSMCAPI::addKey(KeyF0Ac(0), vsmcPlugin.data, VirtualSMCAPI::valueWithFp(0, SmcKeyTypeFpe2, new atomicFpKey(&currentSensor[sensorCount])));
            sensorIndex[sensorCount++] = GAME_ZONE_WMI_GET_FAN_ONE;

            if (value > 1) {
                VirtualSMCAPI::addKey(KeyF0Ac(1), vsmcPlugin.data, VirtualSMCAPI::valueWithFp(0, SmcKeyTypeFpe2, new atomicFpKey(&currentSensor[sensorCount])));
                sensorIndex[sensorCount++] = GAME_ZONE_WMI_GET_FAN_TWO;
            }

            VirtualSMCAPI::addKey(KeyFNum, vsmcPlugin.data, VirtualSMCAPI::valueWithUint8(sensorCount, nullptr, SMC_KEY_ATTRIBUTE_CONST | SMC_KEY_ATTRIBUTE_READ));

            if (wmig->getGameZoneData(GAME_ZONE_WMI_GET_FAN_MAX, &value)) {
                VirtualSMCAPI::addKey(KeyF0Mx(0), vsmcPlugin.data, VirtualSMCAPI::valueWithFp(value, SmcKeyTypeFpe2, nullptr, SMC_KEY_ATTRIBUTE_WRITE | SMC_KEY_ATTRIBUTE_READ));
                if (sensorCount == 2)
                    VirtualSMCAPI::addKey(KeyF0Mx(1), vsmcPlugin.data, VirtualSMCAPI::valueWithFp(value, SmcKeyTypeFpe2, nullptr, SMC_KEY_ATTRIBUTE_WRITE | SMC_KEY_ATTRIBUTE_READ));
            }
        }

        if (wmig->getGameZoneData(GAME_ZONE_WMI_GET_TMP_IR, &value) && value) {
            VirtualSMCAPI::addKey(KeyTPCD, vsmcPlugin.data, VirtualSMCAPI::valueWithSp(0, SmcKeyTypeSp78, new atomicSpKey(&currentSensor[sensorCount])));
            sensorIndex[sensorCount++] = GAME_ZONE_WMI_GET_TMP_IR;
        }

        if (wmig->getGameZoneData(GAME_ZONE_WMI_GET_TMP_CPU, &value) && value) {
            VirtualSMCAPI::addKey(KeyTCXC, vsmcPlugin.data, VirtualSMCAPI::valueWithSp(0, SmcKeyTypeSp78, new atomicSpKey(&currentSensor[sensorCount])));
            sensorIndex[sensorCount++] = GAME_ZONE_WMI_GET_TMP_CPU;
        }

        if (wmig->getGameZoneData(GAME_ZONE_WMI_GET_TMP_GPU, &value) && value) {
            VirtualSMCAPI::addKey(KeyTCGC, vsmcPlugin.data, VirtualSMCAPI::valueWithSp(0, SmcKeyTypeSp78, new atomicSpKey(&currentSensor[sensorCount])));
            sensorIndex[sensorCount++] = GAME_ZONE_WMI_GET_TMP_GPU;
        }
    }

    super::addVSMCKey();
}

void IdeaSMC::updateECVendor() {
    UInt32 value;
    for (UInt8 index = 0; index < ECSensorBase; ++index) {
        UInt8 code = sensorIndex[index];
        atomic_store_explicit(&currentSensor[index], UINT32_MAX, memory_order_release);
        // Reuse the VPC telemetry sample rather than querying the EC twice.
        if (sensorProvider && sensorProvider->getProperty("SensorSampleSequence")) {
            const char *key = (code == FanMethodBase || code == GAME_ZONE_WMI_GET_FAN_ONE) ? ReYogaSensor::descriptors[ReYogaSensor::Fan1].property : (code == (FanMethodBase + 1) || code == GAME_ZONE_WMI_GET_FAN_TWO) ? ReYogaSensor::descriptors[ReYogaSensor::Fan2].property
                                                                                                                                                  : (code == CPUTemperatureMethod || code == GAME_ZONE_WMI_GET_TMP_CPU)  ? ReYogaSensor::descriptors[ReYogaSensor::CPU].property
                                                                                                                                                  : (code == GPUTemperatureMethod || code == GAME_ZONE_WMI_GET_TMP_GPU)  ? ReYogaSensor::descriptors[ReYogaSensor::GPU].property
                                                                                                                                                                                                                         : nullptr;
            if (key) {
                auto sample = OSDynamicCast(OSNumber, sensorProvider->getProperty(key));
                atomic_store_explicit(&currentSensor[index], sample != nullptr ? sample->unsigned32BitValue() : UINT32_MAX, memory_order_release);
                continue;
            }
        }
        if (code >= FanMethodBase) {
            if (wmig->getFanSpeed(code - FanMethodBase, &value))
                atomic_store_explicit(&currentSensor[index], value, memory_order_release);
        } else if (code == CPUTemperatureMethod) {
            if (wmig->getCPUTemperature(&value))
                atomic_store_explicit(&currentSensor[index], value, memory_order_release);
        } else if (code == GPUTemperatureMethod) {
            if (wmig->getGPUTemperature(&value))
                atomic_store_explicit(&currentSensor[index], value, memory_order_release);
        } else {
            if (wmig->getGameZoneData(code, &value))
                atomic_store_explicit(&currentSensor[index], value, memory_order_release);
        }
    }
}

void IdeaSMC::getWMISensor(IOService *provder) {
    sensorProvider = provder;
    wmig = OSDynamicCast(IdeaWMIGameZone, provder->getProperty("Game Zone"));
}
