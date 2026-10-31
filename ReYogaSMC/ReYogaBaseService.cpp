//
//  ReYogaBaseService.cpp
//  ReYogaSMC
//
//  Created by Zhen on 10/17/20.
//  Copyright © 2020 Zhen. All rights reserved.
//

#include "ControlValidation.hpp"
#include "ReYogaBaseService.hpp"

OSDefineMetaClassAndStructors(ReYogaBaseService, IOService);

bool ReYogaBaseService::init(OSDictionary *dictionary) {
    if (!super::init(dictionary))
        return false;

    DebugLog("Initializing");

    _deliverNotification = OSSymbol::withCString(kDeliverNotifications);
    if (!_deliverNotification)
        return false;

    _notificationServices = OSSet::withCapacity(1);

    if (!_notificationServices) {
        OSSafeReleaseNULL(_deliverNotification);
        return false;
    }
    return true;
}

IOService *ReYogaBaseService::probe(IOService *provider, SInt32 *score) {
    iname = provider->getName();
    return this;
}

bool ReYogaBaseService::start(IOService *provider) {
    if (!super::start(provider))
        return false;
#ifndef ALTER
    setProperty("VersionInfo", kextVersion);
#else
    extern kmod_info_t kmod_info;
    setProperty("VersionInfo", kmod_info.version);
    setProperty("Variant", "Alter");
#endif
    setProperty("ForkName", "ReYogaSMC");
    setProperty("DiagnosticSchemaVersion", 1, 32);
    workLoop = IOWorkLoop::workLoop();
    commandGate = IOCommandGate::commandGate(this);
    if (!workLoop || !commandGate || (workLoop->addEventSource(commandGate) != kIOReturnSuccess)) {
        AlwaysLog("Failed to add commandGate");
        OSSafeReleaseNULL(commandGate);
        OSSafeReleaseNULL(workLoop);
        super::stop(provider);
        return false;
    }

    OSDictionary *propertyMatch = propertyMatching(_deliverNotification, kOSBooleanTrue);
    if (propertyMatch) {
        IOServiceMatchingNotificationHandler notificationHandler = OSMemberFunctionCast(IOServiceMatchingNotificationHandler, this, &ReYogaBaseService::notificationHandler);

        //
        // Register notifications for availability of any IOService objects wanting to consume our message events
        //
        _publishNotify = addMatchingNotification(gIOFirstPublishNotification,
                                                 propertyMatch,
                                                 notificationHandler,
                                                 this,
                                                 0, 10000);

        _terminateNotify = addMatchingNotification(gIOTerminatedNotification,
                                                   propertyMatch,
                                                   notificationHandler,
                                                   this,
                                                   0, 10000);

        propertyMatch->release();
    }

    if (isPMsupported) {
        PMinit();
        provider->joinPMtree(this);
        registerPowerDriver(this, IOPMPowerStates, kIOPMNumberPowerStates);
    }

    return true;
}

void ReYogaBaseService::stop(IOService *provider) {
    if (commandGate)
        commandGate->runAction([](OSObject *owner, void *, void *, void *, void *) -> IOReturn {
            static_cast<ReYogaBaseService *>(owner)->stopping = true;
            return kIOReturnSuccess;
        });
    if (_publishNotify) {
        _publishNotify->remove();
        _publishNotify = nullptr;
    }
    if (_terminateNotify) {
        _terminateNotify->remove();
        _terminateNotify = nullptr;
    }
    if (_notificationServices)
        _notificationServices->flushCollection();

    if (isPMsupported)
        PMstop();

    super::stop(provider);
}

void ReYogaBaseService::free() {
    // Userclients retain their provider; keep the gate valid until the final client releases it.
    if (workLoop && commandGate)
        workLoop->removeEventSource(commandGate);
    OSSafeReleaseNULL(commandGate);
    OSSafeReleaseNULL(workLoop);
    OSSafeReleaseNULL(_notificationServices);
    OSSafeReleaseNULL(_deliverNotification);
    super::free();
}

void ReYogaBaseService::dispatchMessageGated(int *message, void *data) {
    if (stopping)
        return;
    OSCollectionIterator *i = OSCollectionIterator::withCollection(_notificationServices);

    if (i) {
        while (IOService *service = OSDynamicCast(IOService, i->getNextObject())) {
            service->message(*message, this, data);
        }
        i->release();
    }
}

void ReYogaBaseService::dispatchMessage(int message, void *data) {
    if (!_notificationServices || _notificationServices->getCount() == 0) {
        AlwaysLog("No available notification consumer");
        return;
    }
    if (!commandGate)
        return;
    commandGate->runAction([](OSObject *owner, void *message, void *data, void *, void *) -> IOReturn {
        static_cast<ReYogaBaseService *>(owner)->dispatchMessageGated(static_cast<int *>(message), data);
        return kIOReturnSuccess;
    },
                           &message, data);
}

void ReYogaBaseService::notificationHandlerGated(IOService *newService, IONotifier *notifier) {
    if (stopping || !newService || !_notificationServices)
        return;
    if (notifier == _publishNotify) {
        DebugLog("Notification consumer published: %s", newService->getName());
        _notificationServices->setObject(newService);
    }

    if (notifier == _terminateNotify) {
        DebugLog("Notification consumer terminated: %s", newService->getName());
        _notificationServices->removeObject(newService);
    }
}

bool ReYogaBaseService::notificationHandler(void *refCon, IOService *newService, IONotifier *notifier) {
    if (!commandGate)
        return false;
    commandGate->runAction([](OSObject *owner, void *service, void *notifier, void *, void *) -> IOReturn {
        static_cast<ReYogaBaseService *>(owner)->notificationHandlerGated(static_cast<IOService *>(service), static_cast<IONotifier *>(notifier));
        return kIOReturnSuccess;
    },
                           newService, notifier);
    return true;
}

bool ReYogaBaseService::findPNP(const char *id, IOACPIPlatformDevice **dev) {
    DebugLog("findPNP for %s", id);
    if (!id || !dev)
        return false;
    auto pnp = OSString::withCString(id);
    if (!pnp)
        return false;
    if ((*dev) && (*dev)->compareName(pnp, nullptr)) {
        DebugLog("found %s at %s", id, (*dev)->getName());
    } else {
        *dev = nullptr;
        auto iterator = IORegistryIterator::iterateOver(gIOACPIPlane, kIORegistryIterateRecursively);
        if (!iterator) {
            AlwaysLog("findPNP failed to create iterator");
        } else {
            while (auto entry = iterator->getNextObject()) {
                if (entry->compareName(pnp, nullptr)) {
                    DebugLog("found %s at %s", id, entry->getName());
                    if (auto candidate = OSDynamicCast(IOACPIPlatformDevice, entry)) {
                        if (*dev) {
                            AlwaysLog("Ambiguous %s devices; refusing an arbitrary EC selection", id);
                            *dev = nullptr;
                            break;
                        }
                        *dev = candidate;
                    }
                }
            }
            iterator->release();
        }
    }
    pnp->release();
    return !!(*dev);
}

void ReYogaBaseService::toggleTouchpad() {
    dispatchMessage(kSMC_getDisableTouchpad, &TouchPadenabled);
    TouchPadenabled = !TouchPadenabled;
    dispatchMessage(kSMC_setDisableTouchpad, &TouchPadenabled);
    DebugLog("TouchPad Input %s", TouchPadenabled ? "enabled" : "disabled");
    setProperty("TouchPadEnabled", TouchPadenabled);
}

void ReYogaBaseService::toggleKeyboard() {
    dispatchMessage(kSMC_getKeyboardStatus, &Keyboardenabled);
    Keyboardenabled = !Keyboardenabled;
    dispatchMessage(kSMC_setKeyboardStatus, &Keyboardenabled);
    DebugLog("Keyboard Input %s", Keyboardenabled ? "enabled" : "disabled");
    setProperty("KeyboardEnabled", Keyboardenabled);
}

void ReYogaBaseService::setTopCase(bool enable) {
    dispatchMessage(kSMC_setKeyboardStatus, &enable);
    dispatchMessage(kSMC_setDisableTouchpad, &enable);
    DebugLog("TopCase Input %s", enable ? "enabled" : "disabled");
    setProperty("TopCaseEnabled", enable);
}

bool ReYogaBaseService::updateTopCase() {
    dispatchMessage(kSMC_getKeyboardStatus, &Keyboardenabled);
    dispatchMessage(kSMC_getDisableTouchpad, &TouchPadenabled);
    if (Keyboardenabled != TouchPadenabled) {
        AlwaysLog("status mismatch: %d, %d", Keyboardenabled, TouchPadenabled);
        return false;
    }
    return true;
}

IOReturn ReYogaBaseService::setPowerState(unsigned long powerStateOrdinal, IOService *whatDevice) {
    DebugLog("powerState %ld : %s", powerStateOrdinal, powerStateOrdinal ? "on" : "off");
    if (whatDevice != this)
        return kIOReturnInvalid;

    return kIOPMAckImplied;
}

IOReturn ReYogaBaseService::readECName(const char *name, UInt32 *result) {
    if (!ec)
        return kIOReturnNoDevice;
    if (!name || !result)
        return kIOReturnBadArgument;
    IOReturn ret = ec->evaluateInteger(name, result);
    switch (ret) {
    case kIOReturnSuccess:
        break;

    case kIOReturnBadArgument:
        AlwaysLog("read %s failed, bad argument (field size too large?)", name);
        break;

    default:
        AlwaysLog("read %s failed %x", name, ret);
        break;
    }
    return ret;
}

IOReturn ReYogaBaseService::method_re1b(UInt32 offset, UInt8 *result, bool logFailure) {
    if (!ec || !(ECAccessCap & ECReadCap))
        return kIOReturnUnsupported;

    if (!result || offset >= 0x100)
        return kIOReturnBadArgument;
    UInt32 raw = 0;
    OSObject *params[1] = {
        OSNumber::withNumber(offset, 32)};

    if (!params[0])
        return kIOReturnNoMemory;
    IOReturn ret = ec->evaluateInteger(readECOneByte, &raw, params, 1);
    params[0]->release();

    if (ret != kIOReturnSuccess && logFailure)
        AlwaysLog("read 0x%02x failed", offset);

    if (ret == kIOReturnSuccess && raw > 0xff)
        return kIOReturnBadArgument;
    *result = raw;
    return ret;
}

IOReturn ReYogaBaseService::method_recb(UInt32 offset, UInt32 size, OSData **data) {
    if (!ec || !(ECAccessCap & ECReadCap))
        return kIOReturnUnsupported;

    if (!data || !ReYogaControl::validECSpan(offset, size))
        return kIOReturnBadArgument;
    *data = nullptr;

    if (ec->validateObject(readECBytes) != kIOReturnSuccess) {
        UInt8 bytes[0x100];
        for (UInt32 i = 0; i < size; ++i) {
            IOReturn status = method_re1b(offset + i, &bytes[i]);
            if (status != kIOReturnSuccess)
                return status;
        }
        *data = OSData::withBytes(bytes, size);
        return *data ? kIOReturnSuccess : kIOReturnNoMemory;
    }

    // Arg0 - offset in bytes from zero-based EC
    // Arg1 - size of buffer in bits
    OSObject *params[2] = {
        OSNumber::withNumber(offset, 32),
        OSNumber::withNumber(size * 8, 32)};
    if (!params[0] || !params[1]) {
        OSSafeReleaseNULL(params[0]);
        OSSafeReleaseNULL(params[1]);
        return kIOReturnNoMemory;
    }
    OSObject *result = nullptr;

    IOReturn ret = ec->evaluateObject(readECBytes, &result, params, 2);
    params[0]->release();
    params[1]->release();

    auto buffer = OSDynamicCast(OSData, result);
    if (ret != kIOReturnSuccess || !buffer) {
        AlwaysLog("read %d bytes @ 0x%02x failed", size, offset);
        OSSafeReleaseNULL(result);
        return kIOReturnInvalid;
    }

    if (buffer->getLength() != size) {
        AlwaysLog("read %d bytes @ 0x%02x, got %d bytes", size, offset, buffer->getLength());
        OSSafeReleaseNULL(result);
        return kIOReturnNoBandwidth;
    }

    *data = buffer;
    return ret;
}

IOReturn ReYogaBaseService::method_we1b(UInt32 offset, UInt8 value, bool logFailure) {
    if (!ec || !(ECAccessCap & ECWriteCap))
        return kIOReturnUnsupported;

    if (offset >= 0x100)
        return kIOReturnBadArgument;
    OSObject *params[2] = {
        OSNumber::withNumber(offset, 32),
        OSNumber::withNumber(value, 8)};
    if (!params[0] || !params[1]) {
        OSSafeReleaseNULL(params[0]);
        OSSafeReleaseNULL(params[1]);
        return kIOReturnNoMemory;
    }

    IOReturn ret = ec->evaluateObject(writeECOneByte, nullptr, params, 2);
    params[0]->release();
    params[1]->release();

    if (ret != kIOReturnSuccess && logFailure)
        AlwaysLog("write 0x%02x @ 0x%02x failed", value, offset);
    else if (ret == kIOReturnSuccess)
        DebugLog("write 0x%02x @ 0x%02x success", value, offset);
    return ret;
}

void ReYogaBaseService::validateEC() {
    if (!ec)
        return;
    ECAccessCap = 0;
    if (ec->validateObject(readECOneByte) != kIOReturnSuccess) {
        setProperty("EC Capability", "Basic");
        return;
    }
    ECAccessCap |= ECReadCap;
    if (ec->validateObject(writeECOneByte) != kIOReturnSuccess) {
        setProperty("EC Capability", "RO");
        return;
    }
    ECAccessCap |= ECWriteCap;
    setProperty("EC Capability", "RW");
}

void ReYogaBaseService::dispatchKeyEvent(UInt16 keyCode, bool goingDown, bool time) {
    PS2KeyInfo info = {.adbKeyCode = keyCode, .goingDown = goingDown, .eatKey = false};
    clock_get_uptime(&info.time);
    if (time)
        dispatchMessage(kPS2M_notifyKeyTime, &info.time);
    dispatchMessage(kSMC_notifyKeystroke, &info);
}
