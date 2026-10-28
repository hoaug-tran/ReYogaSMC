//
//  ReYogaSMC-Bridging-Header.h
//  ReYogaSMC
//
//  Created by Zhen on 10/14/20.
//  Copyright © 2020 Zhen. All rights reserved.
//

#ifndef ReYogaSMC_Bridging_Header_h
#define ReYogaSMC_Bridging_Header_h

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>
#import <IOKit/IOMessage.h>
#import <IOKit/hidsystem/ev_keymap.h>

// Expose the SDK macro to Swift without duplicating its numeric value.
static inline UInt32 ReYogaServiceTerminatedMessage(void) { return kIOMessageServiceIsTerminated; }

#import "../../../ReYogaSMC/ReYogaSMCUserClient.h"
#import "../../../ReYogaSMC/Platform/ThinkEvents.h"

// from https://github.com/toy/blueutil/blob/master/blueutil.m#L44
int IOBluetoothPreferencesAvailable();

int IOBluetoothPreferenceGetControllerPowerState();
void IOBluetoothPreferenceSetControllerPowerState(int state);

int IOBluetoothPreferenceGetDiscoverableState();
void IOBluetoothPreferenceSetDiscoverableState(int state);

// from https://github.com/koekeishiya/yabai/issues/147
CG_EXTERN void CoreDockSendNotification(CFStringRef, void*);

#endif /* ReYogaSMC_Bridging_Header_h */
