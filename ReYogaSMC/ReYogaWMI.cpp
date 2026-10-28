// SPDX-License-Identifier: GPL-2.0-only
//
// ReYogaWMI.cpp
// ReYogaSMC
//
// Created by Zhen on 2020/5/21.
// Copyright (c) 2020 Zhen. All rights reserved.
//

#include "ReYogaWMI.hpp"

#include <pexpert/pexpert.h>

OSDefineMetaClassAndStructors(ReYogaWMI, ReYogaBaseService);

namespace {

constexpr UInt64 kWMIServiceWaitNanoseconds = 2ULL * 1000ULL * 1000ULL * 1000ULL;
constexpr UInt32 kMaximumWMINotifyID = 0xFF;
constexpr const char *kWMIEventProperty = "Event";
constexpr const char *kWMISupportedProperty = "ReYogaWMISupported";

bool hasBootArgument(const char *name) {
    int value = 0;
    return PE_parse_boot_argn(name, &value, sizeof(value));
}

int hexDigit(char value) {
    if (value >= '0' && value <= '9') {
        return value - '0';
    }

    if (value >= 'a' && value <= 'f') {
        return value - 'a' + 10;
    }

    if (value >= 'A' && value <= 'F') {
        return value - 'A' + 10;
    }

    return -1;
}

bool parseNotifyIDKey(const char *key, UInt32 &id) {
    if (!key) {
        return false;
    }

    if (key[0] == '0' && (key[1] == 'x' || key[1] == 'X')) {
        key += 2;
    }

    if (!key[0] || !key[1] || key[2] != '\0') {
        return false;
    }

    const int high = hexDigit(key[0]);
    const int low = hexDigit(key[1]);

    if (high < 0 || low < 0) {
        return false;
    }

    id = static_cast<UInt32>((high << 4) | low);
    return true;
}

} // namespace

IOService *ReYogaWMI::probe(IOService *provider, SInt32 *score) {
    if (hasBootArgument("-reysafe") || hasBootArgument("-reynowmi")) {
        return nullptr;
    }

    IOService *candidate = super::probe(provider, score);
    if (!candidate) {
        return nullptr;
    }

    auto *device = OSDynamicCast(IOACPIPlatformDevice, provider);
    if (!device) {
        return candidate;
    }

    OSObject *uid = nullptr;

    const IOReturn status = device->evaluateObject("_UID", &uid);

    const auto *uidString = OSDynamicCast(OSString, uid);

    const bool isThunderboltInterface =
        status == kIOReturnSuccess && uidString && uidString->isEqualTo("TBFP");

    OSSafeReleaseNULL(uid);

    if (isThunderboltInterface) {
        DebugLog("Skipping Thunderbolt WMI interface");
        return nullptr;
    }

    DebugLog("Probing WMI interface");

    return candidate;
}

void ReYogaWMI::registerAndLogEvent(const char *key) {
    if (!Event || !key) {
        return;
    }

    auto *item = OSDynamicCast(OSDictionary, Event->getObject(key));

    if (!item) {
        AlwaysLog("Invalid WMI event metadata for key %s", key);
        return;
    }

    auto *number = OSDynamicCast(OSNumber, item->getObject(kWMINotifyId));

    if (!number) {
        AlwaysLog("Missing WMI notify ID for key %s", key);
        return;
    }

    const UInt64 rawID = number->unsigned64BitValue();

    if (rawID > kMaximumWMINotifyID) {
        AlwaysLog("Out-of-range WMI notify ID for key %s: 0x%llX",
                  key, static_cast<unsigned long long>(rawID));
        return;
    }

    const UInt32 id = static_cast<UInt32>(rawID);

    UInt32 keyID = 0;

    if (!parseNotifyIDKey(key, keyID)) {
        AlwaysLog("Unexpected WMI event key format: %s", key);
    } else if (keyID != id) {
        AlwaysLog("WMI notify ID mismatch: key=%s, metadata=0x%02X", key, id);
    }

    const char *name = nullptr;

    auto *guid = OSDynamicCast(OSString, item->getObject("guid"));

    if (guid) {
        name = registerEvent(guid, id);
    }

    const char *displayName = name ? name : "unknown";

    auto *mof = OSDynamicCast(OSDictionary, item->getObject("MOF"));

    if (!mof) {
        AlwaysLog("WMI event %s (0x%02X) has no MOF description", displayName, id);
        return;
    }

    auto *className = OSDynamicCast(OSString, mof->getObject("__CLASS"));

    if (!className) {
        AlwaysLog("WMI event %s (0x%02X) has no MOF class", displayName, id);
        return;
    }

    AlwaysLog("WMI event %s (0x%02X): %s", displayName, id,
              className->getCStringNoCopy());
}

bool ReYogaWMI::start(IOService *provider) {
    if (!YWMI) {
        auto *key = OSSymbol::withCString(kWMISupportedProperty);

        if (!key) {
            AlwaysLog("Failed to allocate WMI matching key");
            return false;
        }

        auto *matching = IOService::propertyMatching(key, kOSBooleanTrue);

        key->release();

        if (!matching) {
            AlwaysLog("Failed to create WMI matching dictionary");
            return false;
        }

        auto *existingService =
            IOService::waitForMatchingService(matching, kWMIServiceWaitNanoseconds);

        matching->release();

        if (existingService) {
            existingService->release();

            DebugLog("Another ReYogaWMI service is available; skipping standalone instance");

            return false;
        }
    }

    if (!super::start(provider)) {
        return false;
    }

    if (!YWMI) {
        YWMI = new WMI(provider);

        if (!YWMI) {
            AlwaysLog("Failed to allocate WMI provider");

            super::stop(provider);

            return false;
        }

        ownsWMI_ = true;

        if (!YWMI->initialize()) {
            delete YWMI;
            YWMI = nullptr;
            ownsWMI_ = false;
            super::stop(provider);
            return false;
        }
    }

    YWMI->start();
    processWMI();

    Event = YWMI->getEvent();
    if (Event) {
        if (!setProperty(kWMIEventProperty, Event)) {
            AlwaysLog("Failed to publish WMI event metadata");
        }

        auto *iterator = OSCollectionIterator::withCollection(Event);

        if (!iterator) {
            AlwaysLog("Failed to enumerate WMI events");
        } else {
            OSObject *object = nullptr;

            while ((object = iterator->getNextObject()) != nullptr) {
                auto *key = OSDynamicCast(OSString, object);

                if (key) {
                    registerAndLogEvent(key->getCStringNoCopy());
                }
            }

            iterator->release();
        }
    }

    DebugLog("WMI service started");
    return true;
}

void ReYogaWMI::stop(IOService *provider) {
    DebugLog("Stopping WMI service");

    removeProperty(kWMIEventProperty);
    Event = nullptr;

    super::stop(provider);
}

void ReYogaWMI::free() {
    if (ownsWMI_)
        delete YWMI;
    YWMI = nullptr;
    ownsWMI_ = false;
    super::free();
}

void ReYogaWMI::processWMI() {
}

const char *ReYogaWMI::registerEvent(OSString *guid, UInt32 id) {
    (void)guid;
    (void)id;
    return nullptr;
}

void ReYogaWMI::ACPIEvent(UInt32 argument) {
    AlwaysLog("Unknown ACPI notification: 0x%02X", argument);
}

IOReturn ReYogaWMI::message(UInt32 type, IOService *provider, void *argument) {
    if (type == kIOACPIMessageDeviceNotification) {
        if (!argument) {
            AlwaysLog("ACPI notification from %s has no argument",
                      provider ? provider->getName() : "unknown");
            return kIOReturnSuccess;
        }

        ACPIEvent(*static_cast<const UInt32 *>(argument));
        return kIOReturnSuccess;
    }

    DebugLog("Forwarding IOService message type=0x%X, provider=%s, argument=%p",
             type, provider ? provider->getName() : "unknown", argument);
    return super::message(type, provider, argument);
}
