// SPDX-License-Identifier: GPL-2.0-only
// Original work: Copyright (c) 2020 Zhen.

#include "IdeaWMI.hpp"

OSDefineMetaClassAndStructors(IdeaWMIPaper, ReYogaWMI);

const char *IdeaWMIPaper::registerEvent(OSString *guid, UInt32 id) {
    if (guid->isEqualTo(PAPER_LOOKING_WMI_EVENT)) {
        paperEvent = id;
        return feature;
    }
    return nullptr;
}

void IdeaWMIPaper::ACPIEvent(UInt32 argument) {
    if (argument != paperEvent) {
        super::ACPIEvent(argument);
        return;
    }

    DebugLog("message: ACPI notification 0x%02X, toggle FnLock", argument);
    // force enable keyboard and touchpad
    setTopCase(true);
    dispatchMessage(kSMC_FnlockEvent, NULL);
}

void IdeaWMIPaper::processWMI() {
    setProperty("Feature", feature);
}
