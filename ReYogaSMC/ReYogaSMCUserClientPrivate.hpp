// SPDX-License-Identifier: GPL-2.0-only
//
// ReYogaSMCUserClientPrivate.hpp
// Kernel-only user-client declaration.
//
// Original work: Copyright (c) 2020 Zhen.

#ifndef REYOGA_SMC_USER_CLIENT_PRIVATE_HPP
#define REYOGA_SMC_USER_CLIENT_PRIVATE_HPP

#include "ReYogaSMCUserClient.h"
#include <IOKit/IOUserClient.h>

class ReYogaVPC;

class ReYogaSMCUserClient final : public IOUserClient {
    using super = IOUserClient;
OSDeclareDefaultStructors(ReYogaSMCUserClient)

    public : bool initWithTask(task_t owningTask, void *securityToken, UInt32 type,
                               OSDictionary *properties) APPLE_KEXT_OVERRIDE;
    bool start(IOService *provider) APPLE_KEXT_OVERRIDE;
    void stop(IOService *provider) APPLE_KEXT_OVERRIDE;
    void free() APPLE_KEXT_OVERRIDE;

    IOReturn externalMethod(uint32_t selector,
                            IOExternalMethodArguments *arguments,
                            IOExternalMethodDispatch *dispatch = nullptr,
                            OSObject *target = nullptr,
                            void *reference = nullptr) APPLE_KEXT_OVERRIDE;

    IOReturn registerNotificationPort(mach_port_t port, UInt32 type,
                                      io_user_reference_t refCon) APPLE_KEXT_OVERRIDE;

    IOReturn clientClose() APPLE_KEXT_OVERRIDE;
    IOReturn clientDied() APPLE_KEXT_OVERRIDE;

    // May be called outside the gate; takes the provider's gate internally.
    IOReturn sendNotification(UInt32 event, UInt32 data = 0);

private:
    const char *iname{"UserClient"};

    struct MethodCall {
        ReYogaSMCUserClient *client;
        uint32_t selector;
        IOExternalMethodArguments *arguments;
    };

    struct NotificationRegistration {
        ReYogaSMCUserClient *client;
        mach_port_t port;
        UInt32 type;
        uint64_t refCon;
    };

    struct NotificationPayload {
        ReYogaSMCUserClient *client;
        UInt32 event;
        UInt32 data;
    };

    static IOExternalMethodDispatch kMethods[kRYSMCUCNumMethods];

    static IOReturn dispatchGated(OSObject *owner, void *arg0,
                                  void *arg1, void *arg2, void *arg3);
    static IOReturn closeGatedAction(OSObject *owner, void *arg0,
                                     void *arg1, void *arg2, void *arg3);
    static IOReturn registerPortGated(OSObject *owner, void *arg0,
                                      void *arg1, void *arg2, void *arg3);
    static IOReturn notifyGated(OSObject *owner, void *arg0,
                                void *arg1, void *arg2, void *arg3);

    static IOReturn methodOpen(OSObject *target, void *reference,
                               IOExternalMethodArguments *arguments);
    static IOReturn methodClose(OSObject *target, void *reference,
                                IOExternalMethodArguments *arguments);
    static IOReturn methodReadEC(OSObject *target, void *reference,
                                 IOExternalMethodArguments *arguments);
    static IOReturn methodWriteEC(OSObject *target, void *reference,
                                  IOExternalMethodArguments *arguments);
    static IOReturn methodReadECName(OSObject *target, void *reference,
                                     IOExternalMethodArguments *arguments);
    static IOReturn methodThinkFan(OSObject *target, void *reference,
                                   IOExternalMethodArguments *arguments);
    static IOReturn methodThinkFanCurve(OSObject *target, void *reference,
                                        IOExternalMethodArguments *arguments);

    // All methods below require the provider's command gate to be held.
    IOReturn openGated();
    IOReturn closeGated();
    IOReturn readECGated(UInt64 offset, UInt8 *output,
                         IOByteCount *outputSize);
    enum class FanRequestMode { Direct,
                                Watchdog };
    IOReturn thinkFanGated(UInt64 fan, UInt64 request, UInt8 *output,
                           FanRequestMode mode);
    void clearNotificationGated();

    // Provider is explicitly retained from start() to free().
    ReYogaVPC *provider_{nullptr};

    // Access to these fields is serialized through provider_->commandGate.
    mach_port_t notificationPort_{MACH_PORT_NULL};
    uint64_t notificationRefCon_{0};
    bool stopping_{false};

    // Snapshot of owning task authorization at user-client creation.
    bool administrator_{false};
};

#endif // REYOGA_SMC_USER_CLIENT_PRIVATE_HPP
