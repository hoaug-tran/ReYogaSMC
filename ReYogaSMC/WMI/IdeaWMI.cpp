//  SPDX-License-Identifier: GPL-2.0-only
//
//  IdeaWMI.cpp
//  ReYogaSMC
//
//  Created by Zhen on 2020/6/23.
//  Copyright © 2020 Zhen. All rights reserved.
//

#include "IdeaWMI.hpp"

ReYogaWMI *ReYogaWMI::withIdeaWMI(WMI *provider) {
    ReYogaWMI *dev = nullptr;

    if ((provider->hasMethod(GSENSOR_WMI_EVENT, ACPI_WMI_EVENT) && provider->hasMethod(GSENSOR_DATA_WMI_METHOD)) ||
        (provider->hasMethod(GSENSOR_WMI_EVENT_EXT, ACPI_WMI_EVENT) && provider->hasMethod(GSENSOR_DATA_WMI_METHOD_EXT))) {
        dev = OSTypeAlloc(IdeaWMIYoga);
        if (dev)
            dev->isPMsupported = true;
    } else if (provider->hasMethod(PAPER_LOOKING_WMI_EVENT, ACPI_WMI_EVENT)) {
        dev = OSTypeAlloc(IdeaWMIPaper);
    } else if (provider->hasMethod(SUPER_RES_WMI_EVENT, ACPI_WMI_EVENT)) {
        dev = OSTypeAlloc(IdeaWMISuperRes);
    } else if (provider->hasMethod(BAT_INFO_WMI_STRING, ACPI_WMI_EXPENSIVE | ACPI_WMI_STRING)) {
        dev = OSTypeAlloc(IdeaWMIBattery);
    } else if (provider->hasMethod(GAME_ZONE_DATA_WMI_METHOD) || provider->hasMethod(LENOVO_FAN_METHOD)) {
        dev = OSTypeAlloc(IdeaWMIGameZone);
    } else {
        dev = OSTypeAlloc(ReYogaWMI);
    }

    OSDictionary *dictionary = OSDictionary::withCapacity(1);
    if (!dev || !dictionary) {
        OSSafeReleaseNULL(dev);
        OSSafeReleaseNULL(dictionary);
        return nullptr;
    }

    dev->iname = provider->getName();
    dev->YWMI = provider;

    if (!dev->init(dictionary))
        OSSafeReleaseNULL(dev);

    dictionary->release();
    if (dev)
        dev->ownsWMI_ = true;
    return dev;
}

// Firmware supplies current/step/min/max as four little-endian dwords.
