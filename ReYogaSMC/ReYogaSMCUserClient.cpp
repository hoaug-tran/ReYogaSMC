// SPDX-License-Identifier: GPL-2.0-only
//
// ReYogaSMCUserClient.cpp
// IOKit user-client dispatch and lifecycle.
//
// Original work: Copyright (c) 2020 Zhen.

#include "ReYogaSMCUserClientPrivate.hpp"

#include "ControlValidation.hpp"
#include "ReYogaVPC.hpp"
#include "common.h"

#include <IOKit/IOCommandGate.h>
#include <IOKit/IOLib.h>
#include <libkern/libkern.h>
#include <kern/ipc_mig.h>
#include <mach/task.h>
#include <mach/task_info.h>

OSDefineMetaClassAndStructors(ReYogaSMCUserClient, IOUserClient)

    IOExternalMethodDispatch
    ReYogaSMCUserClient::kMethods[kRYSMCUCNumMethods] = {
        {methodOpen, 0, 0, 0, 0},
        {methodClose, 0, 0, 0, 0},
        {methodReadEC, 1, 0, 0, kIOUCVariableStructureSize},
        {methodWriteEC, 1, kIOUCVariableStructureSize, 0, 0},
        {methodReadECName, 0, 4, 0, 1},
        {methodThinkFan, 2, 0, 0, kRYSMCFanReplySize},
        {methodThinkFanCurve, 2, 0, 0, kRYSMCFanReplySize},
        {methodAuthorizeThinkFan, 0, kRYSMCAuditTokenWords * sizeof(uint32_t), 0, 0},
};

bool ReYogaSMCUserClient::initWithTask(task_t owningTask,
                                       void *securityToken,
                                       UInt32 type,
                                       OSDictionary *properties) {
    if (!super::initWithTask(owningTask, securityToken, type, properties)) {
        return false;
    }

    administrator_ =
        clientHasPrivilege(owningTask, kIOClientPrivilegeAdministrator) ==
        kIOReturnSuccess;
    mach_msg_type_number_t count = TASK_AUDIT_TOKEN_COUNT;
    static_assert(sizeof(ownerAuditToken_) == sizeof(audit_token_t), "Audit token size changed");
    ownerAuditTokenValid_ = task_info(owningTask, TASK_AUDIT_TOKEN,
                                      reinterpret_cast<task_info_t>(ownerAuditToken_), &count) == KERN_SUCCESS &&
                            count == TASK_AUDIT_TOKEN_COUNT;

    return true;
}

bool ReYogaSMCUserClient::start(IOService *provider) {
    auto *vpc = OSDynamicCast(ReYogaVPC, provider);

    if (!vpc || !super::start(provider)) {
        return false;
    }

    vpc->retain();
    provider_ = vpc;

    return true;
}

void ReYogaSMCUserClient::stop(IOService *provider) {
    if (provider_ && provider_->commandGate) {

        const IOReturn status = provider_->commandGate->runAction(
            closeGatedAction, this);

        if (status != kIOReturnSuccess) {
            AlwaysLog("UserClient stop cleanup failed: 0x%x", status);
        }
    } else {
        clearNotificationGated();
    }

    super::stop(provider);
}

void ReYogaSMCUserClient::free() {
    clearNotificationGated();

    if (provider_) {
        provider_->release();
        provider_ = nullptr;
    }

    super::free();
}

IOReturn ReYogaSMCUserClient::externalMethod(
    uint32_t selector, IOExternalMethodArguments *arguments,
    IOExternalMethodDispatch *, OSObject *, void *) {

    if (!arguments || selector >= kRYSMCUCNumMethods) {
        return kIOReturnBadArgument;
    }

    if (!provider_ || isInactive() || !provider_->commandGate) {
        return kIOReturnNotAttached;
    }

    MethodCall call{this, selector, arguments};

    return provider_->commandGate->runAction(dispatchGated, &call);
}

IOReturn ReYogaSMCUserClient::dispatchGated(
    OSObject *, void *arg0, void *, void *, void *) {
    auto *call = static_cast<MethodCall *>(arg0);
    auto *self = call->client;

    if (self->stopping_ || self->isInactive() || !self->provider_ ||
        self->provider_->isInactive() || self->provider_->stopping) {
        return kIOReturnNotAttached;
    }

    if (call->selector >= kRYSMCUCNumMethods) {
        return kIOReturnBadArgument;
    }

    if (call->selector != kRYSMCUCOpen &&
        call->selector != kRYSMCUCClose &&
        self->provider_->getProperty("SafeMode") == kOSBooleanTrue) {
        return kIOReturnNotPermitted;
    }

    return self->IOUserClient::externalMethod(
        call->selector, call->arguments,
        &kMethods[call->selector],
        self, nullptr);
}

IOReturn ReYogaSMCUserClient::methodOpen(
    OSObject *target, void *, IOExternalMethodArguments *) {
    return static_cast<ReYogaSMCUserClient *>(target)->openGated();
}

IOReturn ReYogaSMCUserClient::methodClose(
    OSObject *target, void *, IOExternalMethodArguments *) {
    return static_cast<ReYogaSMCUserClient *>(target)->closeGated();
}

IOReturn ReYogaSMCUserClient::methodReadEC(
    OSObject *target, void *, IOExternalMethodArguments *arguments) {
    auto *self = static_cast<ReYogaSMCUserClient *>(target);
    if (!self->administrator_) {
        return kIOReturnNotPermitted;
    }

    IOByteCount length = arguments->structureOutputSize;

    const IOReturn status = self->readECGated(
        arguments->scalarInput[0],
        static_cast<UInt8 *>(arguments->structureOutput), &length);

    arguments->structureOutputSize =
        status == kIOReturnSuccess ? length : 0;

    return status;
}

IOReturn ReYogaSMCUserClient::methodWriteEC(
    OSObject *, void *, IOExternalMethodArguments *) {

    return kIOReturnUnsupported;
}

IOReturn ReYogaSMCUserClient::methodReadECName(
    OSObject *, void *, IOExternalMethodArguments *) {

    return kIOReturnUnsupported;
}

IOReturn ReYogaSMCUserClient::methodThinkFan(
    OSObject *target, void *, IOExternalMethodArguments *arguments) {
    auto *self = static_cast<ReYogaSMCUserClient *>(target);

    const IOReturn status = self->thinkFanGated(
        arguments->scalarInput[0], arguments->scalarInput[1],
        static_cast<UInt8 *>(arguments->structureOutput), FanRequestMode::Direct);
    arguments->structureOutputSize = status == kIOReturnSuccess ? kRYSMCFanReplySize : 0;
    return status;
}

IOReturn ReYogaSMCUserClient::methodThinkFanCurve(
    OSObject *target, void *, IOExternalMethodArguments *arguments) {
    auto *self = static_cast<ReYogaSMCUserClient *>(target);

    const IOReturn status = self->thinkFanGated(
        arguments->scalarInput[0], arguments->scalarInput[1],
        static_cast<UInt8 *>(arguments->structureOutput), FanRequestMode::Watchdog);
    arguments->structureOutputSize = status == kIOReturnSuccess ? kRYSMCFanReplySize : 0;
    return status;
}

IOReturn ReYogaSMCUserClient::openGated() {
    if (!provider_ || isInactive() || provider_->isInactive() || provider_->stopping) {
        return kIOReturnNotAttached;
    }

    if (provider_->isOpen(this)) {
        return kIOReturnSuccess;
    }

    return provider_->open(this) ? kIOReturnSuccess : kIOReturnExclusiveAccess;
}

IOReturn ReYogaSMCUserClient::methodAuthorizeThinkFan(
    OSObject *target, void *, IOExternalMethodArguments *arguments) {
    auto self = static_cast<ReYogaSMCUserClient *>(target);
    // A separate root connection grants only the already registered app session.
    // Audit PID version prevents a reused PID from inheriting this grant.
    auto peer = self->provider_->client;
    if (!self->administrator_ || !peer || peer->stopping_ || peer->isInactive() ||
        !self->provider_->isOpen(peer) || !peer->ownerAuditTokenValid_ ||
        !arguments->structureInput || arguments->structureInputSize != sizeof(peer->ownerAuditToken_))
        return kIOReturnNotPermitted;
    if (memcmp(peer->ownerAuditToken_, arguments->structureInput, sizeof(peer->ownerAuditToken_)) != 0)
        return kIOReturnNotPermitted;
    peer->fanAuthorized_ = true;
    return kIOReturnSuccess;
}

IOReturn ReYogaSMCUserClient::closeGated() {
    fanAuthorized_ = false;
    clearNotificationGated();

    if (!provider_ || !provider_->isOpen(this)) {
        return kIOReturnSuccess;
    }

    if (!provider_->stopping)
        provider_->restoreUserControls();
    provider_->close(this);

    return kIOReturnSuccess;
}

IOReturn ReYogaSMCUserClient::closeGatedAction(
    OSObject *, void *arg0, void *, void *, void *) {
    auto *self = static_cast<ReYogaSMCUserClient *>(arg0);
    self->stopping_ = true;
    return self->closeGated();
}

IOReturn ReYogaSMCUserClient::readECGated(
    UInt64 offset, UInt8 *output, IOByteCount *outputSize) {

    if (!provider_ || !provider_->isOpen(this)) {
        return kIOReturnNotOpen;
    }

    if (!output || !outputSize || *outputSize == 0 ||
        !ReYogaControl::validECSpan(offset, *outputSize)) {
        return kIOReturnBadArgument;
    }

    if (*outputSize == 1) {
        UInt8 value = 0;

        const IOReturn status =
            provider_->method_re1b(static_cast<UInt32>(offset), &value);

        if (status == kIOReturnSuccess) {
            output[0] = value;
        }

        return status;
    }

    OSData *data = nullptr;

    const IOReturn status = provider_->method_recb(
        static_cast<UInt32>(offset), static_cast<UInt32>(*outputSize), &data);

    if (status != kIOReturnSuccess) {
        OSSafeReleaseNULL(data);
        return status;
    }

    if (!data || data->getLength() != *outputSize ||
        !data->getBytesNoCopy()) {
        OSSafeReleaseNULL(data);
        return kIOReturnIOError;
    }

    memcpy(output, data->getBytesNoCopy(), *outputSize);
    data->release();

    return kIOReturnSuccess;
}

IOReturn ReYogaSMCUserClient::thinkFanGated(
    UInt64 fan, UInt64 request, UInt8 *output, FanRequestMode mode) {
    if (!provider_ || !provider_->isOpen(this)) {
        return kIOReturnNotOpen;
    }

    if (!output || fan > kRYSMCMaxFanIndex || request > UINT32_MAX) {
        return kIOReturnBadArgument;
    }

    if (mode == FanRequestMode::Watchdog) {
        if (!((request >= 1 && request <= 7) ||
              request == kRYSMCFanCurveFullSpeed)) {
            return kIOReturnBadArgument;
        }
    } else if (request != kRYSMCFanQueryRPM &&
               !ReYogaControl::validThinkFanLevel(static_cast<UInt32>(request))) {
        return kIOReturnBadArgument;
    }

    if (!administrator_ && !fanAuthorized_ &&
        (mode == FanRequestMode::Watchdog || request != kRYSMCFanQueryRPM)) {
        return kIOReturnNotPermitted;
    }

    return mode == FanRequestMode::Watchdog
               ? provider_->accessThinkFanCurve(static_cast<UInt32>(fan),
                                                static_cast<UInt32>(request), output)
               : provider_->accessThinkFan(static_cast<UInt32>(fan),
                                           static_cast<UInt32>(request), output);
}

IOReturn ReYogaSMCUserClient::registerNotificationPort(
    mach_port_t port, UInt32 type, io_user_reference_t refCon) {

    if (!IPC_PORT_VALID(port)) {
        return kIOReturnBadArgument;
    }

    if (!provider_ || isInactive() || !provider_->commandGate) {
        releaseNotificationPort(port);
        return kIOReturnNotAttached;
    }

    NotificationRegistration registration{
        this, port, type, static_cast<uint64_t>(refCon)};
    const IOReturn status = provider_->commandGate->runAction(
        registerPortGated, &registration);

    if (status != kIOReturnSuccess) {
        releaseNotificationPort(port);
    }

    return status;
}

IOReturn ReYogaSMCUserClient::registerPortGated(
    OSObject *, void *arg0, void *, void *, void *) {
    auto *registration = static_cast<NotificationRegistration *>(arg0);
    auto *self = registration->client;

    if (registration->type != kRYSMCNotificationType) {
        return kIOReturnBadArgument;
    }

    if (self->stopping_ || self->isInactive() || !self->provider_ ||
        self->provider_->isInactive() || self->provider_->stopping) {
        return kIOReturnNotAttached;
    }

    if (!self->provider_->isOpen(self)) {
        return kIOReturnNotOpen;
    }

    if (self->provider_->client != nullptr ||
        IPC_PORT_VALID(self->notificationPort_)) {
        return kIOReturnPortExists;
    }

    self->notificationPort_ = registration->port;
    self->notificationRefCon_ = registration->refCon;
    self->provider_->client = self;
    self->setProperty("Notification", true);

    return kIOReturnSuccess;
}

void ReYogaSMCUserClient::clearNotificationGated() {
    if (provider_ && provider_->client == this) {
        provider_->client = nullptr;
    }

    const mach_port_t port = notificationPort_;
    notificationPort_ = MACH_PORT_NULL;
    notificationRefCon_ = 0;
    removeProperty("Notification");

    if (IPC_PORT_VALID(port)) {
        const IOReturn status = releaseNotificationPort(port);
        if (status != kIOReturnSuccess) {
            AlwaysLog("Failed to release notification port: 0x%x", status);
        }
    }
}

IOReturn ReYogaSMCUserClient::sendNotification(UInt32 event, UInt32 data) {
    if (!provider_ || isInactive() || !provider_->commandGate) {
        return kIOReturnNotAttached;
    }

    NotificationPayload payload{this, event, data};

    return provider_->commandGate->runAction(notifyGated, &payload);
}

IOReturn ReYogaSMCUserClient::notifyGated(
    OSObject *, void *arg0, void *, void *, void *) {
    auto *payload = static_cast<NotificationPayload *>(arg0);
    auto *self = payload->client;

    if (self->stopping_ || self->isInactive() || !self->provider_ || self->provider_->stopping ||
        !IPC_PORT_VALID(self->notificationPort_)) {
        return kIOReturnNotReady;
    }

    SMCNotificationMessage message{};
    message.header.msgh_bits = MACH_MSGH_BITS(MACH_MSG_TYPE_COPY_SEND, 0);
    message.header.msgh_size = sizeof(message);
    message.header.msgh_remote_port = self->notificationPort_;
    message.header.msgh_local_port = MACH_PORT_NULL;
    message.header.msgh_id = 0;
    message.event = payload->event;
    message.data = payload->data;
    message.ref = self->notificationRefCon_;

    const mach_msg_return_t status = mach_msg_send_from_kernel_proper(
        &message.header, message.header.msgh_size);

    if (status != MACH_MSG_SUCCESS && status != MACH_SEND_TIMED_OUT) {
        IOLog("RYSMC - Info: %s::%s Notification send failed: 0x%x\n",
              self->iname, self->getName(), status);
    }

    return static_cast<IOReturn>(status);
}

IOReturn ReYogaSMCUserClient::clientClose() {
    IOReturn result = kIOReturnSuccess;
    if (provider_ && provider_->commandGate) {
        result = provider_->commandGate->runAction(
            closeGatedAction, this);
    } else {
        clearNotificationGated();
    }

    terminate();

    return result;
}

IOReturn ReYogaSMCUserClient::clientDied() {
    return clientClose();
}
