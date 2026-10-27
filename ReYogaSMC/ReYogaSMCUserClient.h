//
//  ReYogaSMCUserClient.h
//  ReYogaSMC
//
//  Created by Zhen on 10/9/20.
//  Copyright © 2020 Zhen. All rights reserved.
//

#ifndef ReYogaSMCUserClient_h
#define ReYogaSMCUserClient_h

#include <libkern/OSTypes.h>
#include <mach/message.h>

#ifndef IOKIT
typedef uint64_t io_user_reference_t;
#endif

enum {
    kRYSMCUCOpen,            // ScalarIScalarO
    kRYSMCUCClose,           // ScalarIScalarO
    kRYSMCUCReadEC,          // ScalarIStructO
    kRYSMCUCWriteEC,         // ScalarIStructI
    kRYSMCUCReadECName,      // ScalarIScalarO
    kRYSMCUCThinkFan,         // Two scalar inputs (fan, level or 0x100 to read), 3 output bytes.
    kRYSMCUCNumMethods
};

typedef struct {
    mach_msg_header_t header;
    UInt32 event;
    UInt32 data;
    io_user_reference_t ref;
} SMCNotificationMessage;

#endif /* ReYogaSMCUserClient_h */
