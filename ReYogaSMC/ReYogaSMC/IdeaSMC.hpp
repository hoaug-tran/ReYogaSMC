//  SPDX-License-Identifier: GPL-2.0-only
//
//  IdeaSMC.hpp
//  ReYogaSMC
//
//  Created by Zhen on 8/25/20.
//  Copyright © 2020 Zhen. All rights reserved.
//

#ifndef IdeaSMC_hpp
#define IdeaSMC_hpp

#include "../ReYogaWMI/IdeaWMI.hpp"
#include "ReYogaSMC.hpp"

class IdeaSMC : public ReYogaSMC
{
    typedef ReYogaSMC super;
    OSDeclareDefaultStructors(IdeaSMC)

private:
    /**
     *  WMI device, in place of provider and direct ACPI evaluations
     */
    IdeaWMIGameZone *wmig {nullptr};
    IOService *sensorProvider {nullptr};

    /**
     *  Corresponding sensor index
     */
    UInt8 sensorIndex[MAX_SENSOR];

    void addVSMCKey() APPLE_KEXT_OVERRIDE;
    void updateECVendor() APPLE_KEXT_OVERRIDE;

    void getWMISensor(IOService* provider) APPLE_KEXT_OVERRIDE;
};

#endif /* IdeaSMC_hpp */
