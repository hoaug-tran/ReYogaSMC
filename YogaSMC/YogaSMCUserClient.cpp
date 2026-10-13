//
//  YogaSMCUserClient.cpp
//  YogaSMC
//
//  Created by Zhen on 10/7/20.
//  Copyright © 2020 Zhen. All rights reserved.
//

#include <IOKit/IOLib.h>
#include "YogaSMCUserClientPrivate.hpp"

OSDefineMetaClassAndStructors(YogaSMCUserClient, IOUserClient)
// Preserve the public selector ABI while using explicit scalar/structure counts.
IOReturn YogaSMCUserClient::externalMethod(uint32_t selector, IOExternalMethodArguments *arguments,
    IOExternalMethodDispatch *, OSObject *, void *) {
    const IOExternalMethodDispatch methods[kYSMCUCNumMethods] = {
        { [](OSObject *object, void *, IOExternalMethodArguments *) -> IOReturn {
            return static_cast<YogaSMCUserClient *>(object)->userClientOpen();
        }, 0, 0, 0, 0 },
        { [](OSObject *object, void *, IOExternalMethodArguments *) -> IOReturn {
            return static_cast<YogaSMCUserClient *>(object)->userClientClose();
        }, 0, 0, 0, 0 },
        { [](OSObject *object, void *, IOExternalMethodArguments *args) -> IOReturn {
            IOByteCount size = args->structureOutputSize;
            IOReturn ret = static_cast<YogaSMCUserClient *>(object)->readEC(args->scalarInput[0],
                static_cast<UInt8 *>(args->structureOutput), &size);
            args->structureOutputSize = static_cast<uint32_t>(size);
            return ret;
        }, 1, 0, 0, kIOUCVariableStructureSize },
        { [](OSObject *object, void *, IOExternalMethodArguments *args) -> IOReturn {
            return static_cast<YogaSMCUserClient *>(object)->writeEC(args->scalarInput[0],
                const_cast<UInt8 *>(static_cast<const UInt8 *>(args->structureInput)), args->structureInputSize);
        }, 1, kIOUCVariableStructureSize, 0, 0 },
        { [](OSObject *object, void *, IOExternalMethodArguments *args) -> IOReturn {
            return static_cast<YogaSMCUserClient *>(object)->readECName(static_cast<const char *>(args->structureInput),
                static_cast<UInt8 *>(args->structureOutput));
        }, 0, 4, 0, 1 }
    };
    if (selector >= kYSMCUCNumMethods || !arguments) return kIOReturnBadArgument;
    return super::externalMethod(selector, arguments,
        const_cast<IOExternalMethodDispatch *>(&methods[selector]), this, nullptr);
}

IOReturn YogaSMCUserClient::userClientOpen(void) {
    if (fProvider == NULL || isInactive()) {
        AlwaysLog("%s kIOReturnNotAttached", __FUNCTION__);
        return kIOReturnNotAttached;
    } else if (!fProvider->open(this)) {
        AlwaysLog("%s kIOReturnExclusiveAccess", __FUNCTION__);
        return kIOReturnExclusiveAccess;
    }
    DebugLog("%s", __FUNCTION__);
    return kIOReturnSuccess;
}

IOReturn YogaSMCUserClient::userClientClose(void) {
    if (fProvider == NULL || isInactive()) {
        AlwaysLog("%s kIOReturnNotAttached", __FUNCTION__);
        return kIOReturnNotAttached;
    } else if (!fProvider->isOpen(this)) {
        DebugLog("%s kIOReturnNotOpen", __FUNCTION__);
        return kIOReturnNotOpen;
    }

    if (fProvider->client == this) {
        fProvider->client = nullptr;
        DebugLog("%s notification unregistered", __FUNCTION__);
    }

    m_notificationPort = MACH_PORT_NULL;
    fProvider->close(this);
    DebugLog("%s", __FUNCTION__);
    return kIOReturnSuccess;
}

IOReturn YogaSMCUserClient::readEC(UInt64 offset, UInt8* output, IOByteCount *outputSizeP) {
    if (!fProvider || !fProvider->isOpen(this))
        return kIOReturnNotReady;

    if (!(output && outputSizeP)) {
        AlwaysLog("%s invalid arguments", __FUNCTION__);
        return kIOReturnBadArgument;
    }

    if (offset >= 0x100 || *outputSizeP == 0 || *outputSizeP > 0x100 - offset) {
        AlwaysLog("%s invalid range", __FUNCTION__);
        return kIOReturnBadArgument;
    }

    if (*outputSizeP == 1) {
        UInt8 result;
        if (fProvider->method_re1b(UInt32(offset), &result) != kIOReturnSuccess) {
            AlwaysLog("%s re1b failed", __FUNCTION__);
            return kIOReturnIOError;
        }
        *output = result;
    } else {
        OSData *result = nullptr;
        if (fProvider->method_recb(UInt32(offset), UInt32(*outputSizeP), &result) != kIOReturnSuccess) {
            AlwaysLog("%s recb failed", __FUNCTION__);
            return kIOReturnIOError;
        }
        if (!result)
            return kIOReturnIOError;
        if (result->getLength() == *outputSizeP) {
            const UInt8* data = reinterpret_cast<const UInt8 *>(result->getBytesNoCopy());
            memcpy(output, data, result->getLength());
        } else {
            *outputSizeP = 0;
            result->release();
            return kIOReturnIOError;
        }
        result->release();
    }

    DebugLog("%s 0x%02llx @ 0x%02llx", __FUNCTION__, *outputSizeP, offset);
    return kIOReturnSuccess;
}

IOReturn YogaSMCUserClient::writeEC(UInt64 offset, UInt8* input, IOByteCount inputSizeP) {
    if (!fProvider || !fProvider->isOpen(this))
        return kIOReturnNotReady;

    if (!input || !inputSizeP) {
        AlwaysLog("%s invalid arguments", __FUNCTION__);
        return kIOReturnBadArgument;
    }

    if (offset > 0x99) {
        AlwaysLog("%s invalid range", __FUNCTION__);
        return kIOReturnBadArgument;
    }

    if (inputSizeP != 1) {
        AlwaysLog("%s bulk write is not supported yet", __FUNCTION__);
        return kIOReturnUnsupported;
    }

    if (fProvider->method_we1b(UInt32(offset), input[0]) != kIOReturnSuccess) {
        AlwaysLog("%s we1b failed", __FUNCTION__);
        return kIOReturnIOError;
    }

    DebugLog("%s @ 0x%02llx", __FUNCTION__, offset);
    return kIOReturnSuccess;
}

IOReturn YogaSMCUserClient::readECName(const char* name, UInt8* output) {
    if (!fProvider || !fProvider->isOpen(this))
        return kIOReturnNotReady;

    if (!name || !output || !fProvider->ec)
        return kIOReturnBadArgument;
    char field[5] = {name[0], name[1], name[2], name[3], '\0'};
    for (unsigned i = 0; i < 4; ++i) {
        if (!(field[i] == '_' || (field[i] >= 'A' && field[i] <= 'Z') ||
              (i > 0 && field[i] >= '0' && field[i] <= '9')))
            return kIOReturnBadArgument;
    }
    UInt32 result = 0;
    if (fProvider->ec->evaluateInteger(field, &result) != kIOReturnSuccess) {
        AlwaysLog("%s read %s failed", __FUNCTION__, field);
        return kIOReturnIOError;
    }

    *output = result;

    DebugLog("%s @ %s", __FUNCTION__, field);
    return kIOReturnSuccess;
}

IOReturn YogaSMCUserClient::registerNotificationPort(mach_port_t port, UInt32 type, io_user_reference_t refCon) {
    if (!fProvider || !fProvider->isOpen(this))
        return kIOReturnNotReady;

    if (fProvider->client) {
        AlwaysLog("%s already registered", __FUNCTION__);
        return kIOReturnPortExists;
    }

    fProvider->client = this;
    AlwaysLog("%s subscribed", __FUNCTION__);
    setProperty("Notification", true);

    m_notificationPort = port;
    notification.header.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0);
    notification.header.msgh_size = sizeof(SMCNotificationMessage);
    notification.header.msgh_remote_port = m_notificationPort;
    notification.header.msgh_local_port = MACH_PORT_NULL;
    notification.header.msgh_reserved = 0;
    notification.header.msgh_id = 0;
    notification.ref = refCon;
    return kIOReturnSuccess;
}

IOReturn YogaSMCUserClient::sendNotification(UInt32 event, UInt32 data) {
    if (m_notificationPort == MACH_PORT_NULL)
        return kIOReturnError;

    notification.event = event;
    notification.data = data;

    IOReturn ret = mach_msg_send_from_kernel_proper(&notification.header, notification.header.msgh_size);
    if (ret != MACH_MSG_SUCCESS) {
        if (ret != MACH_SEND_TIMED_OUT)
            AlwaysLog("%s failed %x", __FUNCTION__, ret);
        else
            DebugLog("%s timed out", __FUNCTION__);
    }
    return ret;
}

bool YogaSMCUserClient::start(IOService *provider) {
    if (!(fProvider = OSDynamicCast(YogaVPC, provider)))
        return false;
    iname = fProvider->getName();
    DebugLog("%s", __FUNCTION__);
    return super::start(provider);
}

void YogaSMCUserClient::stop(IOService *provider) {
    DebugLog("%s", __FUNCTION__);
    super::stop(provider);
}

IOReturn YogaSMCUserClient::clientClose(void) {
    userClientClose();
    if (terminate())
        DebugLog("%s success", __FUNCTION__);
    else
        AlwaysLog("%s failed", __FUNCTION__);
    return kIOReturnSuccess;
}

IOReturn YogaSMCUserClient::clientDied(void) {
    AlwaysLog("%s", __FUNCTION__);
    return clientClose();
}

