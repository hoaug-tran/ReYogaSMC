//  SPDX-License-Identifier: GPL-2.0-only
//
//  ReYogaWMI.hpp
//  ReYogaSMC
//
//  Created by Zhen on 2020/5/21.
//  Copyright © 2020 Zhen. All rights reserved.
//

#ifndef ReYogaWMI_hpp
#define ReYogaWMI_hpp

#include "ReYogaBaseService.hpp"

class ReYogaWMI : public ReYogaBaseService
{
    typedef ReYogaBaseService super;
    OSDeclareDefaultStructors(ReYogaWMI)

protected:
    /**
     *  Find notify id and other properties of an event
     *
     *  @param key  name of event dictionary
     */
    void getNotifyID(const char *key);

    /**
     *  Vendor specific WMI analyze
     */
    inline virtual void processWMI() {};

    OSDictionary *Event {nullptr};

    /**
     *  Register WMI event id
     *
     *  @param guid WMI GUID
     *  @param id  WMI event id
     *
     *  @return event name if available
     */
    inline virtual const char* registerEvent(OSString *guid, UInt32 id) {return nullptr;};
    
    /**
     *  Corresponding event to trigger after receiving a message
     *
     *  @param argument  argument of message
     */
    virtual void ACPIEvent(UInt32 argument);

public:
    virtual IOService *probe(IOService *provider, SInt32 *score) APPLE_KEXT_OVERRIDE;

    virtual bool start(IOService *provider) APPLE_KEXT_OVERRIDE;
    virtual void stop(IOService *provider) APPLE_KEXT_OVERRIDE;

    virtual IOReturn message(UInt32 type, IOService *provider, void *argument) APPLE_KEXT_OVERRIDE;
    static ReYogaWMI *withIdeaWMI(WMI *provider);
    static ReYogaWMI *withDYWMI(WMI *provider);
};

#endif /* ReYogaWMI_hpp */
