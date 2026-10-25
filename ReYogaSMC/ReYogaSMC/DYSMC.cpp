//
//  DYSMC.cpp
//  ReYogaSMC
//
//  Created by Zhen on 4/28/21.
//  Copyright © 2021 Zhen. All rights reserved.
//

#include "DYSMC.hpp"
#include "ControlValidation.hpp"
#include <Headers/kern_devinfo.hpp>

OSDefineMetaClassAndStructors(DYSMC, ReYogaSMC);

static const struct sensorPair DYPresetTachometer[] = {
    {KeyF0Ac(0), "CPU Fan"},
    {KeyF0Ac(0), "CPU Fan Speed"},
    {KeyF0Ac(1), "GPU Fan"},
    {KeyF0Ac(1), "Rear Chassis Fan"},
    {KeyF0Ac(1), "Rear Chassis Fan Speed"},
    {KeyF0Ac(2), "Power Supply Fan"},
    {KeyF0Ac(2), "Power Supply Fan Speed"},
    {KeyF0Ac(3), "Front Chassis Fan"}
};

static const struct sensorPair DYPresetTemperature[] = {
    {KeyTB0T(1), "Battery Temperature"},
    {KeyTCGC,    "Discrete Graphics Temperature"},
    {KeyTCGC,    "GPU Temperature"},
    {KeyTCSA,    "Private temp1 (CPU VR Temp)"},
    {KeyTCXC,    "CPU Temperature"},
    {KeyTG0P(0), "GPU0 Temperature"},
    {KeyTG0P(1), "GPU1 Temperature"},
    {KeyTH0a,    "M.2 Temperature"},
    {KeyTH0a,    "M.2 0 Temperature"},
    {KeyTH0b,    "M.2 1 Temperature"},
    {KeyTH0b,    "HDD Temperature"},
    {KeyTM0P,    "Private temp2 (Memory Temp)"},
    {KeyTPCD,    "Local Temperature"},
    {KeyTTRD,    "Charger Temperature"},
    {KeyTW0P,    "Chassis Temperature"},
    {KeyTW0P,    "U518"},
    {KeyTh0H(1), "System Ambient Temperature"},
    {KeyTh0H(2), "System Ambient1 Temperature"},
    {KeyTs0P(0), "Remote Temperature"}
};

static bool readNumericSensor(OSArray *array, UInt32 &value, UInt32 &type) {
    if (!array || array->getCount() < 9 || array->getCount() > 32) return false;
    auto status = OSDynamicCast(OSNumber, array->getObject(4));
    if (status == nullptr || status->unsigned64BitValue() > 0xffffffffULL ||
        !ReYogaControl::validHPSensorStatus(status->unsigned32BitValue())) return false;
    auto size = OSDynamicCast(OSNumber, array->getObject(5));
    const bool modern = size != nullptr;
    const unsigned fixed = modern ? 11 : 9;
    if (array->getCount() < fixed) return false;
    const unsigned states = array->getCount() - fixed;
    if (modern && size->unsigned64BitValue() != states) return false;
    auto state = OSDynamicCast(OSString, array->getObject(modern ? 6 + states : 5));
    if (!state || state->isEqualTo("Not Present")) return false;
    for (unsigned i = 0; i < states; ++i)
        if (!OSDynamicCast(OSString, array->getObject(6 + i))) return false;
    const unsigned base = (modern ? 7 : 6) + states;
    auto kind = OSDynamicCast(OSNumber, array->getObject(2));
    auto units = OSDynamicCast(OSNumber, array->getObject(base));
    auto modifier = OSDynamicCast(OSNumber, array->getObject(base + 1));
    auto reading = OSDynamicCast(OSNumber, array->getObject(base + 2));
    if (kind == nullptr || units == nullptr || modifier == nullptr || reading == nullptr || reading->unsigned64BitValue() > 0xffffffffULL) return false;
    if (modern) {
        auto rate = OSDynamicCast(OSNumber, array->getObject(base + 3));
        if (rate == nullptr || rate->unsigned64BitValue() != 0) return false;
    }
    type = kind->unsigned32BitValue();
    return ReYogaControl::decodeHPSensor(reading->unsigned32BitValue(),
        static_cast<SInt32>(modifier->unsigned32BitValue()), type, units->unsigned32BitValue(), value);
}

bool DYSMC::addTachometerKey(OSString *name, UInt8 fan) {
    for (auto &pair : DYPresetTachometer) {
        if (name->isEqualTo(pair.name)) {
            for (UInt8 i = 0; i < fan; ++i)
                if (fanKeys[i] == pair.key) return false;
            if (!VirtualSMCAPI::addKey(KeyF0Ac(fan), vsmcPlugin.data,
                VirtualSMCAPI::valueWithFp(0, SmcKeyTypeFpe2, new atomicFpKey(&currentSensor[sensorCount])))) return false;
            fanKeys[fan] = pair.key;
            return true;
        }
    }
    return false;
}

bool DYSMC::addTemperatureKey(OSString *name) {
    for (auto &pair : DYPresetTemperature) {
        if (name->isEqualTo(pair.name)) {
            for (size_t i = 0; i < vsmcPlugin.data.size(); ++i)
                if (vsmcPlugin.data.data()[i].key == pair.key) return false;
            return VirtualSMCAPI::addKey(pair.key, vsmcPlugin.data,
                VirtualSMCAPI::valueWithSp(0, SmcKeyTypeSp78, new atomicSpMilliCelsiusKey(&currentSensor[sensorCount])));
        }
    }
    return false;
}

void DYSMC::addVSMCKey() {
    if (!wmis) {
        super::addVSMCKey();
        return;
    }

    OSObject *result = nullptr;

    OSDictionary *enabled = OSDictionary::withCapacity(wmis->sensorRange);
    OSDictionary *disabled = OSDictionary::withCapacity(wmis->sensorRange);
    if (!enabled || !disabled) {
        OSSafeReleaseNULL(enabled); OSSafeReleaseNULL(disabled);
        super::addVSMCKey();
        return;
    }

    UInt8 fanCount = 0;

    for (UInt8 index = 0; index < wmis->sensorRange && sensorCount < MAX_SENSOR; ++index) {
        OSSafeReleaseNULL(result);

        if (!wmis->getSensorInfo(index, &result)) {
            AlwaysLog("Failed to evaluate sensor %d", index);
            continue;
        }

        OSArray *arr = OSDynamicCast(OSArray, result);
        if (!arr) {
            AlwaysLog("Sensor %d returns empty result, please check if the method has valid return", index);
            continue;
        }

        OSString *sensorName = OSDynamicCast(OSString, arr->getObject(0));
        if (!sensorName || sensorName->isEqualTo("")) {
            char tempName[10];
            snprintf(tempName, 10, "Sensor %d", index);
            disabled->setObject(tempName, arr);
            AlwaysLog("Failed to get name for sensor %d", index);
            continue;
        }

        if (sensorName->isEqualTo("Unknown Sensor")) {
            AlwaysLog("Unknown Sensor %d", index);
            continue;
        }

        UInt32 value = 0, type = 0;
        if (!readNumericSensor(arr, value, type)) {
            disabled->setObject(sensorName, arr);
            continue;
        }

        switch (type) {
            case SENSOR_TYPE_TEMPERATURE:
                if (value == 0) {
                    disabled->setObject(sensorName, arr);
                    AlwaysLog("Temperature is 0 for %s", sensorName->getCStringNoCopy());
                    continue;
                }
                if (!addTemperatureKey(sensorName)) {
                    disabled->setObject(sensorName, arr);
                    AlwaysLog("Unknown temperature %s", sensorName->getCStringNoCopy());
                    continue;
                }
                break;

            case SENSOR_TYPE_AIR_FLOW:
                if (!addTachometerKey(sensorName, fanCount)) {
                    disabled->setObject(sensorName, arr);
                    AlwaysLog("Unknown tachometer %s", sensorName->getCStringNoCopy());
                    continue;
                }
                fanCount++;
                break;

            default:
                disabled->setObject(sensorName, arr);
                AlwaysLog("Unknown sensor %s", sensorName->getCStringNoCopy());
                continue;
        }

        sensorType[sensorCount] = type;
        sensorIndex[sensorCount++] = index;
        enabled->setObject(sensorName, arr);
    }
    OSSafeReleaseNULL(result);

    if (fanCount)
        VirtualSMCAPI::addKey(KeyFNum, vsmcPlugin.data, VirtualSMCAPI::valueWithUint8(fanCount, nullptr, SMC_KEY_ATTRIBUTE_CONST | SMC_KEY_ATTRIBUTE_READ));

    setProperty("Sensors", enabled);
    setProperty("Disabled Sensors", disabled);
    OSSafeReleaseNULL(enabled);
    OSSafeReleaseNULL(disabled);

    super::addVSMCKey();
}

void DYSMC::updateECVendor() {
    OSObject *result = nullptr;

    for (UInt8 index = 0; index < ECSensorBase; ++index) {
        atomic_store_explicit(&currentSensor[index], UINT32_MAX, memory_order_release);
        OSSafeReleaseNULL(result);
        if (!wmis->getSensorInfo(sensorIndex[index], &result)) {
            AlwaysLog("Failed to evaluate sensor %d", sensorIndex[index]);
            continue;
        }

        OSArray *arr = OSDynamicCast(OSArray, result);
        if (!arr) {
            AlwaysLog("Sensor %d returns empty result, please check if the method has valid return", sensorIndex[index]);
            continue;
        }

        UInt32 value = 0, type = 0;
        if (readNumericSensor(arr, value, type) && type == sensorType[index])
            atomic_store_explicit(&currentSensor[index], value, memory_order_release);
    }
    OSSafeReleaseNULL(result);
}

void DYSMC::getWMISensor(IOService *provider) {
    wmis = OSDynamicCast(DYWMI, provider->getProperty("DYSensor"));
}
