//
//  ReYogaSMCUserClientPrivate.hpp
//  ReYogaSMC
//
//  Created by Zhen on 10/7/20.
//  Copyright © 2020 Zhen. All rights reserved.
//

#ifndef ReYogaSMCUserClientPrivate_hpp
#define ReYogaSMCUserClientPrivate_hpp

#include <IOKit/IOUserClient.h>
#include "common.h"
#include "ReYogaSMCUserClient.h"
#include "ReYogaVPC.hpp"

class ReYogaVPC;
class ReYogaSMCUserClient : public IOUserClient {
    typedef IOUserClient super;
    OSDeclareDefaultStructors(ReYogaSMCUserClient)

protected:
    ReYogaVPC* fProvider {nullptr};
    const char* iname {nullptr};
    task_t fTask {nullptr};
    mach_port_t m_notificationPort {MACH_PORT_NULL};
    SMCNotificationMessage notification {};

public:
    virtual bool start(IOService *provider) APPLE_KEXT_OVERRIDE;
    virtual void stop(IOService *provider) APPLE_KEXT_OVERRIDE;

    IOReturn externalMethod(uint32_t selector, IOExternalMethodArguments *arguments,
        IOExternalMethodDispatch *dispatch = nullptr, OSObject *target = nullptr, void *reference = nullptr) APPLE_KEXT_OVERRIDE;
    IOReturn registerNotificationPort(mach_port_t port, UInt32 type, io_user_reference_t refCon) APPLE_KEXT_OVERRIDE;

    virtual IOReturn clientClose(void) APPLE_KEXT_OVERRIDE;
    virtual IOReturn clientDied(void) APPLE_KEXT_OVERRIDE;

    IOReturn sendNotification(UInt32 event, UInt32 data=0);

    // Externally accessible methods
    IOReturn userClientOpen(void);
    IOReturn userClientClose(void);
    IOReturn readEC(UInt64 offset, UInt8 *output, IOByteCount *outputSizeP);
    IOReturn writeEC(UInt64 offset, UInt8 *input, IOByteCount inputSizeP);
    IOReturn readECName(const char* name, UInt8* output);

};
#endif /* ReYogaSMCUserClientPrivate_hpp */
