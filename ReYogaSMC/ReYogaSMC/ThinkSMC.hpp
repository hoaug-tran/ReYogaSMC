//  SPDX-License-Identifier: GPL-2.0-only
//
//  ThinkSMC.hpp
//  ReYogaSMC
//
//  Created by Zhen on 8/30/20.
//  Copyright © 2020 Zhen. All rights reserved.
//

#ifndef ThinkSMC_hpp
#define ThinkSMC_hpp

#include "ReYogaSMC.hpp"

class ThinkSMC : public ReYogaSMC
{
    typedef ReYogaSMC super;
    OSDeclareDefaultStructors(ThinkSMC)

private:
    void addVSMCKey() APPLE_KEXT_OVERRIDE;
    void updateECVendor() APPLE_KEXT_OVERRIDE;

    bool dualFan {false};

};

#endif /* ThinkSMC_hpp */
