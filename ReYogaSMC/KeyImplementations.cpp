//
//  KeyImplementations.cpp
//  ReYogaSMC
//
//  Created by Zhen on 7/28/20.
//  Copyright © 2020 Zhen. All rights reserved.
//

#include "KeyImplementations.hpp"

SMC_RESULT BDVT::writeAccess() {
    if (!drv)
        return SmcNotWritable;
    return SmcSuccess;
}

SMC_RESULT BDVT::update(const SMC_DATA *src) {
    bool newValue = *(reinterpret_cast<const bool *>(src));
    bool *oldValue = reinterpret_cast<bool *>(data);
    DBGLOG("vpckey", "BDVT update %d -> %d", *oldValue, newValue);
    drv->dispatchMessage(kSMC_setConservation, &newValue);
    bool actual = !newValue;
    drv->dispatchMessage(kSMC_getConservation, &actual);
    if (actual != newValue)
        return SmcError;
    *oldValue = actual;
    return SmcSuccess;
}

SMC_RESULT atomicSpKey::readAccess() {
    uint32_t value = atomic_load_explicit(currentSensor, memory_order_acquire);
    if (!value || value >= 150)
        return SmcNotReadable;
    *reinterpret_cast<uint16_t *>(data) = VirtualSMCAPI::encodeSp(type, value);
    return SmcSuccess;
}

SMC_RESULT atomicSpMilliCelsiusKey::readAccess() {
    const uint32_t value = atomic_load_explicit(currentSensor, memory_order_acquire);
    if (!value || value >= 125000)
        return SmcNotReadable;
    *reinterpret_cast<uint16_t *>(data) = VirtualSMCAPI::encodeSp(type, static_cast<double>(value) / 1000.0);
    return SmcSuccess;
}

SMC_RESULT atomicSpDeciKelvinKey::readAccess() {
    uint32_t value = atomic_load_explicit(currentSensor, memory_order_acquire);
    if (value <= 2731 || value >= 4231)
        return SmcNotReadable;
    *reinterpret_cast<uint16_t *>(data) = VirtualSMCAPI::encodeSp(type, ((double)value - 2731) / 10);
    return SmcSuccess;
}

SMC_RESULT atomicFltKey::readAccess() {
    uint32_t value = atomic_load_explicit(currentSensor, memory_order_acquire);
    *reinterpret_cast<uint32_t *>(data) = VirtualSMCAPI::encodeFlt(value);
    return SmcSuccess;
}

SMC_RESULT atomicFpKey::readAccess() {
    uint32_t value = atomic_load_explicit(currentSensor, memory_order_acquire);
    if (value >= 0x4000)
        return SmcNotReadable;
    *reinterpret_cast<uint16_t *>(data) = VirtualSMCAPI::encodeIntFp(type, value);
    return SmcSuccess;
}
