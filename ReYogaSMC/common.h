//  SPDX-License-Identifier: GPL-2.0-only
//
//  common.h
//  ReYogaSMC
//
//  Created by Zhen on 8/23/20.
//  Copyright © 2020 Zhen. All rights reserved.
//

#ifndef common_h
#define common_h

#include <Availability.h>

#ifndef __ACIDANTHERA_MAC_SDK
#error "This kext SDK is unsupported. Download from https://github.com/acidanthera/MacKernelSDK"
#endif

#ifdef DEBUG
#define DebugLog(str, ...)                                                                            \
    do {                                                                                              \
        IOLog("RYSMC - Debug: %s::%s " str "\n", iname ? iname : "(null)", getName(), ##__VA_ARGS__); \
    } while (0)
#else
#define DebugLog(str, ...) \
    do {                   \
    } while (0)
#endif
#define AlwaysLog(str, ...)                                                                          \
    do {                                                                                             \
        IOLog("RYSMC - Info: %s::%s " str "\n", iname ? iname : "(null)", getName(), ##__VA_ARGS__); \
    } while (0)

#define BIT(nr) (1U << (nr))

#define ECReadCap BIT(0)
#define ECWriteCap BIT(1)

// Getters return borrowed values; setters retain into the dictionary.
#include <libkern/c++/OSBoolean.h>
#include <libkern/c++/OSData.h>
#include <libkern/c++/OSDictionary.h>
#include <libkern/c++/OSNumber.h>
#include <libkern/c++/OSString.h>

namespace ReYogaProperty {
template <typename Value, typename Key>
inline Value *get(const OSDictionary *dictionary, const Key *key) {
    return dictionary && key ? OSDynamicCast(Value, dictionary->getObject(key)) : nullptr;
}

// Consumes exactly one owned reference, including when insertion fails.
template <typename Key>
inline bool setOwned(OSDictionary *dictionary, const Key *key, OSObject *owned) {
    if (!owned)
        return false;
    const bool inserted = dictionary && key && dictionary->setObject(key, owned);
    owned->release();
    return inserted;
}

template <typename Key>
inline bool setBoolean(OSDictionary *dictionary, const Key *key, bool value) {
    return dictionary && key && dictionary->setObject(key, value ? kOSBooleanTrue : kOSBooleanFalse);
}

template <typename Key>
inline bool setNumber(OSDictionary *dictionary, const Key *key, UInt64 value, unsigned bits) {
    return setOwned(dictionary, key, OSNumber::withNumber(value, bits));
}

template <typename Key>
inline bool setString(OSDictionary *dictionary, const Key *key, const char *value) {
    return value && setOwned(dictionary, key, OSString::withCString(value));
}

template <typename Key>
inline bool setBytes(OSDictionary *dictionary, const Key *key, const void *bytes, unsigned length) {
    return setOwned(dictionary, key, OSData::withBytes(bytes, length));
}
} // namespace ReYogaProperty

#endif /* common_h */
