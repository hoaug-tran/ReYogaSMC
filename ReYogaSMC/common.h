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
#define DebugLog(str, ...) do { IOLog("RYSMC - Debug: %s::%s " str "\n", iname ? iname : "(null)", getName(), ## __VA_ARGS__); } while (0)
#else
#define DebugLog(str, ...) do { } while (0)
#endif
#define AlwaysLog(str, ...) do { IOLog("RYSMC - Info: %s::%s " str "\n", iname ? iname : "(null)", getName(), ## __VA_ARGS__); } while (0)

#define BIT(nr) (1U << (nr))

#define ECReadCap    BIT(0)
#define ECWriteCap   BIT(1)

// A malformed property skips the caller's collection loop; a do/while macro
// would only continue its own loop and leave callers dereferencing null.
#define getPropertyBoolean(prompt) \
    if ((value = OSDynamicCast(OSBoolean, dict->getObject(prompt))) == nullptr) { \
        AlwaysLog(valueInvalid, prompt); continue; \
    }
#define getPropertyNumber(prompt) \
    if ((value = OSDynamicCast(OSNumber, dict->getObject(prompt))) == nullptr) { \
        AlwaysLog(valueInvalid, prompt); continue; \
    }
#define getPropertyString(prompt) \
    if ((value = OSDynamicCast(OSString, dict->getObject(prompt))) == nullptr) { \
        AlwaysLog(valueInvalid, prompt); continue; \
    }

#define setPropertyBoolean(dict, name, boolean) \
    do { dict->setObject(name, boolean ? kOSBooleanTrue : kOSBooleanFalse); } while (0)

// Scoped temporaries avoid dependence on the caller's variable names/types.
#define setPropertyNumber(dict, name, number, bits) \
    do { \
        auto propertyObject = OSNumber::withNumber(number, bits); \
        if (propertyObject != nullptr) { dict->setObject(name, propertyObject); propertyObject->release(); } \
    } while (0)
#define setPropertyString(dict, name, str) \
    do { \
        auto propertyObject = OSString::withCString(str); \
        if (propertyObject != nullptr) { dict->setObject(name, propertyObject); propertyObject->release(); } \
    } while (0)

#define setPropertyBytes(dict, name, data, len) \
    do { \
        value = OSData::withBytes(data, len); \
        if (value != nullptr) { \
            dict->setObject(name, value); \
            value->release(); \
        } \
    } while (0)

#define setPropertyObject(dict, name, obj) \
    do { \
        value = obj; \
        if (value != nullptr) { \
            dict->setObject(name, value); \
            value->release(); \
        } \
    } while (0)

#endif /* common_h */
