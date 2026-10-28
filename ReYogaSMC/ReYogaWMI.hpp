// SPDX-License-Identifier: GPL-2.0-only
//
// ReYogaWMI.hpp
// ReYogaSMC
//
// Created by Zhen on 2020/5/21.
// Copyright (c) 2020 Zhen. All rights reserved.
//

#ifndef ReYogaWMI_hpp
#define ReYogaWMI_hpp

#include "ReYogaBaseService.hpp"

class ReYogaWMI : public ReYogaBaseService {
    using super = ReYogaBaseService;
OSDeclareDefaultStructors(ReYogaWMI)

    public : IOService *probe(IOService *provider, SInt32 *score) APPLE_KEXT_OVERRIDE;

    bool start(IOService *provider) APPLE_KEXT_OVERRIDE;

    void stop(IOService *provider) APPLE_KEXT_OVERRIDE;
    void free() APPLE_KEXT_OVERRIDE;

    IOReturn message(UInt32 type, IOService *provider, void *argument) APPLE_KEXT_OVERRIDE;

    static ReYogaWMI *withIdeaWMI(WMI *provider);

    static ReYogaWMI *withDYWMI(WMI *provider);

protected:
    virtual void processWMI();

    virtual const char *registerEvent(OSString *guid, UInt32 id);

    virtual void ACPIEvent(UInt32 argument);

    OSDictionary *Event{nullptr};

private:
    void registerAndLogEvent(const char *key);

    // Successful factories transfer their transport; release only after stop/free.
    bool ownsWMI_{false};
};

#endif // ReYogaWMI_hpp
